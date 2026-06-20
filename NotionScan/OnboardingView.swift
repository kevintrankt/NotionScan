//
//  OnboardingView.swift
//  NotionScan
//
//  First-launch flow: paste + validate a Notion integration token, then pick
//  the default destination database.
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var step: Step = .token
    @State private var tokenInput = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var databases: [NotionDatabase] = []
    @State private var selectedDatabaseID: String?

    private enum Step { case token, database }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .token: tokenStep
                case .database: databaseStep
                }
            }
            .navigationTitle("Connect Notion")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Step 1: token

    private var tokenStep: some View {
        Form {
            Section {
                SecureField("ntn_… or secret_…", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Integration token")
            } footer: {
                Text("Paste your Notion internal integration secret. It's stored only on this device.")
            }

            Section("How to get a token") {
                instructionRow(1, "Open [notion.com/my-integrations](https://www.notion.com/my-integrations) and tap “New integration”.")
                instructionRow(2, "Choose “Internal”, create it, then copy the Internal Integration Secret.")
                instructionRow(3, "In Notion, open each database you want to use → ••• → Connections → add your integration.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        if isWorking { ProgressView() }
                        Text("Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
    }

    // MARK: - Step 2: database

    private var databaseStep: some View {
        Form {
            Section {
                if databases.isEmpty {
                    Text("No databases were shared with this integration yet. In Notion, open a database → ••• → Connections → add your integration, then tap Refresh.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Default database", selection: $selectedDatabaseID) {
                        ForEach(databases) { db in
                            Text(db.title).tag(db.id as String?)
                        }
                    }
                    .pickerStyle(.inline)
                }
            } header: {
                Text("Default destination")
            } footer: {
                Text("Photos will go here by default. You can change it per batch later.")
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                Button {
                    Task { await loadDatabases() }
                } label: {
                    HStack {
                        if isWorking { ProgressView() }
                        Text("Refresh databases")
                    }
                }
                .disabled(isWorking)

                Button {
                    finish()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .disabled(selectedDatabaseID == nil || isWorking)
            }
        }
        .task {
            if databases.isEmpty { await loadDatabases() }
        }
    }

    // `text` is a `LocalizedStringKey` so Markdown links in the instructions render
    // as tappable links (e.g. the my-integrations URL opens in the browser).
    private func instructionRow(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.tint, in: Circle())
            Text(text).font(.callout).tint(.accentColor)
        }
    }

    // MARK: - Actions

    private func connect() async {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let client = NotionClient(token: token)
        do {
            let workspaceName = try await client.validateToken()
            settings.setToken(token, workspaceName: workspaceName)
            step = .database
        } catch {
            errorMessage = (error as? NotionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadDatabases() async {
        guard let client = settings.makeClient() else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            databases = try await client.listDatabases()
            if selectedDatabaseID == nil { selectedDatabaseID = databases.first?.id }
        } catch {
            errorMessage = (error as? NotionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finish() {
        guard let id = selectedDatabaseID,
              let db = databases.first(where: { $0.id == id }) else { return }
        settings.setDefaultDatabase(id: db.id, name: db.title)
    }
}
