//
//  Models.swift
//  NotionScan
//
//  Core value types: captured photos, Notion databases, and the Codable
//  request/response shapes used by NotionClient.
//

import Foundation
import UIKit

// MARK: - App-side models

/// A single photo captured during a batch. Lives in memory only.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
    let jpegData: Data
}

/// A Notion database the integration has access to.
struct NotionDatabase: Identifiable, Hashable {
    let id: String
    let title: String
    /// The name of the database's "title" property (varies per database, e.g. "Name").
    let titlePropertyName: String
}

/// Outcome of uploading one batch.
struct BatchUploadResult {
    let pageURL: String?
    let uploadedCount: Int
}

/// Errors surfaced to the UI in plain language.
enum NotionError: LocalizedError {
    case invalidToken
    case network(String)
    case decoding(String)
    case api(status: Int, message: String)
    case noTitleProperty

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "That token didn't work. Double-check you copied the full integration secret."
        case .network(let message):
            return "Network problem: \(message)"
        case .decoding(let message):
            return "Couldn't read Notion's response: \(message)"
        case .api(let status, let message):
            return "Notion API error (\(status)): \(message)"
        case .noTitleProperty:
            return "This database has no title column, so a page can't be created in it."
        }
    }
}

// MARK: - Notion API: search (databases)

struct SearchRequest: Encodable {
    struct Filter: Encodable {
        let value = "database"
        let property = "object"
    }
    let filter = Filter()
    let page_size = 100
}

struct SearchResponse: Decodable {
    let results: [DatabaseObject]
}

struct DatabaseObject: Decodable {
    let id: String
    let title: [RichText]?
    let properties: [String: PropertySchema]?

    struct PropertySchema: Decodable {
        let type: String
    }
}

struct RichText: Decodable {
    let plain_text: String?
}

// MARK: - Notion API: users/me

struct BotUser: Decodable {
    let id: String
    let name: String?
    let bot: Bot?

    struct Bot: Decodable {
        let workspace_name: String?
    }
}

// MARK: - Notion API: file uploads

struct FileUploadResponse: Decodable {
    let id: String
    let upload_url: String?
    let status: String?
}

// MARK: - Notion API: create page

struct CreatePageRequest: Encodable {
    let parent: Parent
    let properties: [String: TitleProperty]
    let children: [ImageBlock]

    struct Parent: Encodable {
        let database_id: String
    }

    struct TitleProperty: Encodable {
        let title: [TitleText]
    }

    struct TitleText: Encodable {
        let text: TextContent
        struct TextContent: Encodable {
            let content: String
        }
    }

    struct ImageBlock: Encodable {
        let object = "block"
        let type = "image"
        let image: ImagePayload

        struct ImagePayload: Encodable {
            let type = "file_upload"
            let file_upload: FileUploadRef
            struct FileUploadRef: Encodable {
                let id: String
            }
        }
    }
}

struct CreatePageResponse: Decodable {
    let id: String
    let url: String?
}

// MARK: - Generic API error body

struct NotionAPIErrorBody: Decodable {
    let status: Int?
    let code: String?
    let message: String?
}
