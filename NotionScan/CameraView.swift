//
//  CameraView.swift
//  NotionScan
//
//  Home screen: live camera, shutter, flash/flip, batch thumbnail strip,
//  a "Done" button that opens Review, and a last-photo preview that opens
//  the Gallery.
//

import SwiftUI
import AVFoundation

struct CameraView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var gallery: GalleryStore
    @StateObject private var camera = CameraModel()
    @StateObject private var autoUploader = AutoUploadManager()
    @State private var showReview = false
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var showUploadedFlash = false
    @State private var showDiscardConfirmation = false

    /// Databases the integration can write to, used to populate the destination
    /// picker. Loaded lazily when the camera appears (see `loadDatabases`).
    @State private var databases: [NotionDatabase] = []
    @State private var isLoadingDatabases = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.permissionDenied {
                permissionDeniedView
            } else {
                CameraPreviewView(
                    session: camera.session,
                    onTapToFocus: { devicePoint in camera.focus(at: devicePoint) },
                    onPinchBegan: { camera.beginZoomGesture() },
                    onPinchChanged: { scale in camera.updateZoomGesture(scale: scale) },
                    onDoubleTap: { camera.resetZoom() }
                )
                .ignoresSafeArea()
            }

            VStack {
                topBar
                databaseSelector
                autoModeToggle
                Spacer()
                bottomControls
            }
            .padding()
        }
        .task {
            configureCaptureHandler()
            await camera.start()
        }
        .task {
            await loadDatabases()
        }
        .onDisappear {
            camera.stop()
        }
        .onChange(of: autoUploader.lastSucceededAt) { _, newValue in
            guard newValue != nil else { return }
            showUploadedFlash = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                showUploadedFlash = false
            }
        }
        .alert("Upload failed", isPresented: Binding(
            get: { autoUploader.lastError != nil },
            set: { if !$0 { autoUploader.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { autoUploader.lastError = nil }
        } message: {
            Text(autoUploader.lastError ?? "")
        }
        .confirmationDialog(
            "Discard \(camera.capturedPhotos.count) photo\(camera.capturedPhotos.count == 1 ? "" : "s")?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { discardBatch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These photos haven't been uploaded and will be removed.")
        }
        .fullScreenCover(isPresented: $showReview, onDismiss: {
            Task { await camera.start() }
        }) {
            ReviewView(camera: camera)
                .environmentObject(settings)
                .environmentObject(gallery)
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            Task { await camera.start() }
        }) {
            SettingsView()
                .environmentObject(settings)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView()
                .environmentObject(settings)
                .environmentObject(gallery)
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Button {
                camera.cycleFlash()
            } label: {
                Image(systemName: flashIconName)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }

            Spacer()

            Button {
                camera.stop()
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            // The current batch (manual mode only) travels with the controls that
            // act on it: "Discard" throws the whole batch away, "Done" sends it to
            // review. Both only make sense while photos are waiting to be reviewed.
            if !camera.capturedPhotos.isEmpty {
                HStack(spacing: 12) {
                    discardButton
                    thumbnailStrip
                    doneButton
                }
            }

            zoomControls

            HStack {
                // Flip camera
                Button {
                    camera.flipCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.black.opacity(0.35), in: Circle())
                }

                Spacer()

                // Shutter
                Button {
                    camera.capturePhoto()
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
                .disabled(!camera.isAuthorized)

                Spacer()

                // Last-photo preview → opens the gallery. Mirrors the system
                // Camera app, where the most recent shot is the gallery entry point.
                lastPhotoPreview
            }
        }
    }

    /// The lens picker (0.5× / 1× / 2× …) on multi-lens devices, or a small live zoom
    /// pill on single-lens cameras so pinch-to-zoom still has feedback.
    @ViewBuilder
    private var zoomControls: some View {
        if camera.showsLensSelector {
            lensSelector
        } else if camera.displayZoomFactor > 1.05 {
            Text("\(camera.displayZoomLabel)×")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
        }
    }

    /// A row of lens buttons reflecting the iPhone's actual cameras. The active lens
    /// shows the live zoom (e.g. "1.7×") in yellow; the others show their preset (e.g.
    /// "0.5", "2"). Tapping a lens smoothly switches to it.
    private var lensSelector: some View {
        HStack(spacing: 6) {
            ForEach(camera.lensOptions) { lens in
                let isActive = camera.activeLens == lens
                Button {
                    camera.selectLens(lens)
                } label: {
                    Text(isActive ? "\(camera.displayZoomLabel)×" : lens.displayName)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isActive ? .yellow : .white)
                        .frame(minWidth: isActive ? 40 : 30, minHeight: 30)
                        .background(.black.opacity(0.35), in: Capsule())
                }
                .accessibilityLabel("\(lens.displayName)× lens")
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: Capsule())
    }

    private var doneButton: some View {
        Button {
            camera.stop()
            showReview = true
        } label: {
            Text("Done (\(camera.capturedPhotos.count))")
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 56)
                .background(.white, in: Capsule())
        }
    }

    /// Throws away the whole pending batch. Confirmed first, since it's destructive.
    private var discardButton: some View {
        Button {
            showDiscardConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.black.opacity(0.35), in: Circle())
        }
        .accessibilityLabel("Discard batch")
    }

    @ViewBuilder
    private var lastPhotoPreview: some View {
        if let item = gallery.items.first {
            Button {
                showGallery = true
            } label: {
                GalleryThumbnail(url: gallery.imageURL(for: item))
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.white, lineWidth: 2)
                    )
            }
            .accessibilityLabel("Open gallery")
        } else {
            // No photos yet — keep the shutter centered.
            Color.clear.frame(width: 56, height: 56)
        }
    }

    /// Floating destination indicator above the Auto-mode pill. It always shows which
    /// database the next photo will be saved to, and doubles as a picker: tapping it
    /// opens a menu of the integration's databases so the destination can be switched
    /// on the fly, without opening Settings. Both manual batches and Auto mode upload
    /// to `settings.defaultDatabaseID`, so changing it here changes where photos land.
    private var databaseSelector: some View {
        Menu {
            if databases.isEmpty {
                Text(isLoadingDatabases ? "Loading…" : "No databases available")
            } else {
                ForEach(databases) { db in
                    Button {
                        settings.setDefaultDatabase(id: db.id, name: db.title)
                    } label: {
                        if db.id == settings.defaultDatabaseID {
                            Label(db.title, systemImage: "checkmark")
                        } else {
                            Text(db.title)
                        }
                    }
                }
            }

            Divider()

            Button {
                Task { await loadDatabases() }
            } label: {
                Label("Refresh databases", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Saving to")
                    .foregroundStyle(.white.opacity(0.7))
                Text(settings.defaultDatabaseName ?? "Choose database")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
            .padding(.top, 4)
        }
        .accessibilityLabel("Destination database")
        .accessibilityValue(settings.defaultDatabaseName ?? "Not set")
        .accessibilityHint("Choose which database photos are saved to")
    }

    /// Tappable pill that toggles auto mode on and off. When on, it also surfaces
    /// the current upload state (an in-flight count or a brief success flash); when
    /// off it reads "Auto mode off" so there's always a control to turn it back on.
    private var autoModeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.autoUploadEnabled.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                if settings.autoUploadEnabled {
                    if autoUploader.inFlight > 0 {
                        ProgressView().tint(.white)
                        Text("Uploading \(autoUploader.inFlight)…")
                    } else if showUploadedFlash {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Uploaded to Notion")
                    } else {
                        Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                        Text("Auto mode")
                    }
                } else {
                    Image(systemName: "bolt.slash.fill").foregroundStyle(.white.opacity(0.7))
                    Text("Auto mode off")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.4), in: Capsule())
            .overlay(
                Capsule().stroke(
                    settings.autoUploadEnabled ? Color.yellow.opacity(0.8) : Color.white.opacity(0.25),
                    lineWidth: 1
                )
            )
            .padding(.top, 8)
        }
        .buttonStyle(.plain)
        // A short vibration confirms the toggle landed, since the pill is small
        // and easy to tap without looking while shooting.
        .sensoryFeedback(.impact, trigger: settings.autoUploadEnabled)
        .accessibilityLabel("Auto mode")
        .accessibilityValue(settings.autoUploadEnabled ? "On" : "Off")
        .accessibilityHint("Toggles uploading each photo to Notion immediately")
    }

    /// Discards the entire pending batch. Each captured photo was also persisted
    /// to the gallery as `pending` (see `configureCaptureHandler`), so we delete
    /// those entries too — otherwise discarding would leave orphaned, never-uploaded
    /// photos in the gallery. This mirrors the per-photo delete in Review.
    private func discardBatch() {
        for photo in camera.capturedPhotos {
            gallery.delete(photo.id)
        }
        camera.clearBatch()
    }

    /// Fetches the databases the integration can write to, for the destination
    /// picker. Failures leave the existing list untouched; the floating label still
    /// shows the current default (from `settings`), so a network hiccup never hides
    /// where photos are going — it just means the dropdown has nothing new to offer.
    private func loadDatabases() async {
        guard let client = settings.makeClient() else { return }
        isLoadingDatabases = true
        defer { isLoadingDatabases = false }
        if let fetched = try? await client.listDatabases() {
            databases = fetched
        }
    }

    /// Every captured photo is persisted to the gallery. In auto mode it's also
    /// uploaded immediately; otherwise it joins the in-memory batch for review.
    private func configureCaptureHandler() {
        let gallery = self.gallery
        let settings = self.settings
        let autoUploader = self.autoUploader
        camera.onCapture = { [weak camera] photo in
            let item = gallery.add(photo)
            if settings.autoUploadEnabled,
               let client = settings.makeClient(),
               let databaseID = settings.defaultDatabaseID {
                autoUploader.enqueue(itemID: item.id,
                                     gallery: gallery,
                                     client: client,
                                     databaseID: databaseID,
                                     saveToPhotos: settings.saveToPhotoLibraryByDefault)
            } else {
                camera?.capturedPhotos.append(photo)
            }
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(camera.capturedPhotos) { photo in
                    Image(uiImage: photo.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 1))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)
            Text("Camera access is off")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Enable camera access in Settings to take photos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var flashIconName: String {
        switch camera.flashMode {
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.a.fill"
        default: return "bolt.slash.fill"
        }
    }
}
