//
//  FloatingPillView.swift
//  desktop
//
//  Created by Dhruv Gupta on 3/15/26.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Pill Model (shared observable state)

@Observable
final class PillModel {
    var appIcon: NSImage? = nil
    /// Per-bar heights (0–1) driven by real audio levels.
    static let barCount = 5
    var barLevels: [CGFloat] = Array(repeating: 0, count: PillModel.barCount)
}

// MARK: - Waveform Animation

struct WaveformBars: View {
    var model: PillModel

    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<PillModel.barCount, id: \.self) { i in
                let h = minHeight + model.barLevels[i] * (maxHeight - minHeight)
                Capsule()
                    .fill(LinearGradient(colors: [.cyan, .purple], startPoint: .bottom, endPoint: .top))
                    .frame(width: 3, height: h)
            }
        }
        .frame(height: maxHeight)
        .animation(.spring(response: 0.15, dampingFraction: 0.7, blendDuration: 0.1), value: model.barLevels)
    }
}

// MARK: - Floating Pill View

struct FloatingPillView: View {
    var model: PillModel

    var body: some View {
        let maxLevel = model.barLevels.max() ?? 0
        // Soften and halve the blue aura
        let glowRadius = 2 + (maxLevel * 6)
        let glowOpacity = 0.05 + (maxLevel * 0.15)
        
        HStack(spacing: 8) {
            // App icon — falls back to Spinoza globe if none
            if let icon = model.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 16, height: 16)
                    .clipShape(Circle())
            }

            WaveformBars(model: model)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .fixedSize()
        .background(
            Capsule()
                // Native macOS liquid dark glass
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .opacity(0.7) // Much more transparent!
                // Glossy top rim
                .overlay(
                    Capsule()
                        .stroke(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
                // Shadows
                .shadow(color: .black.opacity(0.30), radius: 16, y: 8)
                .shadow(color: Color(nsColor: .systemBlue).opacity(glowOpacity), radius: glowRadius)
        )
        // Extra padding prevents the window from clipping the shadow into a rectangle
        .padding(32)
    }
}

// MARK: - Pill Window Controller

@MainActor
class PillWindowController: NSObject {
    private var panel:      NSPanel?
    private var hostingView: NSHostingView<FloatingPillView>?
    private var coordinator: TranscriptionCoordinator?
    private let model = PillModel()
    private var levelSink: AnyCancellable?

    func setup(coordinator: TranscriptionCoordinator) {
        self.coordinator = coordinator
        createPanel()
        subscribeLevels()
        observeRecordingState()
    }

    func tearDown() {
        levelSink?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Maps a single RMS level to 5 per-bar values with natural variation.
    private func subscribeLevels() {
        // One scale factor per bar — must match PillModel.barCount
        let scales: [CGFloat] = [0.5, 0.85, 0.65, 1.0, 0.55]
        levelSink = coordinator?.engine.levelPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] rms in
                guard let self else { return }

                // Level is already perceptually scaled and smoothed in AudioCapture —
                // use it directly so the bars reflect actual input loudness.
                let base = CGFloat(rms)

                self.model.barLevels = scales.map { scale in
                    let jitter = CGFloat.random(in: -0.05...0.05)
                    return min(max(base * scale + jitter, 0), 1)
                }
            }
    }

    private func createPanel() {
        guard let screen = NSScreen.main else { return }

        // Build the hosting view once, measure it, then reuse it as the panel's content.
        let hosting = NSHostingView(rootView: FloatingPillView(model: model))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 32
        )

        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level                = .floating
        p.backgroundColor      = .clear
        p.isOpaque             = false
        p.hasShadow            = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView          = hosting

        self.hostingView = hosting
        self.panel       = p
    }

    /// Reactively show/hide the pill and update the app icon when recording state changes.
    private func observeRecordingState() {
        guard let coordinator else { return }
        withObservationTracking {
            let recording = coordinator.isRecording
            let icon      = coordinator.targetAppIcon
            if recording {
                model.appIcon = icon
                resizeAndShow()
            } else {
                panel?.orderOut(nil)
            }
        } onChange: {
            Task { @MainActor [weak self] in self?.observeRecordingState() }
        }
    }

    private func resizeAndShow() {
        guard let panel else { return }
        // Resize panel to fit current content (icon may have changed)
        if let hosting = hostingView {
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            guard let screen = NSScreen.main else { panel.orderFront(nil); return }
            let origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.minY + 32
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        panel.orderFront(nil)
    }
}

// MARK: - Preview

#Preview {
    FloatingPillView(model: PillModel())
        .padding(20)
        .background(Color.gray.opacity(0.3))
}
