//
//  NotionScanApp.swift
//  NotionScan
//
//  Created by keb on 6/13/26.
//

import SwiftUI

@main
struct NotionScanApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var gallery = GalleryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(gallery)
        }
    }
}
