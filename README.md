# Spinoza Voice

On-device dictation for macOS. Hold the hotkey, speak, release — the transcript
is pasted into whatever app you were using.

Transcription runs entirely on your Mac with Whisper Large v3 Turbo via
[WhisperKit](https://github.com/argmaxinc/WhisperKit). No account, no cloud, and
no audio leaves the device.

## Download

[Latest release](https://github.com/DGupt4/spinoza/releases/latest) · Apple silicon · macOS 15.6+

## How it works

1. Hold **Right Shift** (configurable) in any app.
2. Speak, then release.
3. The transcript is pasted into the app you started from.

A floating pill shows live audio levels while you dictate.

## Features

- Whisper Large v3 Turbo on-device; the model downloads once (~1.6 GB) and then
  works offline
- Global hotkey: modifier keys or single keys
- Pastes into the frontmost app via Accessibility
- Activity timeline and stats, stored locally with SwiftData
- Microphone picker
- Light and dark appearance

## Requirements

- macOS 15.6 or later on Apple silicon
- Xcode 26 or later to build

## Build

Open `desktop.xcodeproj`, choose the `desktop` scheme, and run. To build a DMG:

```sh
./build_dmg.sh
```

The DMG is written to `build/SpinozaVoice-arm64.dmg`.

## Permissions

- **Microphone** — capture audio.
- **Accessibility** — global hotkey and pasting into other apps.

Both are requested during onboarding.

## Project layout

```
desktop/
  desktopApp.swift          app entry, window, onboarding gate
  Engines/WhisperEngine.swift
  Services/                 hotkey, audio capture, transcription coordinator
  Views/                    dashboard, settings, sidebar, pill, onboarding
  SpinozaTheme.swift        colors, logo, shared components
```

## CI

GitHub Actions builds an arm64-only DMG on pushes to `main` and on pull
requests. Pushing a `v*` tag publishes it as a GitHub Release with the stable
asset name `SpinozaVoice-arm64.dmg`.
