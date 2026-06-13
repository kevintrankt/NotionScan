//
//  CameraView.swift
//  NotionScan
//
//  Home screen: live camera, shutter, flash/flip, batch thumbnail strip,
//  and a "Done" button that opens Review.
//

import SwiftUI
import AVFoundation

struct CameraView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var camera = CameraModel()
    @StateObject private var autoUploader = AutoUploadManager()
    @State private var showReview = false
    @State private var showSettings = false
    @State private var showUploadedFlash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.permissionDenied {
                permissionDeniedView
            } else {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
            }

            VStack {
                topBar
                autoModeBanner
                Spacer()
                bottomControls
            }
            .padding()
        }
        .task {
            await camera.start()
        }
        .onDisappear {
            camera.stop()
        }
        .onChange(of: camera.capturedPhotos.count) { _, newCount in
            handleAutoUpload(newCount: newCount)
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
        .fullScreenCover(isPresented: $showReview, onDismiss: {
            Task { await camera.start() }
        }) {
            ReviewView(camera: camera)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
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
            if !camera.capturedPhotos.isEmpty {
                thumbnailStrip
            }

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

                if settings.autoUploadEnabled {
                    // Keep the shutter centered; auto mode has no "Done" step.
                    Color.clear.frame(width: 56, height: 56)
                } else {
                    // Done (N)
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
                    .opacity(camera.capturedPhotos.isEmpty ? 0.4 : 1)
                    .disabled(camera.capturedPhotos.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var autoModeBanner: some View {
        if settings.autoUploadEnabled {
            HStack(spacing: 8) {
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
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.4), in: Capsule())
            .padding(.top, 8)
        }
    }

    private func handleAutoUpload(newCount: Int) {
        guard settings.autoUploadEnabled, newCount > 0,
              let client = settings.makeClient(),
              let databaseID = settings.defaultDatabaseID else { return }
        let photos = camera.capturedPhotos
        camera.clearBatch()
        for photo in photos {
            autoUploader.enqueue(photo,
                                 client: client,
                                 databaseID: databaseID,
                                 saveToPhotos: settings.saveToPhotoLibraryByDefault)
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
