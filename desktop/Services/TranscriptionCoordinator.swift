//
//  TranscriptionCoordinator.swift
//  desktop
//

import AVFoundation
import Foundation
import AppKit
import CoreGraphics
import Observation
import SwiftData
import os

// MARK: - Model

@Model
final class TranscriptionRecord {
    var id: UUID
    var text: String
    var createdAt: Date

    init(text: String) {
        self.id        = UUID()
        self.text      = text
        self.createdAt = Date()
    }
}

// MARK: - Coordinator

/// Owns the full dictation pipeline: hotkey -> WhisperEngine -> paste + history.
/// Engine is always WhisperEngine; history and vocabulary live in SwiftData.
@Observable
@MainActor
final class TranscriptionCoordinator {

    // MARK: - Observable state

    private(set) var isRecording:          Bool     = false
    private(set) var targetAppIcon:        NSImage? = nil
    /// Live partial text updated by the engine while a session is in progress.
    private(set) var currentTranscription: String = ""
    private(set) var statusMessage:        String = "Ready to dictate"
    /// Whether the global hotkey tap is active (Accessibility permission granted).
    private(set) var isHotkeyActive:       Bool   = false
    /// Whether the app has microphone permission.
    private(set) var isMicrophoneGranted:  Bool   = false

    // MARK: - Public sub-managers (exposed for UI observation)

    let speechModelManager  = WhisperModelManager()

    // MARK: - Private

    private let hotkey = HotkeyManager()
    private var priorApp: NSRunningApplication?
    /// The authoritative final text from the most recent session.
    private var lastFinalText: String = ""
    /// Incremented for every new recording so stale async work cannot affect a newer session.
    private var sessionID = 0
    let engine: WhisperEngine

    /// Injected by RootView after the SwiftData model container is ready.
    private(set) var modelContext: ModelContext?
    private var didMigrateLegacyHistory = false

    private static let legacyHistoryKey    = "transcriptionHistory"

    // MARK: - Init

    init() {
        engine = WhisperEngine(modelManager: speechModelManager)
        engine.delegate = self

        // Apply the persisted device choice at launch. This only records a preference;
        // no audio hardware is touched until a dictation starts.
        let savedUID = UserDefaults.standard.string(forKey: "selectedAudioDeviceUID") ?? ""
        engine.setPreferredInputDevice(uid: savedUID)
    }

    // MARK: - ModelContext injection

    func configure(with context: ModelContext) {
        modelContext = context
        guard !didMigrateLegacyHistory else { return }
        didMigrateLegacyHistory = true
        performMigrationIfNeeded(context: context)
    }

    // MARK: - Legacy migration (runs once)

    private func performMigrationIfNeeded(context: ModelContext) {
        let ud = UserDefaults.standard

        if let data = ud.data(forKey: Self.legacyHistoryKey) {
            struct LegacyEntry: Codable { let id: String; let text: String; let timestamp: String }
            if let entries = try? JSONDecoder().decode([LegacyEntry].self, from: data) {
                let fmt = ISO8601DateFormatter()
                for entry in entries {
                    let date   = fmt.date(from: entry.timestamp) ?? Date()
                    let record = TranscriptionRecord(text: entry.text)
                    record.createdAt = date
                    context.insert(record)
                }
                do {
                    try context.save()
                    ud.removeObject(forKey: Self.legacyHistoryKey)
                    Log.coordinator.info("Migrated \(entries.count) history entries to SwiftData")
                } catch {
                    Log.coordinator.error("Migration save failed: \(error) — retaining UserDefaults data for next launch")
                }
            }
        }

    }

    // MARK: - Lifecycle

