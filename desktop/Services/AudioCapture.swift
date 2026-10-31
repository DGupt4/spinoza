//
//  AudioCapture.swift
//  desktop
//

import AVFoundation
import Accelerate
import CoreAudio
import os

// MARK: - Error

enum AudioCaptureError: LocalizedError {
    case formatUnavailable
    case deviceNotFound
    case captureUnavailable

    var errorDescription: String? {
        switch self {
        case .formatUnavailable: return "Could not configure 16 kHz mono audio capture format."
        case .deviceNotFound:    return "The selected audio input device was not found."
        case .captureUnavailable: return "Could not start audio capture from the selected microphone."
        }
    }
}

// MARK: - InputDevice

/// Lightweight representation of an audio input device.
struct InputDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

// MARK: - AudioCapture

/// Captures microphone audio and resamples to 16 kHz mono Float32 PCM.
/// Completely independent of any transcription model — wire it up in the engine.
///
/// Uses `AVCaptureSession` with an explicitly selected input device rather than
/// `AVAudioEngine`. An idle `AVAudioEngine` keeps its input node bound to the default
/// device, which pins Bluetooth headphones into HFP (muffled, 24 kHz mono) and makes
/// the app participate in every default-device change. `AVCaptureSession` only holds
/// the device that was explicitly chosen, and the whole session is torn down in
/// `stop()` so the microphone (and any Bluetooth link) is released between dictations.
final class AudioCapture: NSObject {

    /// Sample rate required by most speech models.
    static let sampleRate: Double = 16_000

    /// Samples per chunk delivered to onChunk.
    /// 1600 = 100 ms at 16 kHz — drives both the speech model feed rate and VU meter update rate.
    /// Increasing this reduces CPU overhead; decreasing it lowers latency.
    var chunkSamples: Int = 1_600  // 16_000 Hz × 0.1 s

    /// Fires on the main thread with exactly chunkSamples new samples (a delta).
    var onChunk: (([Float]) -> Void)?

    /// Fires on the main thread with a smoothed RMS value (0–1) after each capture callback.
    var onLevel: ((Float) -> Void)?

    // MARK: - Private

    /// Serial queue that owns the capture session and all audio processing.
    private let audioQueue = DispatchQueue(
        label: "com.spinoza.voice.audio",
        qos: .userInteractive
    )

    private var session: AVCaptureSession?
    private var output:  AVCaptureAudioDataOutput?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    /// UID of the preferred input device. Empty means "system default".
    /// Written on `audioQueue` so it is ordered with start/stop.
    private var preferredUID: String = ""

    /// Smoothed RMS for visualization (0–1). Lives on audioQueue.
    private var smoothedLevel: Float = 0

    // Gain normalization state (lives on audioQueue).
    private static let targetRMS: Float = 0.05
    private static let silenceThreshold: Float = 0.005
    private static let maxGain: Float = 10.0
    private var smoothedGain: Float = 1.0

    private var accumulated: [Float] = []
    private var accumulatedReadIndex: Int = 0

