//
//  desktopApp.swift
//  desktop
//
//  Created by Dhruv Gupta on 3/9/26.
//

import SwiftUI
import SwiftData
#if DEBUG
import WhisperKit
#endif

// MARK: - App Entry Point

@main
struct DesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Spinoza", id: "main") {
            RootView()
                .environment(appDelegate.coordinator)
        }
        .modelContainer(for: [TranscriptionRecord.self])
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let coordinator = TranscriptionCoordinator()
    private var pillController: PillWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--diagnose-whisper")
            || CommandLine.arguments.contains("--diagnose-whisper-download") {
            runWhisperDiagnostic(
                forceDownload: CommandLine.arguments.contains("--diagnose-whisper-download")
            )
            return
        }
        #endif

        coordinator.start()

        let pill = PillWindowController()
        pill.setup(coordinator: coordinator)
        pillController = pill
    }

    #if DEBUG
    /// Headless diagnostic entry point: `Spinoza --diagnose-whisper`.
    /// Loads the Whisper model through the exact same path the app uses, prints
    /// the full error (including NSError domain/code/userInfo) to stderr, and exits.
    /// Never affects normal launches.
    private func runWhisperDiagnostic(forceDownload: Bool) {
        let stderr = FileHandle.standardError
        func log(_ message: String) {
            stderr.write(Data((message + "\n").utf8))
        }

        // Hard safety valve so a hung network call can never wedge the diagnostic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
            log("DIAGNOSTIC TIMEOUT after 240s")
            exit(3)
        }

        Task { @MainActor in
            let manager = self.coordinator.speechModelManager
            let fm = FileManager.default
            let folder = WhisperModelManager.modelFolder
            let tokenizerFolder = WhisperModelManager.tokenizerCacheFolder

            log("=== Whisper diagnostic ===")
            log("downloadBase: \(WhisperModelManager.downloadBase.path)")
            log("modelFolder:  \(folder.path)")
            log("tokenizerFolder: \(tokenizerFolder.path)")
            log("modelFolder exists: \(fm.fileExists(atPath: folder.path))")
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "TextDecoderContextPrefill.mlmodelc", "config.json"] {
                log("  \(name): \(fm.fileExists(atPath: folder.appendingPathComponent(name).path))")
            }
            log("tokenizer.json: \(fm.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer.json").path))")
            log("tokenizer_config.json: \(fm.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer_config.json").path))")
            log("readiness snapshot: isReady=\(manager.isReady) isDownloading=\(manager.isDownloading) error=\(manager.downloadError ?? "nil")")

            if forceDownload {
                log("Calling downloadModel()...")
                manager.downloadModel()
                let deadline = Date().addingTimeInterval(200)
                while manager.isDownloading && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                log("after downloadModel(): isReady=\(manager.isReady) isDownloading=\(manager.isDownloading) progress=\(manager.downloadProgress) error=\(manager.downloadError ?? "nil")")
            }

            do {
                let kit = try await manager.loadedTranscriber()
                log("LOAD SUCCEEDED")
                log("  modelState: \(kit.modelState)")
                log("  tokenizer loaded: \(kit.tokenizer != nil)")
                log("  modelVariant: \(kit.modelVariant)")
                log("  modelFolder: \(kit.modelFolder?.path ?? "nil")")

                // Trivial end-to-end check: decode one second of silence.
                log("Running 1s silence transcription...")
                let silence = [Float](repeating: 0, count: 16_000)
                let results = try await kit.transcribe(audioArray: silence)
                log("TRANSCRIBE SUCCEEDED: \(results.map(\.text))")
                log("DIAGNOSTIC RESULT: OK")
                exit(0)
            } catch {
                log("DIAGNOSTIC RESULT: FAILED")
                log("manager.downloadError: \(manager.downloadError ?? "nil")")
                log("error debugDescription: \(String(reflecting: error))")
                log("error localizedDescription: \(error.localizedDescription)")
                let ns = error as NSError
                log("NSError domain: \(ns.domain)")
                log("NSError code: \(ns.code)")
                log("NSError userInfo: \(ns.userInfo)")
                var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                var depth = 0
                while let current = underlying, depth < 8 {
                    log("  underlying[\(depth)] domain: \(current.domain) code: \(current.code) userInfo: \(current.userInfo)")
                    underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
                    depth += 1
                }
                exit(1)
            }
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        pillController?.tearDown()
    }
}

// MARK: - RootView

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionCoordinator.self) private var coordinator
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appearance") private var appearance: AppearanceMode = .light
    @State private var selection: Tab = .dashboard
    @State private var showOnboarding = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection)

            Group {
                switch selection {
                case .dashboard:
                    DashboardView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 600)
        .frame(idealWidth: 900, idealHeight: 620)
        .background(Color.spinozaBg)
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            coordinator.configure(with: modelContext)

            if !onboardingComplete {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environment(coordinator)
                .interactiveDismissDisabled()
        }
        .onChange(of: showOnboarding) { _, isShowing in
            if !isShowing { onboardingComplete = true }
        }
        .onChange(of: onboardingComplete) { _, complete in
            if !complete { showOnboarding = true }
        }
    }
}
