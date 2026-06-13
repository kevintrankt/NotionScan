//
//  AppSettings.swift
//  NotionScan
//
//  Single source of truth for connection state and user preferences.
//  Token lives in the Keychain; everything else in UserDefaults.
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {

    /// The Notion integration token, or nil when not connected.
    @Published private(set) var token: String?

    /// The default destination database id.
    @Published var defaultDatabaseID: String?

    /// Cached human-readable name of the default database (for display).
    @Published var defaultDatabaseName: String?

    /// Cached workspace/bot name, shown in Settings.
    @Published var connectedWorkspaceName: String?

    /// Global default for whether new batches also save to the Photos library.
    @Published var saveToPhotoLibraryByDefault: Bool {
        didSet { defaults.set(saveToPhotoLibraryByDefault, forKey: Keys.saveToLibrary) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let defaultDatabaseID = "defaultDatabaseID"
        static let defaultDatabaseName = "defaultDatabaseName"
        static let workspaceName = "connectedWorkspaceName"
        static let saveToLibrary = "saveToPhotoLibraryByDefault"
    }

    init() {
        self.token = KeychainStore.loadToken()
        self.defaultDatabaseID = defaults.string(forKey: Keys.defaultDatabaseID)
        self.defaultDatabaseName = defaults.string(forKey: Keys.defaultDatabaseName)
        self.connectedWorkspaceName = defaults.string(forKey: Keys.workspaceName)
        self.saveToPhotoLibraryByDefault = defaults.bool(forKey: Keys.saveToLibrary)
    }

    /// True once a token exists. Drives Onboarding-vs-Camera routing.
    var isConnected: Bool { token != nil }

    /// True once both a token and a default database are configured.
    var isFullyConfigured: Bool { token != nil && defaultDatabaseID != nil }

    /// Persists a validated token.
    func setToken(_ token: String, workspaceName: String?) {
        KeychainStore.saveToken(token)
        self.token = token
        self.connectedWorkspaceName = workspaceName
        defaults.set(workspaceName, forKey: Keys.workspaceName)
    }

    /// Sets the default destination database.
    func setDefaultDatabase(id: String, name: String) {
        defaultDatabaseID = id
        defaultDatabaseName = name
        defaults.set(id, forKey: Keys.defaultDatabaseID)
        defaults.set(name, forKey: Keys.defaultDatabaseName)
    }

    /// Clears everything and returns to a disconnected state.
    func disconnect() {
        KeychainStore.deleteToken()
        token = nil
        defaultDatabaseID = nil
        defaultDatabaseName = nil
        connectedWorkspaceName = nil
        defaults.removeObject(forKey: Keys.defaultDatabaseID)
        defaults.removeObject(forKey: Keys.defaultDatabaseName)
        defaults.removeObject(forKey: Keys.workspaceName)
    }

    /// Builds a NotionClient for the current token (nil if disconnected).
    func makeClient() -> NotionClient? {
        guard let token else { return nil }
        return NotionClient(token: token)
    }
}
