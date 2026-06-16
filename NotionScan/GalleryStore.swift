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
    /// Human-readable name of the destination database, captured at upload time so
    /// the gallery can show where a photo went without re-fetching the database list
    /// (and so it survives even if the integration later loses access to it).
    var databaseName: String?
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
                               databaseName: nil,
                               pageURL: nil,
                               errorMessage: nil)
        items.insert(item, at: 0)
        save()
        return item
    }

    func delete(_ id: UUID) {
        delete([id])
    }

    /// Removes several photos at once — their image files and metadata. Used by
    /// the gallery's multiselect "Delete" action. A single `save()` at the end
    /// keeps one write to disk no matter how many photos are removed.
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            try? FileManager.default.removeItem(at: imageURL(for: item))
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func markUploading(_ id: UUID) {
        update(id) { $0.status = .uploading; $0.errorMessage = nil }
    }

    func markUploaded(_ id: UUID, pageURL: String?, databaseID: String?, databaseName: String?) {
        update(id) {
            $0.status = .uploaded
            $0.pageURL = pageURL
            $0.databaseID = databaseID
            $0.databaseName = databaseName
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
                databaseName: String?,
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
            markUploaded(itemID, pageURL: response.url, databaseID: databaseID, databaseName: databaseName)
            return response
        } catch {
            markFailed(itemID,
                       error: (error as? NotionError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    /// Retries every *failed* item in `ids`, one at a time so the uploads don't
    /// race each other (mirroring auto mode's sequential queue in
    /// `AutoUploadManager`). Items in `ids` that aren't failed are skipped, so
    /// callers can pass a whole multiselect set without filtering first. Each
    /// item's status updates live as it uploads. Returns the number that failed
    /// again, so the caller can surface a summary if it wants to.
    @discardableResult
    func retryFailed(ids: Set<UUID>,
                     client: NotionClient,
                     databaseID: String,
                     databaseName: String?,
                     saveToPhotos: Bool) async -> Int {
        // Snapshot the failed targets up front: `upload` mutates `items` as it
        // runs, so iterating the live array while it changes would be fragile.
        let targets = items.filter { ids.contains($0.id) && $0.status == .failed }
        var failures = 0
        for target in targets {
            do {
                _ = try await upload(itemID: target.id,
                                     client: client,
                                     databaseID: databaseID,
                                     databaseName: databaseName,
                                     saveToPhotos: saveToPhotos)
            } catch {
                failures += 1
            }
        }
        return failures
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
        var loaded = decoded.filter {
            FileManager.default.fileExists(atPath: imageURL(for: $0).path)
        }
        // An upload only makes progress while the app is running — the async task
        // that does the work dies with the process. So any item still marked
        // `.uploading` (interrupted mid-upload) or `.pending` (captured but never
        // sent) when we load at launch was stranded by the app closing. Surface
        // these as `.failed` so they're flagged in the gallery and can be retried,
        // instead of spinning forever or sitting silently un-uploaded.
        var didReconcile = false
        for index in loaded.indices
        where loaded[index].status == .uploading || loaded[index].status == .pending {
            loaded[index].status = .failed
            loaded[index].errorMessage = Self.interruptedMessage
            didReconcile = true
        }
        items = loaded
        if didReconcile { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: metadataURL)
        }
    }

    /// Shown on photos whose upload was cut short by the app closing (see `load`).
    static let interruptedMessage =
        "This photo wasn't uploaded before the app closed. Tap retry to upload it now."

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
