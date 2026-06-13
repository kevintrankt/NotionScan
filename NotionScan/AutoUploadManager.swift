//
//  AutoUploadManager.swift
//  NotionScan
//
//  Handles "auto mode": each captured photo is uploaded immediately as its own
//  one-photo Notion page, with no review step. Uploads run sequentially so rapid
//  captures don't race.
//

import Foundation
import UIKit
import Combine

@MainActor
final class AutoUploadManager: ObservableObject {

    /// Number of photos still uploading or queued.
    @Published private(set) var inFlight = 0
    /// Set briefly after a successful upload, to flash a confirmation.
    @Published var lastSucceededAt: Date?
    /// Most recent error message, if any.
    @Published var lastError: String?

    private var queue: [CapturedPhoto] = []
    private var isProcessing = false

    /// Enqueue a photo for immediate upload to `databaseID`.
    func enqueue(_ photo: CapturedPhoto,
                 client: NotionClient,
                 databaseID: String,
                 saveToPhotos: Bool) {
        queue.append(photo)
        inFlight = queue.count + (isProcessing ? 1 : 0)
        Task { await process(client: client, databaseID: databaseID, saveToPhotos: saveToPhotos) }
    }

    private func process(client: NotionClient, databaseID: String, saveToPhotos: Bool) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        while !queue.isEmpty {
            let photo = queue.removeFirst()
            inFlight = queue.count + 1
            do {
                let fileID = try await client.uploadImage(photo.jpegData)
                let title = "NotionScan \(Self.titleFormatter.string(from: Date()))"
                try await client.createBatchPage(
                    databaseId: databaseID,
                    title: title,
                    fileUploadIDs: [fileID]
                )
                if saveToPhotos {
                    await PhotoLibrarySaver.save([photo.image])
                }
                lastSucceededAt = Date()
                lastError = nil
            } catch {
                lastError = (error as? NotionError)?.errorDescription ?? error.localizedDescription
            }
            inFlight = queue.count
        }
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
