//
//  AutoUploadManager.swift
//  NotionScan
//
//  Handles "auto mode": each captured photo is uploaded immediately as its own
//  one-photo Notion page, with no review step. Uploads run sequentially so rapid
//  captures don't race. The actual upload + status tracking lives in GalleryStore.
//

import Foundation
import Combine

@MainActor
final class AutoUploadManager: ObservableObject {

    /// Number of photos still uploading or queued.
    @Published private(set) var inFlight = 0
    /// Set briefly after a successful upload, to flash a confirmation.
    @Published var lastSucceededAt: Date?
    /// Most recent error message, if any.
    @Published var lastError: String?

    private struct Job {
        let itemID: UUID
        let gallery: GalleryStore
        let client: NotionClient
        let databaseID: String
        let databaseName: String?
        let saveToPhotos: Bool
    }

    private var queue: [Job] = []
    private var isProcessing = false

    func enqueue(itemID: UUID,
                 gallery: GalleryStore,
                 client: NotionClient,
                 databaseID: String,
                 databaseName: String?,
                 saveToPhotos: Bool) {
        queue.append(Job(itemID: itemID,
                         gallery: gallery,
                         client: client,
                         databaseID: databaseID,
                         databaseName: databaseName,
                         saveToPhotos: saveToPhotos))
        inFlight = queue.count + (isProcessing ? 1 : 0)
        Task { await process() }
    }

    private func process() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        while !queue.isEmpty {
            let job = queue.removeFirst()
            inFlight = queue.count + 1
            do {
                try await job.gallery.upload(itemID: job.itemID,
                                             client: job.client,
                                             databaseID: job.databaseID,
                                             databaseName: job.databaseName,
                                             saveToPhotos: job.saveToPhotos)
                lastSucceededAt = Date()
                lastError = nil
            } catch {
                lastError = (error as? NotionError)?.errorDescription ?? error.localizedDescription
            }
            inFlight = queue.count
        }
    }
}
