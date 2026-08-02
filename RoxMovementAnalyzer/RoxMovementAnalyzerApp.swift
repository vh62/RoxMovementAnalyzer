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
        // Clear out exports left behind by earlier sessions or interrupted jobs. Off the main
        // thread so scanning the directory cannot slow the launch.
        Task.detached(priority: .utility) {
            SessionExportStore.pruneStaleExports()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(exportService)
        }
    }
}
