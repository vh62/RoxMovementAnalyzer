//
//  RoxMovementAnalyzerApp.swift
//  RoxMovementAnalyzer
//
//  Created by Vikram Ho on 27/7/2026.
//

import SwiftUI

@main
struct RoxMovementAnalyzerApp: App {
    init() {
        // Load and warm the pose model off the main thread so the first live-analysis frame is fast.
        Task.detached(priority: .utility) {
            SharedPoseEstimator.prewarm()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