    func start() {
        hotkey.onKeyDown = { [weak self] in self?.beginRecording() }
        hotkey.onKeyUp   = { [weak self] in self?.endRecording()   }

        // Check mic status on launch (don't prompt yet — that happens on first recording or onboarding).
        refreshMicrophoneStatus()

        // First attempt: prompt: true to show the system alert once.
        do {
            try hotkey.start(prompt: true)
            isHotkeyActive = true
        } catch {
            isHotkeyActive = false
            statusMessage = "Hotkey unavailable: \(error.localizedDescription)"
            Log.coordinator.warning("Hotkey start failed: \(error.localizedDescription)")
            startAccessibilityPolling()
        }

        // Listen for app re-activation (user returns from System Settings) to immediately
        // re-check permissions instead of waiting for the next polling tick.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshMicrophoneStatus()
                if !self.isHotkeyActive {
                    self.retryHotkey()
                }
                // If hotkey was lost mid-recording, forcibly end the session
                if self.isRecording && !self.isHotkeyActive {
                    self.endRecording()
                }
            }
        }

    }

    func retryHotkey() {
        guard !isHotkeyActive else { return }
        hotkey.stop()
        // Retries never re-prompt — the user is already aware.
        do {
            try hotkey.start(prompt: false)
            isHotkeyActive = true
            statusMessage = "Ready to dictate"
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            Log.coordinator.info("Hotkey activated after Accessibility grant")
        } catch {
            isHotkeyActive = false
        }
    }

    private var accessibilityTimer: Timer?

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        // Fallback polling in case the user doesn't return focus to the app.
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if HotkeyManager.isAccessibilityGranted(prompt: false) {
                    self.retryHotkey()
                } else if self.isRecording {
                    // Accessibility was revoked mid-session — stop recording gracefully
                    self.endRecording()
                }
            }
        }
    }

    // MARK: - Microphone permission

    /// Updates `isMicrophoneGranted` to reflect the current AVFoundation authorization state.
    func refreshMicrophoneStatus() {
        isMicrophoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Requests microphone access using the native system dialog.
    /// Returns `true` if the user granted permission.
    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        isMicrophoneGranted = granted
        return granted
    }

    /// Label for the microphone permission button.
    var microphoneActionLabel: String {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            ? "Grant Access"
            : "Open Settings"
    }

    /// Requests mic access when undetermined, otherwise opens the Microphone pane.
    func handleMicrophonePermissionAction() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await requestMicrophoneAccess()
        } else {
            openSystemSettings(.microphone)
        }
    }

    /// Prompts for Accessibility and opens the corresponding System Settings pane.
    func handleAccessibilityPermissionAction() {
        _ = HotkeyManager.isAccessibilityGranted(prompt: true)
        openSystemSettings(.accessibility)
    }

    private func openSystemSettings(_ pane: SystemSettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }

    enum SystemSettingsPane {
        case microphone
        case accessibility

        var url: URL {
            let path: String
            switch self {
            case .microphone:    path = "Privacy_Microphone"
            case .accessibility: path = "Privacy_Accessibility"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)")!
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        guard !isRecording else { return }

        // Pre-flight: ensure microphone permission before touching AVAudioEngine.
        guard isMicrophoneGranted else {
            statusMessage = "Microphone access required — grant it in System Settings → Privacy & Security → Microphone."
            Log.coordinator.warning("Recording blocked: microphone not authorized")
            return
        }

        priorApp = NSWorkspace.shared.frontmostApplication
        targetAppIcon = priorApp?.icon
        DictationSound.start.play()
        isRecording          = true
        sessionID           += 1
        let session          = sessionID
        currentTranscription = ""
        lastFinalText        = ""
        statusMessage        = "Recording…"
        engine.reset()
        Task { @MainActor [weak self] in
            guard let self, self.sessionID == session else { return }
            do {
                try await self.engine.start()
            } catch {
                guard self.sessionID == session else { return }
                self.isRecording   = false
                self.statusMessage = error.localizedDescription
                Log.coordinator.error("engine.start() threw: \(error)")
            }
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording   = false
        DictationSound.stop.play()
        statusMessage = "Transcribing…"

        let fallbackText = currentTranscription
        let session      = sessionID

        Task { @MainActor [weak self] in
            guard let self, self.sessionID == session else { return }

            do {
                try await self.engine.stop()
            } catch {
                guard self.sessionID == session else { return }
                self.statusMessage = "Error: \(error.localizedDescription)"
                Log.coordinator.error("engine.stop() threw: \(error)")
                return
            }

            // A newer session started while this one was finishing — discard the result.
            guard self.sessionID == session else { return }

            // engine.stop() awaits the final transcription and delivers engineDidFinalize
            // before returning, so lastFinalText is already populated here.
            let finalText = self.lastFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastFinalText = ""

            let fullText = finalText.isEmpty
                ? fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                : finalText

            guard !fullText.isEmpty else { self.statusMessage = "Ready to dictate"; return }
            Log.coordinator.info("Transcription committed (\(fullText.count) characters)")

            self.commit(text: fullText)
        }
    }

    // MARK: - Commit & paste

    private func commit(text: String) {
        guard !text.isEmpty else { statusMessage = "Ready to dictate"; return }
        if let ctx = modelContext {
            let record = TranscriptionRecord(text: text)
            ctx.insert(record)
            do {
                try ctx.save()
            } catch {
                Log.coordinator.error("SwiftData save failed: \(error)")
            }
        }
        pasteText(text)
        statusMessage = "Ready to dictate"
    }

    private func pasteText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let target = priorApp
        priorApp = nil

        if let app = target, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.postPaste() }
        } else {
            postPaste()
        }
    }

    private func postPaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
           let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) {
            down.flags = .maskCommand
            up.flags   = .maskCommand
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Public API

    func clearHistory() {
        guard let ctx = modelContext else { return }
        try? ctx.delete(model: TranscriptionRecord.self)
        try? ctx.save()
    }

    /// Records the preferred audio input device by its persistent UID string.
    /// Pass an empty string to use the system default. No audio hardware is bound
    /// here — that happens only when the next dictation session starts.
    func preferInputDevice(uid: String) {
        guard !isRecording else {
            Log.coordinator.warning("Ignoring device switch — recording in progress")
            return
        }
        engine.setPreferredInputDevice(uid: uid)
        Log.coordinator.info("Preferred input device: \(uid.isEmpty ? "System Default" : uid)")
    }
}

// MARK: - TranscriptionEngineDelegate

extension TranscriptionCoordinator: TranscriptionEngineDelegate {
    func engineDidUpdatePartial(_ text: String) {
        // WhisperEngine emits the full current transcript, not a delta.
        currentTranscription = text
    }
    func engineDidFinalize(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastFinalText = trimmed
        currentTranscription = trimmed
    }
    func engineDidFail(_ error: Error) {
        Log.coordinator.error("Engine error: \(error)")
        statusMessage = "Error: \(error.localizedDescription)"
    }
}
