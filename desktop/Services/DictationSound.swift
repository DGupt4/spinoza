//
//  DictationSound.swift
//  desktop
//

import AppKit

/// Short UI sounds played when a dictation session starts and stops.
///
/// Defaults to macOS system sounds. To use custom audio, drop a .wav/.caf file
/// into the app bundle and change the `bundledName` case below — `NSSound(named:)`
/// resolves bundled resources by filename (without extension) first, then falls
/// back to `/System/Library/Sounds`.
enum DictationSound: String {
    case start = "Purr"
    case stop  = "Pop"

    func play() {
        NSSound(named: rawValue)?.play()
    }
}
