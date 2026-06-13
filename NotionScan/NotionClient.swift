//
//  NotionClient.swift
//  NotionScan
//
//  All Notion API access. No third-party dependencies — just URLSession.
//  Each instance is bound to one integration token.
//

import Foundation

struct NotionClient: Sendable {
    let token: String

    private let baseURL = URL(string: "https://api.notion.com")!
    private let notionVersion = "2022-06-28"

    // MARK: - Public API

    /// Validates the token via GET /v1/users/me. Returns the workspace/bot name.
    func validateToken() async throws -> String? {
        let request = makeJSONRequest(path: "/v1/users/me", method: "GET")
        let user: BotUser = try await send(request)
        return user.bot?.workspace_name ?? user.name
    }

    /// Lists databases the integration can access via POST /v1/search.
    func listDatabases() async throws -> [NotionDatabase] {
        var request = makeJSONRequest(path: "/v1/search", method: "POST")
        request.httpBody = try JSONEncoder().encode(SearchRequest())
        let response: SearchResponse = try await send(request)

        return response.results.map { db in
            let title = db.title?
                .compactMap(\.plain_text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let titleProp = db.properties?
                .first(where: { $0.value.type == "title" })?.key ?? "Name"
            return NotionDatabase(
                id: db.id,
                title: title.isEmpty ? "Untitled database" : title,
                titlePropertyName: titleProp
            )
        }
    }

    /// Two-step upload of one image. Returns the file_upload id to reference in a block.
    func uploadImage(_ jpegData: Data) async throws -> String {
        // Step 1: create the file upload object.
        var createReq = makeJSONRequest(path: "/v1/file_uploads", method: "POST")
        createReq.httpBody = try JSONSerialization.data(withJSONObject: [:] as [String: Any])
        let created: FileUploadResponse = try await send(createReq)

        guard let uploadURLString = created.upload_url,
              let uploadURL = URL(string: uploadURLString) else {
            throw NotionError.api(status: 0, message: "Notion did not return an upload URL.")
        }

        // Step 2: send the bytes as multipart/form-data with field name "file".
        let boundary = "Boundary-\(UUID().uuidString)"
        var sendReq = URLRequest(url: uploadURL)
        sendReq.httpMethod = "POST"
        sendReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        sendReq.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        sendReq.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        sendReq.httpBody = multipartBody(boundary: boundary,
                                         fieldName: "file",
                                         filename: "photo.jpg",
                                         mimeType: "image/jpeg",
                                         data: jpegData)

        let sent: FileUploadResponse = try await send(sendReq)
        return sent.id
    }

    /// Creates one page in `databaseId` containing all uploaded images as blocks.
    @discardableResult
    func createBatchPage(databaseId: String,
                         titlePropertyName: String,
                         title: String,
                         fileUploadIDs: [String]) async throws -> CreatePageResponse {
        let children = fileUploadIDs.map { id in
            CreatePageRequest.ImageBlock(
                image: .init(file_upload: .init(id: id))
            )
        }
        let body = CreatePageRequest(
            parent: .init(database_id: databaseId),
            properties: [
                titlePropertyName: .init(title: [.init(text: .init(content: title))])
            ],
            children: children
        )

        var request = makeJSONRequest(path: "/v1/pages", method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    // MARK: - Helpers

    private func makeJSONRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func multipartBody(boundary: String,
                               fieldName: String,
                               filename: String,
                               mimeType: String,
                               data: Data) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    /// Performs the request and decodes JSON, mapping failures to NotionError.
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NotionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NotionError.network("No HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw NotionError.invalidToken
            }
            let message = (try? JSONDecoder().decode(NotionAPIErrorBody.self, from: data))?.message
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw NotionError.api(status: http.statusCode, message: message)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NotionError.decoding(error.localizedDescription)
        }
    }
}
