//
//  ReviewView.swift
//  NotionScan
//
//  Review a captured batch: delete bad shots, choose the destination database,
//  optionally save to Photos, then upload as a single Notion page.
//

import SwiftUI

struct ReviewView: View {
    @ObservedObject var camera: CameraModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var databases: [NotionDatabase] = []
    @State private var selectedDatabaseID: String?
    @State private var saveToPhotos = false
    @State private var isLoadingDatabases = false

    @State private var uploadState: UploadState = .idle
    @State private var errorMessage: String?

    private enum UploadState: Equatable {
        case idle
        case uploading(done: Int, total: Int)
        case creatingPage
        case success
    }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    photoGrid
                    destinationSection
                    Toggle("Save to Photos", isOn: $saveToPhotos)
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Review \(camera.capturedPhotos.count) photo\(camera.capturedPhotos.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                        .disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { Task { await upload() } }
                        .disabled(!canUpload)
                }
            }
            .overlay { uploadOverlay }
            .alert("Upload failed",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                saveToPhotos = settings.saveToPhotoLibraryByDefault
                selectedDatabaseID = settings.defaultDatabaseID
                await loadDatabases()
            }
        }
        .interactiveDismissDisabled(isUploading)
    }

    // MARK: - Sections

    private var photoGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(camera.capturedPhotos) { photo in
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: photo.image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 100)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button {
                        camera.removePhoto(photo)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .padding(4)
                    }
                    .disabled(isUploading)
                }
            }
        }
        .padding(.horizontal)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination database")
                .font(.headline)
                .padding(.horizontal)

            if isLoadingDatabases {
                HStack {
                    ProgressView()
                    Text("Loading databases…").foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            } else if databases.isEmpty {
                Text("No databases found. Make sure your integration is shared with the database in Notion (••• → Connections).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                Picker("Database", selection: $selectedDatabaseID) {
                    ForEach(databases) { db in
                        Text(db.title).tag(db.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var uploadOverlay: some View {
        if isUploading {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text(uploadStatusText)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Derived state

    private var isUploading: Bool {
        switch uploadState {
        case .uploading, .creatingPage: return true
        default: return false
        }
    }

    private var canUpload: Bool {
        !camera.capturedPhotos.isEmpty && selectedDatabaseID != nil && !isUploading
    }

    private var uploadStatusText: String {
        switch uploadState {
        case .uploading(let done, let total): return "Uploading \(done) of \(total)…"
        case .creatingPage: return "Creating Notion page…"
        case .success: return "Done!"
        case .idle: return ""
        }
    }

    // MARK: - Actions

    private func loadDatabases() async {
        guard let client = settings.makeClient() else { return }
        isLoadingDatabases = true
        defer { isLoadingDatabases = false }
        do {
            let result = try await client.listDatabases()
            databases = result
            if selectedDatabaseID == nil || !result.contains(where: { $0.id == selectedDatabaseID }) {
                selectedDatabaseID = result.first(where: { $0.id == settings.defaultDatabaseID })?.id
                    ?? result.first?.id
            }
        } catch {
            errorMessage = (error as? NotionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func upload() async {
        guard let client = settings.makeClient(),
              let databaseID = selectedDatabaseID,
              let database = databases.first(where: { $0.id == databaseID }) else { return }

        let photos = camera.capturedPhotos
        let total = photos.count

        do {
            var fileUploadIDs: [String] = []
            uploadState = .uploading(done: 0, total: total)
            for (index, photo) in photos.enumerated() {
                let id = try await client.uploadImage(photo.jpegData)
                fileUploadIDs.append(id)
                uploadState = .uploading(done: index + 1, total: total)
            }

            uploadState = .creatingPage
            let title = "NotionScan \(Self.titleFormatter.string(from: Date()))"
            try await client.createBatchPage(
                databaseId: databaseID,
                titlePropertyName: database.titlePropertyName,
                title: title,
                fileUploadIDs: fileUploadIDs
            )

            if saveToPhotos {
                await PhotoLibrarySaver.save(photos.map(\.image))
            }

            uploadState = .success
            camera.clearBatch()
            dismiss()
        } catch {
            uploadState = .idle
            errorMessage = (error as? NotionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
