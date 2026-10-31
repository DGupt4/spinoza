//
//  WhisperEngine.swift
//  desktop
//

import Foundation
import Combine
import Observation
import WhisperKit
import os

// MARK: - Delegate

/// Receives results from WhisperEngine.
/// All methods are guaranteed to be called on the MainActor.
@MainActor
protocol TranscriptionEngineDelegate: AnyObject {
    /// Fired with each streaming partial result while a session is in progress.
    func engineDidUpdatePartial(_ text: String)
    /// Fired once with the final result when a session ends.
    func engineDidFinalize(_ text: String)
    /// Fired if the engine hits an unrecoverable error.
    func engineDidFail(_ error: Error)
}

// MARK: - Engine

/// Transcription engine backed by OpenAI Whisper (large-v3 turbo) via WhisperKit.
///
/// Audio flow:
///   AudioCapture (16 kHz mono Float32) → sessionSamples → WhisperKit.transcribe(audioArray:)
///
/// Transcript flow:
///   periodic re-transcription of the accumulated buffer → engineDidUpdatePartial (display only)
///   stop() (one authoritative full-buffer transcription) → engineDidFinalize
///
/// WhisperKit's `transcribe(audioArray:)` handles long-form audio internally via its
/// windowed/chunked decoding, so the full session buffer can be transcribed in one call.
@MainActor
final class WhisperEngine {

    weak var delegate: (any TranscriptionEngineDelegate)?

    var levelPublisher: AnyPublisher<Float, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    // MARK: - Private

    private let levelSubject = PassthroughSubject<Float, Never>()

    private let modelManager: WhisperModelManager
    // AudioCapture starts a fresh AVCaptureSession for each dictation and tears it
    // down in stop(). Nothing touches the input device while idle, so opening
    // Settings cannot interrupt other audio and Bluetooth headphones are released
    // from HFP between sessions.
    private let audioCapture  = AudioCapture()

    /// All PCM captured during the current session (16 kHz mono Float32).
    /// Used both for periodic partials and for the authoritative final transcription.
    private var sessionSamples: [Float] = []
    private var samplesAtLastPartial = 0
    private var partialTask: Task<Void, Never>?
    private var transcriber: WhisperKit?
    private var isSessionActive = false
    /// Invalidates in-flight async work (model load, partials) once a session ends.
    private var generation = 0

    /// Cadence of live partial updates. Each pass re-transcribes everything captured so
    /// far, so a pass is only started when no other pass is running (serialized below).
    private static let partialInterval: Duration = .milliseconds(1_200)
    /// Minimum amount of new audio required before another partial is worth decoding.
    private static let minNewAudioForPartial = 0.5  // seconds

    // MARK: - Init

    init(modelManager: WhisperModelManager) {
        self.modelManager = modelManager
    }

    /// Stores the preferred input device. The device is bound only when a session starts.
    func setPreferredInputDevice(uid: String) {
        audioCapture.setPreferredDevice(uid: uid)
    }

    // MARK: - Session

    func start() async throws {
        guard !isSessionActive else { return }

        generation += 1
        let session = generation
        isSessionActive  = true
        sessionSamples   = []
        samplesAtLastPartial = 0

        // Tear down any stale session left behind by an interrupted previous run.
        // This is a no-op when nothing is running and guarantees the new session
        // never overlaps an old capture.
        _ = await audioCapture.stop()

        // 1. Start audio capture IMMEDIATELY so no speech is lost while the model is
        //    warming up. Chunks are buffered until WhisperKit is ready.
        audioCapture.onLevel = { [weak self] rms in self?.levelSubject.send(rms) }
        audioCapture.onChunk = { [weak self] samples in
            self?.sessionSamples.append(contentsOf: samples)
        }
        do {
            try await audioCapture.start()
        } catch {
            isSessionActive = false
            audioCapture.onChunk = nil
            audioCapture.onLevel = nil
            throw error
        }

        // 2. Obtain the loaded WhisperKit instance (loads from the on-disk cache on the
        //    first session if the model manager has not finished warming up yet).
        let kit: WhisperKit
        do {
            kit = try await modelManager.loadedTranscriber()
        } catch {
            isSessionActive = false
            audioCapture.onChunk = nil
            audioCapture.onLevel = nil
            _ = await audioCapture.stop()
            sessionSamples = []
            throw error
        }

        // The session may have been stopped (or restarted) while the model was loading.
        guard session == generation, isSessionActive else { return }
        transcriber = kit

        // 3. Start periodic partial transcription. Everything captured while warming up
        //    is already in sessionSamples, so nothing is lost.
        startPartialLoop(session: session)
    }

