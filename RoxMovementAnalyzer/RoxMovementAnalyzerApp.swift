//
//  RoxMovementAnalyzerApp.swift
//  RoxMovementAnalyzer
//
//  Created by Vikram Ho on 27/7/2026.
//

import SwiftUI

@main
struct RoxMovementAnalyzerApp: App {
    /// App-scoped so a session export outlives the screen that started it.
    @State private var exportService = SessionExportService()

    init() {
        // Both off the main thread so neither slows the launch.
        Task.detached(priority: .utility) {
            // Load and warm the pose model so the first live-analysis frame is fast.
            SharedPoseEstimator.prewarm()
            // Clear out exports left behind by earlier sessions or interrupted jobs.
            SessionExportStore.pruneStaleExports()
            ImportedVideoStore.pruneStaleImports()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(exportService)
        }
    }
}
