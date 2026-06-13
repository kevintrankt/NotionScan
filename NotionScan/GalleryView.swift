//
//  GalleryView.swift
//  NotionScan
//
//  In-app gallery of every captured photo with its Notion upload status.
//  Doubles as the upload history: failed uploads can be retried, uploaded
//  photos link to their Notion page.
//

import SwiftUI

struct GalleryView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var gallery: GalleryStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: GalleryItem?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                if gallery.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(gallery.items) { item in
                                Button { selectedItem = item } label: {
                                    GalleryCell(item: item, url: gallery.imageURL(for: item))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedItem) { item in
                GalleryDetailView(itemID: item.id)
                    .environmentObject(settings)
                    .environmentObject(gallery)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("No photos yet",
                               systemImage: "photo.on.rectangle.angled",
                               description: Text("Photos you capture will appear here with their upload status."))
    }
}

// MARK: - Grid cell

private struct GalleryCell: View {
    let item: GalleryItem
    let url: URL

    var body: some View {
        GalleryThumbnail(url: url)
            .aspectRatio(1, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                StatusBadge(status: item.status)
                    .padding(5)
            }
    }
}

// MARK: - Detail

struct GalleryDetailView: View {
    let itemID: UUID

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var gallery: GalleryStore
    @Environment(\.dismiss) private var dismiss

    @State private var isRetrying = false

    private var item: GalleryItem? {
        gallery.items.first(where: { $0.id == itemID })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let item {
                    ScrollView {
                        VStack(spacing: 16) {
                            GalleryThumbnail(url: gallery.imageURL(for: item), fullSize: true)
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            statusRow(item)

                            if let error = item.errorMessage, item.status == .failed {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            actions(item)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("Photo unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func statusRow(_ item: GalleryItem) -> some View {
        HStack {
            StatusBadge(status: item.status)
            Text(statusText(item.status))
                .font(.headline)
            Spacer()
            Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(_ item: GalleryItem) -> some View {
        VStack(spacing: 12) {
            if let urlString = item.pageURL, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("Open in Notion", systemImage: "arrow.up.forward.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if item.status == .failed || item.status == .pending {
                Button {
                    Task { await retry(item) }
                } label: {
                    HStack {
                        if isRetrying { ProgressView() }
                        Label(item.status == .failed ? "Retry upload" : "Upload now",
                              systemImage: "arrow.up.circle")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying || settings.defaultDatabaseID == nil)
            }

            Button(role: .destructive) {
                gallery.delete(item.id)
                dismiss()
            } label: {
                Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func retry(_ item: GalleryItem) async {
        guard let client = settings.makeClient(),
              let databaseID = settings.defaultDatabaseID else { return }
        isRetrying = true
        defer { isRetrying = false }
        try? await gallery.upload(itemID: item.id,
                                  client: client,
                                  databaseID: databaseID,
                                  saveToPhotos: settings.saveToPhotoLibraryByDefault)
    }

    private func statusText(_ status: UploadStatus) -> String {
        switch status {
        case .pending: return "Not uploaded"
        case .uploading: return "Uploading…"
        case .uploaded: return "Uploaded to Notion"
        case .failed: return "Upload failed"
        }
    }
}

// MARK: - Shared subviews

struct StatusBadge: View {
    let status: UploadStatus

    var body: some View {
        Group {
            switch status {
            case .pending:
                badge("clock.fill", .orange)
            case .uploading:
                ProgressView()
                    .controlSize(.small)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Circle())
            case .uploaded:
                badge("checkmark.circle.fill", .green)
            case .failed:
                badge("exclamationmark.circle.fill", .red)
            }
        }
    }

    private func badge(_ systemName: String, _ color: Color) -> some View {
        Image(systemName: systemName)
            .font(.body)
            .foregroundStyle(.white, color)
            .background(Circle().fill(.black.opacity(0.25)))
    }
}

/// Loads an image off the main thread; downsamples for grid thumbnails.
struct GalleryThumbnail: View {
    let url: URL
    var fullSize: Bool = false

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.gray.opacity(0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fullSize ? .fit : .fill)
            }
        }
        .task(id: url) {
            image = await Self.load(url, fullSize: fullSize)
        }
    }

    private static func load(_ url: URL, fullSize: Bool) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { return nil }
            if fullSize { return image }
            return image.preparingThumbnail(of: CGSize(width: 320, height: 320)) ?? image
        }.value
    }
}