    func stop() async throws {
        guard isSessionActive else { return }
        isSessionActive = false
        generation += 1

        audioCapture.onChunk = nil
        audioCapture.onLevel = nil

        // stop() tears down the capture session (releasing the mic and any Bluetooth
        // link) and drains the audio queue, returning samples that didn't fill a chunk.
        let remainder = await audioCapture.stop()
        if !remainder.isEmpty {
            sessionSamples.append(contentsOf: remainder)
        }

        // Cancel the partial loop and wait for any in-flight decode to finish so the
        // authoritative transcription below never runs concurrently with WhisperKit.
        partialTask?.cancel()
        await partialTask?.value
        partialTask = nil

        let samples = sessionSamples
        sessionSamples = []
        samplesAtLastPartial = 0

        guard let kit = transcriber else { return }
        transcriber = nil

        // Ignore taps shorter than ~0.1 s — Whisper has nothing to decode there.
        guard samples.count >= Int(AudioCapture.sampleRate * 0.1) else { return }

        do {
            let finalText = try await Self.transcribe(kit, samples: samples)
            let trimmed   = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                delegate?.engineDidFinalize(trimmed)
            }
        } catch {
            delegate?.engineDidFail(error)
            throw error
        }
    }

    func reset() {
        generation += 1
        isSessionActive = false
        partialTask?.cancel()
        partialTask = nil
        sessionSamples = []
        samplesAtLastPartial = 0
        transcriber = nil
        audioCapture.onChunk = nil
        audioCapture.onLevel = nil
    }

    // MARK: - Periodic partials

    private func startPartialLoop(session: Int) {
        partialTask?.cancel()
        partialTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.partialInterval)
                guard !Task.isCancelled, let self else { break }
                await self.emitPartialIfNeeded(session: session)
            }
        }
    }

    /// Re-transcribes the accumulated session buffer for live display. Runs at most once
    /// at a time (the loop awaits each pass before the next tick), and results from a
    /// stale session are discarded.
    private func emitPartialIfNeeded(session: Int) async {
        guard session == generation, isSessionActive, let kit = transcriber else { return }

        let samples = sessionSamples
        let newSamples = samples.count - samplesAtLastPartial
        guard samples.count >= Int(AudioCapture.sampleRate * Self.minNewAudioForPartial),
              newSamples >= Int(AudioCapture.sampleRate * Self.minNewAudioForPartial)
        else { return }

        guard let text = try? await Self.transcribe(kit, samples: samples) else { return }
        guard session == generation, isSessionActive else { return }

        samplesAtLastPartial = samples.count
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            delegate?.engineDidUpdatePartial(trimmed)
        }
    }

    // MARK: - WhisperKit helpers

    /// Transcribes 16 kHz mono Float32 samples and joins the decoded windows.
    private static func transcribe(_ kit: WhisperKit, samples: [Float]) async throws -> String {
        let results = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: nil,
                temperature: 0,
                usePrefillPrompt: true,
                detectLanguage: true,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false
            )
        )
        return results.map(\.text).joined(separator: " ")
    }
}

// MARK: - Errors

enum WhisperEngineError: LocalizedError {
    /// No model weights on disk yet (fresh install).
    case modelsNotLoaded
    /// Model weights are on disk but the tokenizer has not been fetched yet.
    case tokenizerNotReady
    /// A download is complete enough to attempt a load, but WhisperKit failed.
    case modelLoadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:
            return "Whisper model is not downloaded. Please download it in Preferences."
        case .tokenizerNotReady:
            return "The speech model files are present, but the tokenizer is missing. Click Retry to finish setup (internet access is needed once)."
        case .modelLoadFailed(let error):
            return "The speech model could not be loaded: \(error.localizedDescription). Click Retry to repair the download."
        }
    }
}

// MARK: - Model Manager

/// Manages downloading and loading the WhisperKit model bundle.
///
/// The variant is pinned in `modelVariant`; change it here to switch models.
/// Downloads are stored under `downloadBase` (Application Support) so the local
/// model folder is deterministic and can be loaded without any network access.
@Observable
@MainActor
final class WhisperModelManager {

    // MARK: - Configuration

    /// WhisperKit model variant (Hugging Face folder name in `argmaxinc/whisperkit-coreml`).
    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo"
    /// User-facing name shown in Settings/Onboarding.
    static let displayName  = "Whisper Large v3 Turbo"
    /// Approximate download size shown in Settings/Onboarding.
    static let approximateSize = "~1.6 GB"

