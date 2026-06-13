//
//  SettingsView.swift
//  NotionScan
//
//  Connection status, change default database, replace token, toggle the
//  "save to Photos" default, and disconnect.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var databases: [NotionDatabase] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showReplaceToken = false
    @State private var newToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Notion") {
                    LabeledContent("Workspace", value: settings.connectedWorkspaceName ?? "Connected")
                    LabeledContent("Default database", value: settings.defaultDatabaseName ?? "Not set")
                }

                Section("Default database") {
                    if isLoading {
                        HStack { ProgressView(); Text("Loading…") }
                    } else if !databases.isEmpty {
                        Picker("Database", selection: Binding(
                            get: { settings.defaultDatabaseID },
                            set: { newValue in
                                if let id = newValue,
                                   let db = databases.first(where: { $0.id == id }) {
                                    settings.setDefaultDatabase(id: db.id, name: db.title)
                                }
                            }
                        )) {
                            ForEach(databases) { db in
                                Text(db.title).tag(db.id as String?)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    Button("Refresh databases") { Task { await loadDatabases() } }
                        .disabled(isLoading)
                }

                Section {
                    Toggle("Auto mode", isOn: $settings.autoUploadEnabled)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("When on, every photo you take is uploaded to your default database immediately — no review or confirmation. Each photo becomes its own page.")
                }

                Section {
                    Toggle("Save photos to library by default",
                           isOn: $settings.saveToPhotoLibraryByDefault)
                } footer: {
                    Text("When on, new batches are also saved to your Photos library after upload.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

                Section {
                    Button("Replace token") {
                        newToken = ""
                        showReplaceToken = true
                    }
                    Button("Disconnect", role: .destructive) {
                        settings.disconnect()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadDatabases() }
            .alert("Replace token", isPresented: $showReplaceToken) {
                SecureField("ntn_… or secret_…", text: $newToken)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await replaceToken() } }
            } message: {
                Text("Paste a new integration token to reconnect.")
            }
        }
    }

    private func loadDatabases() async {
        guard let client = settings.makeClient() else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            databases = try await client.listDatabases()
        } catch {
            errorMessage = (error as? NotionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func replaceToken() async {
        let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let client = NotionClient(token: token)
        do {
            let workspace = try await client.validateToken()
            settings.setToken(token, workspaceName: workspace)
            await loadDatabases()
        } catch {
            errorMessage = (error as? NotionError)?.errorDescription ?? error.localizedDescription
        }
    }
}
