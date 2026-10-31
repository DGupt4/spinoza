//
//  HotkeyManager.swift
//  desktop
//

import CoreGraphics
import AppKit
import ApplicationServices
import os

// MARK: - Error

enum HotkeyError: LocalizedError {
    case accessibilityNotGranted
    var errorDescription: String? {
        "Accessibility access required — open System Settings → Privacy & Security → Accessibility and enable Spinoza."
    }
}

// MARK: - Manager

/// Global hotkey detector using NSEvent monitors.
/// Uses addGlobalMonitorForEvents (other apps) + addLocalMonitorForEvents (this app)
/// to reliably detect hotkeys regardless of which app is focused.
/// Reads `hotkeyKeyCode` from UserDefaults (written by KeyRecorderView in Preferences).
/// Defaults to Right Shift (keyCode 60) if the key is not yet set.
final class HotkeyManager {

    // MARK: - Key Code Constants

    /// Carbon key codes from HIToolbox/Events.h
    enum KeyCode {
        static let command      = 55
        static let leftShift    = 56
        static let rightShift   = 60
        static let leftOption   = 58
        static let rightOption  = 61
        static let leftControl  = 59
        static let rightControl = 62
        static let function_    = 63
        static let `return`     = 36
        static let tab          = 48
        static let space        = 49
        static let delete       = 51
        static let escape       = 53
    }

    // MARK: - Storage

    /// The single UserDefaults key for the chosen hotkey.
    static let keyCodeDefaultsKey = "hotkeyKeyCode"

    /// The persisted hotkey, falling back to Right Shift when unset.
    static var storedKeyCode: Int {
        let value = UserDefaults.standard.integer(forKey: keyCodeDefaultsKey)
        return value == 0 ? KeyCode.rightShift : value
    }

    // MARK: - Key metadata

    /// Single source of truth for every key that can be used as a hotkey.
    private struct KeyInfo {
        let shortLabel: String
        let displayName: String
        let modifierFlag: NSEvent.ModifierFlags?
    }

    private static let keyInfo: [Int: KeyInfo] = [
        KeyCode.command:      .init(shortLabel: "⌘ Command", displayName: "Command ⌘",      modifierFlag: .command),
        KeyCode.leftShift:    .init(shortLabel: "⇧ Shift",   displayName: "Left Shift ⇧",   modifierFlag: .shift),
        KeyCode.rightShift:   .init(shortLabel: "⇧ Shift",   displayName: "Right Shift ⇧",  modifierFlag: .shift),
        KeyCode.leftOption:   .init(shortLabel: "⌥ Option",  displayName: "Left Option ⌥",  modifierFlag: .option),
        KeyCode.rightOption:  .init(shortLabel: "⌥ Option",  displayName: "Right Option ⌥", modifierFlag: .option),
        KeyCode.leftControl:  .init(shortLabel: "⌃ Control", displayName: "Left Control ⌃", modifierFlag: .control),
        KeyCode.rightControl: .init(shortLabel: "⌃ Control", displayName: "Right Control ⌃", modifierFlag: .control),
        KeyCode.function_:    .init(shortLabel: "fn",        displayName: "fn",             modifierFlag: .function),
        KeyCode.`return`:     .init(shortLabel: "Return ↩",  displayName: "Return ↩",       modifierFlag: nil),
        KeyCode.tab:          .init(shortLabel: "Tab ⇥",     displayName: "Tab ⇥",          modifierFlag: nil),
        KeyCode.space:        .init(shortLabel: "Space ␣",   displayName: "Space ␣",        modifierFlag: nil),
        KeyCode.delete:       .init(shortLabel: "Delete ⌫",  displayName: "Delete ⌫",       modifierFlag: nil),
        KeyCode.escape:       .init(shortLabel: "Escape ⎋",  displayName: "Escape ⎋",       modifierFlag: nil),
    ]

    /// Modifier key codes that arrive via flagsChanged events (not keyDown/keyUp).
    static let modifierCodes: Set<Int> = Set(
        keyInfo.filter { $0.value.modifierFlag != nil }.keys
    )

    // MARK: - Properties

    /// Called on the main thread when the watched key is pressed.
    var onKeyDown: (() -> Void)?
    /// Called on the main thread when the watched key is released.
    var onKeyUp: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor:  Any?

    /// Tracks whether the hotkey is currently held down (to avoid repeat-fire).
    private var isKeyDown: Bool = false

    /// Cached key code — updated via UserDefaults observation instead of reading on every event.
    private var cachedKeyCode: Int = HotkeyManager.storedKeyCode
    private var defaultsObserver: NSObjectProtocol?

    // MARK: - Accessibility check

    /// Returns true if this process has Accessibility access.
    /// Pass `prompt: true` to show the system prompt if not yet granted.
    static func isAccessibilityGranted(prompt: Bool = false) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Display name (shared with KeyRecorderView)

    /// Short badge label shown in UI (e.g. "⇧ Shift", "⌥ Option").
    static func shortLabel(keyCode: Int) -> String {
        keyInfo[keyCode]?.shortLabel ?? displayName(keyCode: keyCode)
    }

    /// Human-readable label for a key code. Used by both HotkeyManager and KeyRecorderView.
    static func displayName(keyCode: Int) -> String {
        if let info = keyInfo[keyCode] { return info.displayName }
        // Derive character from key code via keyboard layout
        if let ch = characterFromKeyCode(keyCode), !ch.isEmpty {
            return ch.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// Derives the printable character for a key code using the current keyboard layout.
    private static func characterFromKeyCode(_ keyCode: Int) -> String? {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true) else { return nil }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        let str = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
        // Only return visible ASCII characters
        guard let scalar = str.unicodeScalars.first, scalar.value >= 32 && scalar.value < 127 else { return nil }
        return str
    }

    // MARK: - Lifecycle

    /// - Parameter prompt: Pass `true` only on the very first attempt (e.g. onboarding).
    ///   Subsequent retries should pass `false` to avoid showing the system alert repeatedly.
    func start(prompt: Bool = false) throws {
        if !Self.isAccessibilityGranted(prompt: prompt) {
            Log.hotkey.warning("Accessibility not granted")
            throw HotkeyError.accessibilityNotGranted
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        guard globalMonitor != nil else {
            Log.hotkey.warning("Failed to create global monitor")
            stop()
            throw HotkeyError.accessibilityNotGranted
        }

        observeKeyCodeChanges()
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor  = nil
        isKeyDown     = false
        if let obs = defaultsObserver { NotificationCenter.default.removeObserver(obs) }
        defaultsObserver = nil
    }

    private func observeKeyCodeChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cachedKeyCode = HotkeyManager.storedKeyCode
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        guard keyCode == cachedKeyCode else { return }

        if Self.modifierCodes.contains(keyCode) {
            let down = HotkeyManager.isFlagActive(keyCode: keyCode, flags: event.modifierFlags)
            if down && !isKeyDown {
                isKeyDown = true
                onKeyDown?()
            } else if !down && isKeyDown {
                isKeyDown = false
                onKeyUp?()
            }
        } else {
            switch event.type {
            case .keyDown:
                guard !isKeyDown else { return }
                isKeyDown = true
                onKeyDown?()
            case .keyUp:
                isKeyDown = false
                onKeyUp?()
            default:
                break
            }
        }
    }

    // MARK: - Helpers

    static func isFlagActive(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        keyInfo[keyCode]?.modifierFlag.map(flags.contains) ?? false
    }
}
