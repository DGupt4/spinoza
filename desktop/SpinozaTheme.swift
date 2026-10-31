//
//  SpinozaTheme.swift
//  desktop
//
//  Design tokens, shared UI components, and logging for the Spinoza Voice UI.
//

import SwiftUI
import AppKit
import os

// MARK: - Theme preference

/// User-selected UI appearance. Persisted in UserDefaults via @AppStorage("appearance").
enum AppearanceMode: String {
    case light
    case dark

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }
}

// MARK: - Colors

extension Color {
    /// Dynamic colors resolve against the effective appearance of the view hierarchy,
    /// so the same token renders correctly in light and dark mode.
    static let spinozaBg          = dynamic(light: Color(hex: "#f5f5f7"), dark: Color(hex: "#1b1b1d"))
    static let spinozaBlue        = Color(hex: "#0771e3")
    static let spinozaCard        = dynamic(light: .white,                dark: Color(hex: "#2a2a2d"))
    static let spinozaBorder      = dynamic(light: Color.black.opacity(0.08),
                                            dark:  Color.white.opacity(0.10))
    static let spinozaText        = dynamic(light: Color(red: 0.10, green: 0.10, blue: 0.11),
                                            dark:  Color(red: 0.95, green: 0.95, blue: 0.96))
    static let spinozaTextSub     = dynamic(light: Color(red: 0.38, green: 0.38, blue: 0.42),
                                            dark:  Color(red: 0.70, green: 0.70, blue: 0.74))
    static let spinozaTextTertiary = dynamic(light: Color(red: 0.58, green: 0.58, blue: 0.62),
                                             dark:  Color(red: 0.55, green: 0.55, blue: 0.60))

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - Logo

/// Gradient circle that mirrors the spinoza.svg logo.
struct SpinozaLogo: View {
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: "#ff7eb3"), location: 0),
                        .init(color: Color(hex: "#65d3ff"), location: 0.5),
                        .init(color: Color(hex: "#84fab0"), location: 1),
                    ],
                    startPoint: UnitPoint(x: 0.3, y: 0),
                    endPoint:   UnitPoint(x: 0.7, y: 1)
                )
            )
            .frame(width: size, height: size)
    }
}

// MARK: - Logging

/// Unified loggers for Spinoza subsystems.
/// Uses Apple's os.Logger — messages appear in Console.app and are
/// automatically stripped from Release builds at the debug level.
enum Log {
    static let coordinator = Logger(subsystem: "com.spinoza.voice", category: "Coordinator")
    static let hotkey      = Logger(subsystem: "com.spinoza.voice", category: "Hotkey")
    static let whisper     = Logger(subsystem: "com.spinoza.voice", category: "Whisper")
    static let audio       = Logger(subsystem: "com.spinoza.voice", category: "Audio")
}

// MARK: - Button Style

struct ElegantButtonStyle: ButtonStyle {
    var isPrimary: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(isPrimary ? Color.white : Color.spinozaText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPrimary ? Color.spinozaBlue : Color.spinozaBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isPrimary ? Color.clear : Color.spinozaBorder, lineWidth: 1)
                    )
            )
            .shadow(color: isPrimary ? Color.spinozaBlue.opacity(0.3) : .clear, radius: 4, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == ElegantButtonStyle {
    static var elegant: ElegantButtonStyle { .init(isPrimary: false) }
    static var elegantPrimary: ElegantButtonStyle { .init(isPrimary: true) }
}

// MARK: - Shared Badge

struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Card Chrome

extension View {
    /// Standard Spinoza card: padded content on a rounded card with a hairline border.
    /// Parameterized because the existing surfaces intentionally use different radii,
    /// shadows, and border colors (dashboard tiles are lighter than settings cards).
    func spinozaCard(
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 16,
        shadowOpacity: Double = 0.04,
        shadowRadius: CGFloat = 8,
        shadowY: CGFloat = 4,
        stroke: Color = Color.primary.opacity(0.06)
    ) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.spinozaCard)
                    .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(stroke, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Model Status Card

/// Shared model download/status card used by Settings and Onboarding.
struct ModelStatusCard: View {
    var manager: WhisperModelManager
    /// When true, the download starts automatically and errors offer "Retry".
    var autoDownload: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(WhisperModelManager.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.spinozaText)
                    Text("\(WhisperModelManager.approximateSize) · Runs on-device")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.spinozaTextSub)
                }

                Spacer()

                if manager.isReady {
                    StatusBadge(label: "Ready", color: .green)
                } else if manager.isDownloading {
                    StatusBadge(label: "Downloading", color: .spinozaBlue)
                } else if manager.downloadError != nil {
                    // Weights may be on disk while the tokenizer or a load is
                    // missing — "Not Downloaded" would be misleading here.
                    StatusBadge(label: "Needs Attention", color: .orange)
                } else {
                    StatusBadge(label: "Not Downloaded", color: .orange)
                }
            }

            if manager.isDownloading {
                ProgressView(value: manager.downloadProgress)
                    .progressViewStyle(.linear)
                    .tint(Color.spinozaBlue)
                Text("\(Int(manager.downloadProgress * 100))% downloaded")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.spinozaTextSub)
            } else if !manager.isReady {
                if let error = manager.downloadError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Button(manager.downloadError == nil ? "Download" : "Retry") {
                    manager.downloadModel()
                }
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
        .onAppear {
            if autoDownload && !manager.isReady && !manager.isDownloading && manager.downloadError == nil {
                manager.downloadModel()
            }
        }
    }
}
