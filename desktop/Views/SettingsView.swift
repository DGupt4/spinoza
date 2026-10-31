//
//  SettingsView.swift
//  desktop
//

import SwiftUI
import AppKit

// MARK: - Hotkey Recorder

@Observable
final class HotkeyRecorder {
    var isRecording = false
    var keyCode: Int = HotkeyManager.storedKeyCode

    private var monitor: Any?

    func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let kc = Int(event.keyCode)
            if event.type == .flagsChanged {
                if HotkeyManager.modifierCodes.contains(kc) && HotkeyManager.isFlagActive(keyCode: kc, flags: event.modifierFlags) {
                    DispatchQueue.main.async { self.save(kc) }
                    return nil
                }
            } else if event.type == .keyDown {
                DispatchQueue.main.async { self.save(kc) }
                return nil
            }
            return event
        }
    }

    func stop() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { stop() }

    private func save(_ kc: Int) {
        keyCode = kc
        UserDefaults.standard.set(kc, forKey: HotkeyManager.keyCodeDefaultsKey)
        stop()
    }
}

// MARK: - View

struct SettingsView: View {
    @Environment(TranscriptionCoordinator.self) var coordinator
    @State private var recorder = HotkeyRecorder()
    @State private var inputDevices: [InputDevice] = []
    @AppStorage("selectedAudioDeviceUID") private var selectedDeviceUID: String = ""
    #if DEBUG
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                modelSection
                inputDeviceSection
                permissionsSection
                hotkeySection
                #if DEBUG
                debugSection
                #endif
            }
            .padding(24)
        }
        .background(Color.spinozaBg)
        .onAppear {
            // Never touch the audio hardware while merely viewing Settings. The saved
            // device preference is applied by the coordinator at launch and bound only
            // when a dictation session actually starts.
            if !coordinator.speechModelManager.isReady && !coordinator.speechModelManager.isDownloading {
                coordinator.speechModelManager.checkReady()
            }
            inputDevices = AudioCapture.availableDevices()
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        SettingsSection(title: "MODEL") {
            ModelStatusCard(manager: coordinator.speechModelManager)
        }
    }

    // MARK: - Input Device Section

    private var inputDeviceSection: some View {
        SettingsSection(title: "INPUT DEVICE") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Microphone")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.spinozaText)
                    Text("Select which microphone to use for dictation")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.spinozaTextSub)
                }

                Spacer()

                Picker("", selection: $selectedDeviceUID) {
                    Text("System Default")
                        .tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name)
                            .tag(device.uid)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .onChange(of: selectedDeviceUID) { _, newUID in
                    coordinator.preferInputDevice(uid: newUID)
                }
            }
            .spinozaCard()
        }
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        SettingsSection(title: "PERMISSIONS") {
            VStack(spacing: 0) {
                PermissionRow(
                    icon: "mic.fill",
                    iconColor: coordinator.isMicrophoneGranted ? Color.spinozaTextSub : .red,
                    title: "Microphone",
                    subtitle: coordinator.isMicrophoneGranted
                        ? "Access granted"
                        : "Required to capture your voice",
                    statusLabel: coordinator.isMicrophoneGranted ? "Granted" : "Required",
                    statusColor: coordinator.isMicrophoneGranted ? .green : .red,
                    buttonLabel: coordinator.microphoneActionLabel,
                    buttonAction: {
                        Task { await coordinator.handleMicrophonePermissionAction() }
                    },
                    showButton: !coordinator.isMicrophoneGranted
                )

                Rectangle()
                    .fill(Color.spinozaBorder)
                    .frame(height: 1)
                    .padding(.horizontal, 14)

                PermissionRow(
                    icon: "accessibility",
                    iconColor: coordinator.isHotkeyActive ? Color.spinozaTextSub : .red,
                    title: "Accessibility",
                    subtitle: coordinator.isHotkeyActive
                        ? "Global hotkey is active"
                        : "Required for global hotkey and paste",
                    statusLabel: coordinator.isHotkeyActive ? "Granted" : "Required",
                    statusColor: coordinator.isHotkeyActive ? .green : .red,
                    buttonLabel: "Grant Access",
                    buttonAction: {
                        coordinator.handleAccessibilityPermissionAction()
                    },
                    showButton: !coordinator.isHotkeyActive
                )
            }
            .spinozaCard(padding: 0)
        }
    }

    // MARK: - Debug Section

    #if DEBUG
    private var debugSection: some View {
        SettingsSection(title: "DEBUG") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reset Onboarding")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.spinozaText)
                    Text("Show the onboarding flow again on next view")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.spinozaTextSub)
                }
                Spacer()
                Button("Reset") {
                    onboardingComplete = false
                }
                .buttonStyle(.elegant)
            }
            .spinozaCard()
        }
    }
    #endif

    // MARK: - Hotkey Section

    private var hotkeySection: some View {
        SettingsSection(title: "HOTKEY") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hold to dictate, release to stop")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.spinozaText)
                    Text("Works in any app when Accessibility is granted")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.spinozaTextSub)
                }
                Spacer()
                Button(action: {
                    if recorder.isRecording { recorder.stop() } else { recorder.start() }
                }) {
                    Text(recorder.isRecording ? "Press any key…" : HotkeyManager.shortLabel(keyCode: recorder.keyCode))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(recorder.isRecording ? Color.spinozaBlue : Color.spinozaTextSub)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(recorder.isRecording ? Color.spinozaBlue.opacity(0.08) : Color(hex: "#e8e8ed"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(recorder.isRecording ? Color.spinozaBlue.opacity(0.4) : Color.black.opacity(0.12), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .spinozaCard()
        }
    }
}

// MARK: - Reusable Components

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.spinozaTextSub)
                .tracking(1.0)
            content
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let statusLabel: String
    let statusColor: Color
    let buttonLabel: String
    let buttonAction: () -> Void
    let showButton: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.spinozaText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.spinozaTextSub)
            }

            Spacer()

            StatusBadge(label: statusLabel, color: statusColor)

            if showButton {
                Button(buttonLabel, action: buttonAction)
                    .buttonStyle(.elegant)
            }
        }
        .padding(14)
    }
}