    /// The model-facing format: 16 kHz mono Float32.
    private static let targetFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate:   AudioCapture.sampleRate,
            channels:     1,
            interleaved:  false
        ) else {
            fatalError("Could not create the 16 kHz mono capture format")
        }
        return format
    }()

    // MARK: - Device Enumeration

    /// Returns all available audio input devices on the system.
    static func availableDevices() -> [InputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> InputDevice? in
            // Check that this device has input channels
            var inputScope = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputScope, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }

            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPointer.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputScope, 0, nil, &streamSize, bufferListPointer) == noErr else { return nil }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { return nil }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)

            return InputDevice(id: deviceID, uid: uid as String, name: name as String)
        }
    }

    // MARK: - Device Selection

    /// Stores the preferred input device. No audio hardware is touched here — the
    /// device is bound when a capture session starts. Pass an empty UID for system default.
    func setPreferredDevice(uid: String) {
        audioQueue.async { [weak self] in
            self?.preferredUID = uid
        }
    }

    // MARK: - Lifecycle

    /// Starts a fresh capture session bound to the preferred device.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: AudioCaptureError.captureUnavailable)
                    return
                }
                do {
                    try self.startLocked()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops capture, releases the microphone/Bluetooth link, and returns any samples
    /// that did not fill a full chunk.
    @discardableResult
    func stop() async -> [Float] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            audioQueue.async { [weak self] in
                continuation.resume(returning: self?.stopLocked() ?? [])
            }
        }
    }

    /// Runs on audioQueue.
    private func startLocked() throws {
        // Reset per-session processing state.
        accumulated          = []
        accumulatedReadIndex = 0
        converter            = nil
        converterSourceFormat = nil
        smoothedGain         = 1.0

        guard let device = resolveCaptureDevice() else {
            throw AudioCaptureError.deviceNotFound
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        var configurationCommitted = false
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw AudioCaptureError.captureUnavailable
            }
            session.addInput(input)

            let dataOutput = AVCaptureAudioDataOutput()
            dataOutput.setSampleBufferDelegate(self, queue: audioQueue)
            guard session.canAddOutput(dataOutput) else {
                throw AudioCaptureError.captureUnavailable
            }
            session.addOutput(dataOutput)
            session.commitConfiguration()
            configurationCommitted = true

            session.startRunning()
            guard session.isRunning else {
                throw AudioCaptureError.captureUnavailable
            }

            self.session = session
            self.output  = dataOutput
            Log.audio.info("Capture started")
        } catch {
            if !configurationCommitted {
                session.commitConfiguration()
            }
            session.stopRunning()
            throw error
        }
    }

    /// Runs on audioQueue.
    private func stopLocked() -> [Float] {
        if let session {
            output?.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
        }
        session              = nil
        output               = nil
        converter            = nil
        converterSourceFormat = nil

        let remainder        = Array(accumulated[accumulatedReadIndex...])
        accumulated          = []
        accumulatedReadIndex = 0
        return remainder
    }

    /// Resolves the preferred UID to an `AVCaptureDevice`.
    /// Falls back to matching by name when the CoreAudio UID and AVFoundation UID differ,
    /// then to the system default input.
    private func resolveCaptureDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices

        if !preferredUID.isEmpty {
            if let exact = devices.first(where: { $0.uniqueID == preferredUID }) {
                return exact
            }
            if let name = Self.availableDevices().first(where: { $0.uid == preferredUID })?.name,
               let byName = devices.first(where: { $0.localizedName == name }) {
                return byName
            }
            Log.audio.warning("Preferred input device not found; using system default")
        }
        return AVCaptureDevice.default(for: .audio)
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Runs on audioQueue.
        guard let buffer = pcmBuffer(from: sampleBuffer),
              let samples = resampledSamples(from: buffer) else { return }
        process(samples)
    }

    /// Copies the sample buffer's audio into an AVAudioPCMBuffer.
    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        var asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bufferCount = isNonInterleaved ? max(1, Int(asbd.mChannelsPerFrame)) : 1

        // AudioBufferList is a flexible-length struct: one AudioBuffer plus any extra channels.
        let byteCount = MemoryLayout<AudioBufferList>.size
            + (bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer,
            bufferListSize: byteCount,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let sourceList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let sourceFormat = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { return nil }

        pcm.frameLength = frameCount
        let destinationList = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard destinationList.count >= sourceList.count else { return nil }

        for index in 0..<sourceList.count {
            let source      = sourceList[index]
            let destination = destinationList[index]
            let bytes = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))
            guard bytes > 0,
                  let sourceData = source.mData,
                  let destinationData = destination.mData
            else { continue }
            memcpy(destinationData, sourceData, bytes)
        }
        return pcm
    }

    /// Converts the captured buffer to 16 kHz mono Float32 when needed.
    private func resampledSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let format = buffer.format

        // Fast path: the capture pipeline already produced the target format.
        if format.commonFormat == .pcmFormatFloat32,
           format.channelCount == 1,
           format.sampleRate == Self.sampleRate,
           let data = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        guard let converter = converter(for: format) else { return nil }
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * Self.sampleRate / format.sampleRate
        ) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error,
              conversionError == nil,
              output.frameLength > 0,
              let data = output.floatChannelData?[0]
        else { return nil }

        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    private func converter(for sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        if let converter,
           let current = converterSourceFormat,
           current.sampleRate == sourceFormat.sampleRate,
           current.channelCount == sourceFormat.channelCount,
           current.isInterleaved == sourceFormat.isInterleaved {
            return converter
        }
        guard let newConverter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat) else {
            return nil
        }
        newConverter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter             = newConverter
        converterSourceFormat = sourceFormat
        return newConverter
    }

    // MARK: - Processing (runs on audioQueue)

    private func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Visualization RMS is computed on the RAW samples (pre-gain) so the VU
        // meter reflects actual input loudness rather than the AGC-equalized signal.
        var rawRMS: Float = 0
        vDSP_rmsqv(samples, 1, &rawRMS, vDSP_Length(samples.count))

        // RMS-based gain normalization: boost quiet audio to a target level
        // for the ASR feed (does NOT affect the visualization).
        var shaped = samples
        if rawRMS > Self.silenceThreshold {
            let rawGain = min(Self.targetRMS / rawRMS, Self.maxGain)
            smoothedGain = 0.9 * smoothedGain + 0.1 * rawGain
            var gain = smoothedGain
            vDSP_vsmul(shaped, 1, &gain, &shaped, 1, vDSP_Length(shaped.count))
            var lo: Float = -1.0, hi: Float = 1.0
            vDSP_vclip(shaped, 1, &lo, &hi, &shaped, 1, vDSP_Length(shaped.count))
        }

        accumulated.append(contentsOf: shaped)
        checkChunk()

        // Map raw RMS (typical speech: ~0.005–0.1) to 0–1 with a perceptual curve,
        // then low-pass to avoid jittery bars. α=0.7 on new value ≈ 100 ms smoothing.
        let scaled = min(sqrt(rawRMS) * 5.0, 1.0)
        smoothedLevel = 0.3 * smoothedLevel + 0.7 * scaled
        let level = smoothedLevel
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    private func checkChunk() {
        // precondition: running on audioQueue
        while accumulated.count - accumulatedReadIndex >= chunkSamples {
            let start = accumulatedReadIndex
            let end   = start + chunkSamples
            let chunk = Array(accumulated[start..<end])
            accumulatedReadIndex = end
            DispatchQueue.main.async { [weak self] in self?.onChunk?(chunk) }
        }
        // Compact: reclaim memory once we've consumed a full window worth of data.
        // This keeps the array small while avoiding per-chunk O(N) shifts.
        if accumulatedReadIndex >= chunkSamples * 16 {
            accumulated.removeFirst(accumulatedReadIndex)
            accumulatedReadIndex = 0
        }
    }
}