    /// Root directory for model downloads/caches.
    static let downloadBase: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Spinoza/Models", isDirectory: true)
    }()

    /// Deterministic on-disk location of the model folder (Hub cache layout:
    /// `<downloadBase>/models/<repo-id>/<variant>`).
    static var modelFolder: URL {
        downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelVariant, isDirectory: true)
    }

    /// Hugging Face repo that hosts the tokenizer for the pinned model variant.
    /// WhisperKit looks for it at `<downloadBase>/models/<repo-id>`; we keep it
    /// deterministic so a completed download loads entirely offline afterwards.
    static let tokenizerRepoID = "openai/whisper-large-v3"

    /// Deterministic on-disk location matching WhisperKit's `HubApiWrapper`
    /// cache layout (`<downloadBase>/models/openai/whisper-large-v3`).
    static var tokenizerCacheFolder: URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(tokenizerRepoID, isDirectory: true)
    }

    /// Files downloaded from the tokenizer repo. `config.json` is optional to
    /// WhisperKit's local loader but is fetched for parity with its Hub path.
    static let tokenizerDownloadFiles = ["config.json", "tokenizer_config.json", "tokenizer.json"]

    /// Files WhisperKit's local tokenizer loader actually requires. If these are
    /// present, loading never touches the network.
    static let requiredTokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    /// Model files WhisperKit's `loadModelComponents` requires.
    static let requiredModelFiles = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    /// True when every required Core ML model is present on disk.
    static func modelFilesPresent() -> Bool {
        requiredModelFiles.allSatisfy {
            FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path)
        }
    }

    /// True when the tokenizer files WhisperKit searches for are present on disk.
    static func tokenizerFilesPresent() -> Bool {
        requiredTokenizerFiles.allSatisfy {
            FileManager.default.fileExists(atPath: tokenizerCacheFolder.appendingPathComponent($0).path)
        }
    }

    // MARK: - Observable state

    private(set) var isReady:          Bool   = false
    private(set) var isDownloading:    Bool   = false
    private(set) var downloadProgress: Double = 0.0
    private(set) var downloadError:    String?

    /// Loaded model, retained after first successful load and shared by the engine.
    private(set) var cachedTranscriber: WhisperKit?

    private var readinessTask: Task<Void, Never>?
    private var downloadTask:  Task<Void, Never>?

    init() {
        checkReady()
    }

    /// Attempt to load the model from the on-disk cache (no network).
    ///
    /// Readiness is only reported after WhisperKit has fully loaded the Core ML
    /// models *and* the tokenizer. A model whose weights are present but whose
    /// tokenizer is missing therefore surfaces an actionable error instead of
    /// silently staying "Not Downloaded".
    func checkReady() {
        guard !isReady, !isDownloading, readinessTask == nil, downloadTask == nil else { return }

        readinessTask = Task { [weak self] in
            guard let self else { return }
            do {
                let kit = try await Self.loadFromCache()
                self.applyLoaded(kit)
            } catch let error as WhisperEngineError {
                self.isReady = false
                self.cachedTranscriber = nil
                if case .modelsNotLoaded = error {
                    // Fresh install: a normal "not downloaded yet" state, not an error.
                    Log.whisper.info("Whisper model is not downloaded yet")
                } else {
                    self.downloadError = error.localizedDescription
                    Log.whisper.error("Whisper model is not ready: \(error.localizedDescription)")
                }
            } catch {
                self.isReady = false
                self.cachedTranscriber = nil
                let message = Self.userFacingMessage(for: error)
                self.downloadError = message
                Log.whisper.error("Whisper model load failed: \(String(reflecting: error))")
            }
            self.readinessTask = nil
        }
    }

    /// Returns the loaded transcriber, loading it from the cache on demand.
    /// Throws `WhisperEngineError` if the model is missing or incomplete.
    func loadedTranscriber() async throws -> WhisperKit {
        if let cachedTranscriber { return cachedTranscriber }

        // Wait for an in-flight readiness check instead of loading the model twice.
        if let readinessTask {
            await readinessTask.value
            if let cachedTranscriber { return cachedTranscriber }
        }

        // A download owns the model pipeline. Wait for it rather than starting a
        // second concurrent Core ML load (two large loads can exhaust memory).
        if let downloadTask {
            await downloadTask.value
            if let cachedTranscriber { return cachedTranscriber }
        }

        do {
            let kit = try await Self.loadFromCache()
            applyLoaded(kit)
            return kit
        } catch {
            // Don't clobber a more specific download error already shown in the UI.
            if Self.modelFilesPresent(), downloadError == nil {
                downloadError = Self.userFacingMessage(for: error)
            }
            Log.whisper.error("Whisper model unavailable: \(String(reflecting: error))")
            throw error
        }
    }

    /// Download the Whisper model bundle and its tokenizer, then load and cache it.
    ///
    /// The tokenizer is fetched here, once, and stored next to the model cache so
    /// that every later launch loads entirely offline. Progress is held below 100%
    /// until the model has actually loaded; a failure resets progress and surfaces
    /// an actionable error instead of leaving the UI stuck at 100%.
    func downloadModel() {
        guard !isDownloading, !isReady else { return }
        downloadError    = nil
        isDownloading    = true
        downloadProgress = 0.0

        downloadTask = Task { [weak self] in
            guard let self else { return }

            // Never overlap with a launch-time checkReady() load.
            if let readinessTask = self.readinessTask {
                await readinessTask.value
            }
            if self.isReady {
                self.downloadProgress = 1.0
                self.isDownloading    = false
                self.downloadTask     = nil
                return
            }

            do {
                let folder = try await WhisperKit.download(
                    variant: Self.modelVariant,
                    downloadBase: Self.downloadBase
                ) { [weak self] progress in
                    // Hold at 98% until the tokenizer is cached and the model has
                    // actually loaded, so the UI never shows 100% for an unusable model.
                    let fraction = min(progress.fractionCompleted, 0.98)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.downloadProgress = max(self.downloadProgress, fraction)
                    }
                }

                guard Self.modelFilesPresent(at: folder) else {
                    throw WhisperEngineError.modelsNotLoaded
                }

                // WhisperKit's model repo does not contain the tokenizer; without
                // this step the load below would hit Hugging Face at runtime.
                try await Self.ensureTokenizerDownloaded()

                // Files are all on disk; hold just below 100% while the (possibly
                // slow, first-time Core ML specialization) load runs.
                if self.downloadProgress < 0.98 {
                    self.downloadProgress = 0.98
                }

                let kit = try await Self.loadTranscriber(at: folder)
                self.applyLoaded(kit)
                self.downloadProgress = 1.0
                Log.whisper.info("Whisper model ready at \(folder.path)")
            } catch {
                self.isReady           = false
                self.cachedTranscriber = nil
                self.downloadProgress  = 0.0
                let message = Self.userFacingMessage(for: error)
                self.downloadError = message
                Log.whisper.error("Whisper model setup failed: \(String(reflecting: error))")
            }
            self.isDownloading = false
            self.downloadTask  = nil
        }
    }

    // MARK: - Loading

    /// Loads the model from the deterministic cache folder without downloading.
    /// Requires both the Core ML bundle and the tokenizer to be complete on disk.
    private static func loadFromCache() async throws -> WhisperKit {
        guard modelFilesPresent() else {
            throw WhisperEngineError.modelsNotLoaded
        }
        guard tokenizerFilesPresent() else {
            throw WhisperEngineError.tokenizerNotReady
        }
        do {
            return try await loadTranscriber(at: modelFolder)
        } catch {
            throw WhisperEngineError.modelLoadFailed(error)
        }
    }

    /// Downloads the tokenizer files into the exact Hub cache layout WhisperKit
    /// searches (`<downloadBase>/models/openai/whisper-large-v3`).
    private static func ensureTokenizerDownloaded() async throws {
        if tokenizerFilesPresent() { return }

        Log.whisper.info("Downloading Whisper tokenizer to \(tokenizerCacheFolder.path)")
        let hub  = HubApiWrapper(downloadBase: downloadBase)
        let repo = HubApiWrapper.Repo(id: tokenizerRepoID)
        _ = try await hub.snapshot(from: repo, matching: tokenizerDownloadFiles)

        guard tokenizerFilesPresent() else {
            throw WhisperEngineError.tokenizerNotReady
        }
        Log.whisper.info("Whisper tokenizer cached at \(tokenizerCacheFolder.path)")
    }

    /// True when every required Core ML model is present at `folder`.
    static func modelFilesPresent(at folder: URL) -> Bool {
        requiredModelFiles.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    private static func loadTranscriber(at folder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: Self.modelVariant,
            downloadBase: Self.downloadBase,
            modelFolder: folder.path,
            tokenizerFolder: Self.tokenizerCacheFolder,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    /// Records a successful model load and clears any stale error.
    private func applyLoaded(_ kit: WhisperKit) {
        cachedTranscriber = kit
        isReady           = true
        downloadError     = nil
    }

    /// Wraps non-engine errors with download context for display in the UI.
    private static func userFacingMessage(for error: Error) -> String {
        if let engineError = error as? WhisperEngineError {
            return engineError.localizedDescription
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return "Could not download the speech model: \(description)"
        }
        return "Could not download the speech model: \(error.localizedDescription)"
    }
}
