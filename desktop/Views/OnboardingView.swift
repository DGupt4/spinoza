//
//  OnboardingView.swift
//  desktop
//
//  First-launch onboarding: permissions → model download → hotkey intro.
//

import SwiftUI

// MARK: - OnboardingView

struct OnboardingView: View {
    @Environment(TranscriptionCoordinator.self) private var coordinator
    @Binding var isPresented: Bool

    @State private var step = 0

    private let totalSteps = 5

    var body: some View {
        ZStack {
            Color.spinozaBg.ignoresSafeArea()
            
            // Subtle energetic background
            LinearGradient(
                colors: [Color.spinozaBlue.opacity(0.05), Color.purple.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: step)

            VStack(spacing: 0) {
                // Step content
                ZStack {
                    switch step {
                    case 0: WelcomeStep()
                    case 1: MicrophoneStep()
                    case 2: AccessibilityStep()
                    case 3: ModelDownloadStep()
                    case 4: HotkeyStep(onFinish: markComplete)
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity
                    )
                )
                .id(step)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: step)

                // Nav bar (hidden on final step — it has its own finish button)
                if step < totalSteps - 1 {
                    OnboardingNavBar(
                        step: step,
                        totalSteps: totalSteps,
                        canAdvance: canAdvance,
                        onBack: { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { step -= 1 } },
                        onNext: { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { step += 1 } }
                    )
                }
            }
            .padding(32)
        }
        .frame(width: 480, height: 500)
    }

    // MARK: - Helpers

    private var canAdvance: Bool {
        switch step {
        case 1: return coordinator.isMicrophoneGranted
        case 2: return coordinator.isHotkeyActive
        case 3: return coordinator.speechModelManager.isReady
        default: return true
        }
    }

    private func markComplete() {
        isPresented = false
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            SpinozaLogo(size: 64)

            VStack(spacing: 8) {
                Text("Welcome to Spinoza")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.spinozaText)

                Text("Voice dictation that works in any app.\nHold a key, speak, release — done.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.spinozaTextSub)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 16)
    }
}

// MARK: - Step 1: Microphone

private struct MicrophoneStep: View {
    @Environment(TranscriptionCoordinator.self) private var coordinator

    var body: some View {
        PermissionStep(
            icon: "mic.fill",
            iconColor: coordinator.isMicrophoneGranted ? .green : Color.spinozaBlue,
            title: "Microphone Access",
            description: "Spinoza needs your microphone to capture speech. Your audio never leaves this device.",
            isGranted: coordinator.isMicrophoneGranted,
            grantedLabel: "Access Granted",
            pendingLabel: "Not Yet Granted",
            buttonLabel: coordinator.microphoneActionLabel,
            buttonAction: {
                Task { await coordinator.handleMicrophonePermissionAction() }
            }
        )
    }
}

// MARK: - Step 2: Accessibility

private struct AccessibilityStep: View {
    @Environment(TranscriptionCoordinator.self) private var coordinator

    var body: some View {
        PermissionStep(
            icon: "keyboard",
            iconColor: coordinator.isHotkeyActive ? .green : .orange,
            title: "Accessibility Access",
            description: "Required to detect your hotkey globally and paste transcribed text into any app.",
            isGranted: coordinator.isHotkeyActive,
            grantedLabel: "Access Granted",
            pendingLabel: "Not Yet Granted",
            buttonLabel: "Open Settings",
            buttonAction: {
                coordinator.handleAccessibilityPermissionAction()
            }
        )
    }
}

// MARK: - Step 3: Model Download

private struct ModelDownloadStep: View {
    @Environment(TranscriptionCoordinator.self) private var coordinator

    private var manager: WhisperModelManager { coordinator.speechModelManager }

    var body: some View {
        VStack(spacing: 28) {
            // Icon + title
            VStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.spinozaBlue)

                VStack(spacing: 6) {
                    Text("Download Speech Model")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.spinozaText)

                    Text("Spinoza uses a local AI model — no internet required after download.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.spinozaTextSub)
                        .multilineTextAlignment(.center)
                }
            }

            ModelStatusCard(manager: manager, autoDownload: true)
        }
    }
}

// MARK: - Step 4: Hotkey

private struct HotkeyStep: View {
    let onFinish: () -> Void
    @AppStorage(HotkeyManager.keyCodeDefaultsKey)
    private var hotkeyKeyCode: Int = HotkeyManager.KeyCode.rightShift

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.spinozaBlue)

                VStack(spacing: 6) {
                    Text("Your Dictation Hotkey")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.spinozaText)

                    Text("Hold the key while speaking, then release. Spinoza will transcribe and paste your words instantly.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.spinozaTextSub)
                        .multilineTextAlignment(.center)
                }
            }

            // Hotkey display
            VStack(spacing: 6) {
                Text(HotkeyManager.shortLabel(keyCode: hotkeyKeyCode))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.spinozaText)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: "#e8e8ed"))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
                            )
                    )

                Text("You can change this anytime in Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.spinozaTextSub)
            }

            Button("Start Dictating") {
                onFinish()
            }
            .buttonStyle(.elegantPrimary)
            .scaleEffect(1.1)
        }
    }
}

// MARK: - Shared Permission Step Layout

private struct PermissionStep: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let isGranted: Bool
    let grantedLabel: String
    let pendingLabel: String
    let buttonLabel: String
    let buttonAction: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            // Icon + title
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(iconColor)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isGranted)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.spinozaText)

                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.spinozaTextSub)
                        .multilineTextAlignment(.center)
                }
            }

            // Status + action card
            HStack {
                StatusBadge(
                    label: isGranted ? grantedLabel : pendingLabel,
                    color: isGranted ? .green : .orange
                )

                Spacer()

                if !isGranted {
                    Button(buttonLabel, action: buttonAction)
                        .buttonStyle(.elegantPrimary)
                }
            }
            .spinozaCard(
                cornerRadius: 10,
                padding: 14,
                shadowOpacity: 0.05,
                shadowRadius: 4,
                shadowY: 2,
                stroke: Color.spinozaBorder
            )
        }
    }
}

// MARK: - Nav Bar

private struct OnboardingNavBar: View {
    let step: Int
    let totalSteps: Int
    let canAdvance: Bool
    let onBack: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack {
            // Back
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(step == 0 ? Color.clear : Color.spinozaText)
            }
            .buttonStyle(.plain)
            .disabled(step == 0)

            Spacer()

            // Step dots
            HStack(spacing: 6) {
                ForEach(0 ..< totalSteps - 1, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.spinozaBlue : Color.spinozaBorder)
                        .frame(width: 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: step)
                }
            }

            Spacer()

            // Next
            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(canAdvance ? Color.spinozaText : Color.spinozaTextSub.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canAdvance)
        }
        .padding(.top, 20)
    }
}

