//
//  SidebarView.swift
//  desktop
//

import SwiftUI
import AppKit

enum Tab: String, CaseIterable {
    case dashboard = "Dashboard"
    case settings  = "Settings"

    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .settings:  return "gearshape.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: Tab
    @AppStorage("appearance") private var appearance: AppearanceMode = .light
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Transient state for the playful brand-mark bounce.
    @State private var logoOffset: CGSize = .zero
    @State private var logoRotation: Double = 0
    @State private var logoScale: CGFloat = 1
    @State private var glow: Double = 0
    @State private var isBrandHovered = false
    @State private var cursorPushed = false
    @State private var bounceTask: Task<Void, Never>?

    private var isDark: Bool { appearance == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandButton
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 18)

            // Nav items
            ForEach(Tab.allCases, id: \.self) { tab in
                SidebarRow(
                    icon: tab.icon,
                    title: tab.rawValue,
                    isSelected: selection == tab,
                    scalesOnHover: true
                ) {
                    selection = tab
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            SidebarRow(
                icon: isDark ? "moon.fill" : "sun.max.fill",
                title: isDark ? "Dark" : "Light"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appearance = isDark ? .light : .dark
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 200)
        .background(Color.spinozaBg)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 1)
        }
    }

    // MARK: - Brand mark

    /// Logo + wordmark as one clickable, playful control.
    private var brandButton: some View {
        Button(action: playBrandBounce) {
            HStack(spacing: 8) {
                SpinozaLogo(size: 22)
                    .rotationEffect(.degrees(logoRotation))
                    .scaleEffect(logoScale)
                    .shadow(
                        color: Color.spinozaBlue.opacity(glow * 0.45 + (isBrandHovered ? 0.10 : 0)),
                        radius: 2 + glow * 9
                    )
                    .offset(logoOffset)

                Text("Spinoza")
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(Color.spinozaText)
                    // Trails the orb a hair so the pair feels connected.
                    .offset(x: logoOffset.width * 0.18, y: logoOffset.height * 0.12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .scaleEffect(isBrandHovered ? 1.02 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isBrandHovered)
        }
        .buttonStyle(.plain)
        .onHover { setBrandHovered($0) }
        .onDisappear { popBrandCursor() }
        .accessibilityLabel("Spinoza")
        .accessibilityAddTraits(.isButton)
        .help("Spinoza")
    }

    /// Dart away on a random vector, then spring back to rest. A new click
    /// cancels the pending return, so rapid clicks always settle at center.
    private func playBrandBounce() {
        bounceTask?.cancel()

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) {
                logoOffset = .zero
                logoRotation = 0
                logoScale = 1.05
                glow = 0.7
            }
            bounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    logoScale = 1
                    glow = 0
                }
            }
            return
        }

        let angle = Double.random(in: 0..<(2 * .pi))
        let distance = CGFloat.random(in: 3...9)
        let rotation = (Bool.random() ? 1.0 : -1.0) * Double.random(in: 20...30)

        withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) {
            logoOffset = CGSize(width: CGFloat(cos(angle)) * distance,
                                height: CGFloat(sin(angle)) * distance)
            logoRotation = rotation
            logoScale = 1.12
            glow = 1
        }

        bounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.40, dampingFraction: 0.5)) {
                logoOffset = .zero
                logoRotation = 0
                logoScale = 1
                glow = 0
            }
        }
    }

    private func setBrandHovered(_ hovering: Bool) {
        isBrandHovered = hovering
        guard hovering else {
            popBrandCursor()
            return
        }
        guard !cursorPushed else { return }
        NSCursor.pointingHand.push()
        cursorPushed = true
    }

    private func popBrandCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

private struct SidebarRow: View {
    let icon: String
    let title: String
    var isSelected: Bool = false
    var scalesOnHover: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(isSelected ? Color.spinozaBlue : Color.spinozaTextSub)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(Color.spinozaBlue.opacity(0.12))
                            : AnyShapeStyle(isHovered ? Color.gray.opacity(0.05) : Color.clear)
                    )
            )
            .scaleEffect(scalesOnHover && isHovered && !isSelected ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
    }
}
