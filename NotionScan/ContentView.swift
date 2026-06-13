//
//  ContentView.swift
//  NotionScan
//
//  Root router: shows Onboarding until a token + default database are set,
//  otherwise the Camera home screen.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if settings.isFullyConfigured {
            CameraView()
        } else {
            OnboardingView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
}
