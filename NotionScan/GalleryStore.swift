//
//  GalleryStore.swift
//  NotionScan
//
//  Persistent, on-device gallery of every photo the app has captured, with each
//  photo's Notion upload status. Images are stored as JPEG files; metadata is a
//  JSON sidecar. This also doubles as the upload history (with retry).
//

import Foundation
import UIKit
import Combine

enum UploadStatus: String, Codable {
    case pending      // captured, not yet uploaded
    case uploading
    case uploaded
    case failed
}

struct GalleryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var imageFilename: String
    var status: UploadStatus
    var databaseID: String?
    var pageURL: String?
    var errorMessage: String?
}

@MainActor
final class GalleryStore: ObservableObject {

    @Published private(set) var items: [GalleryItem] = []

    private let directory: URL
    private let metadataURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Gallery", isDirectory: true)
        metadataURL = directory.appendingPathComponent("items.json")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading images

    func imageURL(for item: GalleryItem) -> URL {
        directory.appendingPathComponent(item.imageFilename)
    }

    func data(for item: GalleryItem) -> Data? {
        try? Data(contentsOf: imageURL(for: item))
    }

    // MARK: - Mutations

    /// Persists a freshly captured photo and returns its new gallery item.
    @discardableResult
    func add(_ photo: CapturedPhoto) -> GalleryItem {
        let filename = "\(photo.id.uuidString).jpg"
        try? photo.jpegData.write(to: directory.appendingPathComponent(filename))
        let item = GalleryItem(id: photo.id,
                               createdAt: Date(),
                               imageFilename: filename,
                               status: .pending,
                               databaseID: nil,
                               pageURL: nil,
                               errorMessage: nil)
        items.insert(item, at: 0)
        save()
        return item
    }

    func delete(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: imageURL(for: item))
        }
        items.removeAll { $0.id == id }
        save()
    }

    func markUploading(_ id: UUID) {
        update(id) { $0.status = .uploading; $0.errorMessage = nil }
    }

    func markUploaded(_ id: UUID, pageURL: String?, databaseID: String?) {
        update(id) {
            $0.status = .uploaded
            $0.pageURL = pageURL
            $0.databaseID = databaseID
            $0.errorMessage = nil
        }
    }

    func markFailed(_ id: UUID, error: String) {
        update(id) { $0.status = .failed; $0.errorMessage = error }
    }

    // MARK: - Upload (single photo -> single page)

    /// Uploads one gallery item as its own Notion page and updates its status.
    /// Used by auto mode and by manual retries from the gallery.
    @discardableResult
    func upload(itemID: UUID,
                client: NotionClient,
                databaseID: String,
                saveToPhotos: Bool) async throws -> CreatePageResponse {
        guard let item = items.first(where: { $0.id == itemID }),
              let jpeg = data(for: item) else {
            throw NotionError.network("This photo's data is missing.")
        }
        markUploading(itemID)
        do {
            let fileID = try await client.uploadImage(jpeg)
            let title = "NotionScan \(Self.titleFormatter.string(from: item.createdAt))"
            let response = try await client.createBatchPage(
                databaseId: databaseID,
                title: title,
                fileUploadIDs: [fileID]
            )
            if saveToPhotos, let image = UIImage(data: jpeg) {
                await PhotoLibrarySaver.save([image])
            }
            markUploaded(itemID, pageURL: response.url, databaseID: databaseID)
            return response
        } catch {
            markFailed(itemID,
                       error: (error as? NotionError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    // MARK: - Private

    private func update(_ id: UUID, _ transform: (inout GalleryItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        transform(&items[index])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([GalleryItem].self, from: data) else {
            return
        }
        // Drop entries whose image file is gone.
        items = decoded.filter {
            FileManager.default.fileExists(atPath: imageURL(for: $0).path)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: metadataURL)
        }
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
