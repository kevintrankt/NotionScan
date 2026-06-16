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

    /// Multiselect state. Long-pressing a photo flips `isSelecting` on; while it's
    /// on, a tap toggles a photo's membership in `selection` instead of opening
    /// its detail sheet. `isRetrying` disables the controls during a mass retry.
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var isRetrying = false
    @State private var showDeleteConfirmation = false

    /// A fixed three-column grid so every photo lands in a perfect row of three,
    /// regardless of device width. `.flexible()` splits the available width evenly.
    private static let gridSpacing: CGFloat = 4
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
                                count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if gallery.items.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar }
            }
            .sheet(item: $selectedItem) { item in
                GalleryDetailView(itemID: item.id)
                    .environmentObject(settings)
                    .environmentObject(gallery)
            }
            .confirmationDialog(deleteConfirmationTitle,
                                isPresented: $showDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
            // A light tap of haptic feedback when selection mode turns on, since
            // it's triggered by an (invisible) long-press rather than a control.
            .sensoryFeedback(.selection, trigger: isSelecting)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                ForEach(gallery.items) { item in
                    GalleryCell(item: item,
                                url: gallery.imageURL(for: item),
                                isSelecting: isSelecting,
                                isSelected: selection.contains(item.id))
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(item) }
                        .onLongPressGesture(minimumDuration: 0.4) { beginSelecting(item) }
                }
            }
            .padding(Self.gridSpacing)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { endSelecting() }
                    .disabled(isRetrying)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(gallery.items.map(\.id))
                    }
                }
                .disabled(isRetrying)
            }
        } else {
            if !gallery.items.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select") { withAnimation { isSelecting = true } }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Bottom action bar

    private var selectionBar: some View {
        HStack {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label(selection.isEmpty ? "Delete" : "Delete (\(selection.count))",
                      systemImage: "trash")
            }
            .disabled(selection.isEmpty || isRetrying)

            Spacer()

            Button {
                Task { await retrySelected() }
            } label: {
                HStack(spacing: 6) {
                    if isRetrying { ProgressView() }
                    Label(failedSelectionCount == 0 ? "Retry" : "Retry (\(failedSelectionCount))",
                          systemImage: "arrow.up.circle")
                }
            }
            .disabled(failedSelectionCount == 0 || isRetrying || settings.defaultDatabaseID == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView("No photos yet",
                               systemImage: "photo.on.rectangle.angled",
                               description: Text("Photos you capture will appear here with their upload status."))
    }

    // MARK: - Derived state

    private var navigationTitle: String {
        guard isSelecting else { return "Gallery" }
        return selection.isEmpty ? "Select Photos" : "\(selection.count) Selected"
    }

    private var allSelected: Bool {
        !gallery.items.isEmpty && selection.count == gallery.items.count
    }

    /// Selected photos whose upload failed — the ones "Retry" will act on.
    private var failedSelectionCount: Int {
        gallery.items.reduce(0) { count, item in
            count + (selection.contains(item.id) && item.status == .failed ? 1 : 0)
        }
    }

    private var deleteConfirmationTitle: String {
        let count = selection.count
        return "Delete \(count) photo\(count == 1 ? "" : "s")?"
    }

    // MARK: - Actions

    private func handleTap(_ item: GalleryItem) {
        if isSelecting {
            toggle(item)
        } else {
            selectedItem = item
        }
    }

    private func beginSelecting(_ item: GalleryItem) {
        guard !isSelecting else { return }
        withAnimation { isSelecting = true }
        selection.insert(item.id)
    }

    private func toggle(_ item: GalleryItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    private func endSelecting() {
        withAnimation { isSelecting = false }
        selection.removeAll()
    }

    private func deleteSelected() {
        gallery.delete(selection)
        endSelecting()
    }

    private func retrySelected() async {
        guard let client = settings.makeClient(),
              let databaseID = settings.defaultDatabaseID else { return }
        isRetrying = true
        defer { isRetrying = false }
        _ = await gallery.retryFailed(ids: selection,
                                      client: client,
                                      databaseID: databaseID,
                                      saveToPhotos: settings.saveToPhotoLibraryByDefault)
    }
}

// MARK: - Grid cell

private struct GalleryCell: View {
    let item: GalleryItem
    let url: URL
    var isSelecting: Bool = false
    var isSelected: Bool = false

    private var isFailed: Bool { item.status == .failed }

    var body: some View {
        // `Color.clear` takes the full column width, and `.aspectRatio(1, .fit)`
        // forces that width into a square. The thumbnail fills the square and is
        // clipped, so every cell in the grid is identically sized.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GalleryThumbnail(url: url)
            }
            // A failed upload gets a red wash and border so it stands out in the
            // grid at a glance — not just from the small corner badge.
            .overlay {
                if isFailed { Color.red.opacity(0.22) }
            }
            // A selected photo is dimmed a touch so the blue check reads clearly.
            .overlay {
                if isSelected { Color.black.opacity(0.25) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Selection wins the border over the failed state, so a selected
            // failed photo still looks selected.
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).stroke(.blue, lineWidth: 3)
                } else if isFailed {
                    RoundedRectangle(cornerRadius: 6).stroke(.red, lineWidth: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                StatusBadge(status: item.status)
                    .padding(5)
            }
            .overlay(alignment: .topLeading) {
                if isSelecting {
                    selectionIndicator
                        .padding(5)
                }
            }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        Group {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .blue)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.25), in: Circle())
            }
        }
        .font(.title3)
        .shadow(color: .black.opacity(0.3), radius: 1)
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
        _ = try? await gallery.upload(itemID: item.id,
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
