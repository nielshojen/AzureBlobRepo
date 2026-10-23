//
//  AzureBlobRepoPlugin.swift
//  munki
//
//  Azure Blob Storage repository support for the Munki admin tools
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//       https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import CryptoKit
import Foundation

/// Azure Blob Storage implementation of the Repo protocol, talking to the
/// Blob service REST API directly (there is no maintained Azure Storage SDK
/// for Swift on macOS).
///
/// Supported repo URLs:
///   - https://<account>.blob.core.windows.net/<container>[/path/to/repo]
///     (any host containing ".blob.", e.g. sovereign clouds)
///   - http(s)://<host>[:port]/<account>/<container>[/path/to/repo]
///     (path-style, e.g. Azurite at http://127.0.0.1:10000/devstoreaccount1/munki-repo)
///
/// Credentials come from the environment, first match wins:
///   - AZURE_STORAGE_SAS_TOKEN: a SAS token for the container or account
///   - AZURE_STORAGE_KEY: the storage account key (Shared Key auth)
///   - otherwise a Microsoft Entra ID token from `az account get-access-token`
///     (needs `az login` and a Storage Blob Data role on the container)
public class AzureBlobRepo: Repo {
    static let apiVersion = "2021-08-06"
    /// Files larger than this are uploaded as blocks of this size
    static let blockSize = 64 * 1024 * 1024
    /// No HTTP cache: cached responses make URLSession add conditional
    /// headers after signing (breaking Shared Key auth) and serve stale data
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    enum Credential {
        case sas(String)
        case sharedKey(Data)
        case bearer(String)
    }

    let account: String
    let prefix: String
    /// Percent-encoded path of the container, e.g. "/munki-repo" or
    /// "/devstoreaccount1/munki-repo" for path-style endpoints
    let containerPath: String
    private let endpoint: URLComponents
    private let credential: Credential

    public required convenience init(_ url: String) throws {
        try self.init(url, credential: Self.credentialFromEnvironment())
    }

    init(_ url: String, credential: Credential) throws {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else {
            throw AzureBlobRepoError("Repo URL must be http(s)://<host>/...: \(url)")
        }
        let segments = components.path.split(separator: "/").map(String.init)
        // Path-style URLs carry the account as the first path segment
        let pathStyle = !host.lowercased().contains(".blob.")
        let containerIndex = pathStyle ? 1 : 0
        guard segments.count > containerIndex else {
            throw AzureBlobRepoError(
                "Repo URL must include \(pathStyle ? "an account and " : "")a container name: \(url)")
        }
        account = pathStyle ? segments[0] : String(host.split(separator: ".")[0])
        containerPath = "/" + segments[...containerIndex].map(Self.encode).joined(separator: "/")
        prefix = segments[(containerIndex + 1)...].joined(separator: "/")

        var endpoint = URLComponents()
        endpoint.scheme = scheme
        endpoint.host = host
        endpoint.port = components.port
        self.endpoint = endpoint
        self.credential = credential
    }

    // MARK: Repo API

    /// Returns identifiers relative to `kind`, recursively, like FileRepo
    public func list(_ kind: String) async throws -> [String] {
        let listPrefix = fullName(kind) + "/"
        var names: [String] = []
        var marker = ""
        repeat {
            var query = ["restype": "container", "comp": "list", "prefix": listPrefix]
            if !marker.isEmpty {
                query["marker"] = marker
            }
            let request = try makeRequest("GET", blob: nil, query: query)
            let (data, response) = try await Self.session.data(for: request)
            try Self.check(response, data)
            let page = try BlobListParser.parse(data)
            names += page.names.map { String($0.dropFirst(listPrefix.count)) }.filter { !$0.isEmpty }
            marker = page.nextMarker
        } while !marker.isEmpty
        return names
    }

    public func get(_ identifier: String) async throws -> Data {
        let request = try makeRequest("GET", blob: fullName(identifier))
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, data, identifier)
        return data
    }

    public func get(_ identifier: String, toFile localFilePath: String) async throws {
        let request = try makeRequest("GET", blob: fullName(identifier))
        let (tempURL, response) = try await Self.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Self.check(response, (try? Data(contentsOf: tempURL)) ?? Data(), identifier)
        let destination = URL(fileURLWithPath: localFilePath)
        if FileManager.default.fileExists(atPath: localFilePath) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    public func put(_ identifier: String, content: Data) async throws {
        let request = try makeRequest(
            "PUT", blob: fullName(identifier),
            headers: ["Content-Type": "application/octet-stream", "x-ms-blob-type": "BlockBlob"],
            contentLength: content.count
        )
        let (data, response) = try await Self.session.upload(for: request, from: content)
        try Self.check(response, data, identifier)
    }

    public func put(_ identifier: String, fromFile localFilePath: String) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: localFilePath)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if size <= Self.blockSize {
            let request = try makeRequest(
                "PUT", blob: fullName(identifier),
                headers: ["Content-Type": "application/octet-stream", "x-ms-blob-type": "BlockBlob"],
                contentLength: size
            )
            let fileURL = URL(fileURLWithPath: localFilePath)
            let (data, response) = try await Self.session.upload(for: request, fromFile: fileURL)
            try Self.check(response, data, identifier)
        } else {
            try await putBlocks(identifier, fromFile: localFilePath)
        }
    }

    public func delete(_ identifier: String) async throws {
        let request = try makeRequest("DELETE", blob: fullName(identifier))
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, data, identifier)
    }

    /// No local filesystem path exists; Munki tools then fall back to get()
    public func pathFor(_: String) -> String? {
        return nil
    }

    // MARK: Helpers

    /// Uploads a large file as a series of blocks, then commits them.
    /// A single Put Blob is capped at 5000 MiB, which large installers
    /// (e.g. Xcode) exceed; blocks also keep memory use to one block.
    private func putBlocks(_ identifier: String, fromFile localFilePath: String) async throws {
        let blob = fullName(identifier)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: localFilePath))
        defer { try? handle.close() }
        var blockIDs: [String] = []
        while let chunk = try handle.read(upToCount: Self.blockSize), !chunk.isEmpty {
            let blockID = Data(String(format: "%06d", blockIDs.count).utf8).base64EncodedString()
            let request = try makeRequest(
                "PUT", blob: blob, query: ["comp": "block", "blockid": blockID],
                headers: ["Content-Type": "application/octet-stream"],
                contentLength: chunk.count
            )
            let (data, response) = try await Self.session.upload(for: request, from: chunk)
            try Self.check(response, data, identifier)
            blockIDs.append(blockID)
        }
        let blockList = Data((
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>"
                + blockIDs.map { "<Latest>\($0)</Latest>" }.joined()
                + "</BlockList>"
        ).utf8)
        let request = try makeRequest(
            "PUT", blob: blob, query: ["comp": "blocklist"],
            headers: ["Content-Type": "application/xml"],
            contentLength: blockList.count
        )
        let (data, response) = try await Self.session.upload(for: request, from: blockList)
        try Self.check(response, data, identifier)
    }

    private func fullName(_ identifier: String) -> String {
        return prefix.isEmpty ? identifier : "\(prefix)/\(identifier)"
    }

    /// Builds an authorized request for the container (blob == nil) or a blob in it
    func makeRequest(
        _ method: String,
        blob: String?,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        contentLength: Int = 0,
        date: Date = Date()
    ) throws -> URLRequest {
        var components = endpoint
        components.percentEncodedPath = containerPath + (blob.map { "/" + Self.encode($0) } ?? "")
        var queryParts = query.sorted { $0.key < $1.key }.map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }
        if case let .sas(token) = credential {
            queryParts.append(token)
        }
        components.percentEncodedQuery = queryParts.isEmpty ? nil : queryParts.joined(separator: "&")
        guard let url = components.url else {
            throw AzureBlobRepoError("Could not build request URL for \(blob ?? containerPath)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        var allHeaders = headers
        allHeaders["x-ms-version"] = Self.apiVersion
        allHeaders["x-ms-date"] = Self.httpDate(date)
        switch credential {
        case .sas:
            break
        case let .bearer(token):
            allHeaders["Authorization"] = "Bearer \(token)"
        case let .sharedKey(key):
            let signature = HMAC<SHA256>.authenticationCode(
                for: Data(stringToSign(method, path: components.percentEncodedPath, query: query,
                                       headers: allHeaders, contentLength: contentLength).utf8),
                using: SymmetricKey(data: key)
            )
            allHeaders["Authorization"] = "SharedKey \(account):\(Data(signature).base64EncodedString())"
        }
        for (name, value) in allHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Shared Key string-to-sign, see
    /// https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key
    func stringToSign(
        _ method: String, path: String, query: [String: String], headers: [String: String], contentLength: Int
    ) -> String {
        let header = { (name: String) in headers.first { $0.key.lowercased() == name }?.value ?? "" }
        let canonicalHeaders = headers
            .filter { $0.key.lowercased().hasPrefix("x-ms-") }
            .map { "\($0.key.lowercased()):\($0.value)\n" }
            .sorted()
            .joined()
        let canonicalResource = "/\(account)\(path)" + query
            .map { (key: $0.key.lowercased(), value: $0.value) }
            .sorted { $0.key < $1.key }
            .map { "\n\($0.key):\($0.value)" }
            .joined()
        return [
            method,
            header("content-encoding"),
            header("content-language"),
            contentLength > 0 ? String(contentLength) : "",
            header("content-md5"),
            header("content-type"),
            "", // Date (x-ms-date is used instead)
            header("if-modified-since"),
            header("if-match"),
            header("if-none-match"),
            header("if-unmodified-since"),
            header("range"),
        ].joined(separator: "\n") + "\n" + canonicalHeaders + canonicalResource
    }

    static func credentialFromEnvironment() throws -> Credential {
        let environment = ProcessInfo.processInfo.environment
        if let sas = environment["AZURE_STORAGE_SAS_TOKEN"], !sas.isEmpty {
            return .sas(sas.hasPrefix("?") ? String(sas.dropFirst()) : sas)
        }
        if let key = environment["AZURE_STORAGE_KEY"], !key.isEmpty {
            guard let keyData = Data(base64Encoded: key) else {
                throw AzureBlobRepoError("AZURE_STORAGE_KEY is not valid base64")
            }
            return .sharedKey(keyData)
        }
        return try .bearer(azCLIAccessToken())
    }

    /// Gets an Entra ID token for Azure Storage from the Azure CLI's login
    static func azCLIAccessToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "az", "account", "get-access-token",
            "--resource", "https://storage.azure.com/",
            "--query", "accessToken", "--output", "tsv",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let failure = "Set AZURE_STORAGE_SAS_TOKEN or AZURE_STORAGE_KEY, or run `az login`"
        do {
            try process.run()
        } catch {
            throw AzureBlobRepoError("Could not run the Azure CLI (\(error.localizedDescription)). \(failure)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let token = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !token.isEmpty else {
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AzureBlobRepoError("Could not get an access token from the Azure CLI: \(message). \(failure)")
        }
        return token
    }

    /// Throws for any non-2xx response, using the service's error code if present
    static func check(_ response: URLResponse, _ body: Data, _ identifier: String? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AzureBlobRepoError("Unexpected response for \(identifier ?? "container")")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let text = String(decoding: body, as: UTF8.self)
            let code = text.range(of: "<Code>").flatMap { start in
                text.range(of: "</Code>", range: start.upperBound ..< text.endIndex).map {
                    String(text[start.upperBound ..< $0.lowerBound])
                }
            } ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AzureBlobRepoError("HTTP \(http.statusCode) \(code) for \(identifier ?? "container")")
        }
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters and "/"
    static func encode(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

/// Parses a List Blobs response for blob names and the continuation marker
final class BlobListParser: NSObject, XMLParserDelegate {
    private(set) var names: [String] = []
    private(set) var nextMarker = ""
    private var path: [String] = []
    private var text = ""

    static func parse(_ data: Data) throws -> BlobListParser {
        let delegate = BlobListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw AzureBlobRepoError("Could not parse List Blobs response: \(parser.parserError?.localizedDescription ?? "")")
        }
        return delegate
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?,
                qualifiedName _: String?, attributes _: [String: String] = [:])
    {
        path.append(elementName)
        text = ""
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if path.suffix(2) == ["Blob", "Name"] {
            names.append(text)
        } else if path.suffix(2) == ["EnumerationResults", "NextMarker"] {
            nextMarker = text
        }
        path.removeLast()
        text = ""
    }
}

struct AzureBlobRepoError: LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        return message
    }

    /// Munki tools print some errors with String(describing:)
    var description: String {
        return message
    }
}

/// Azure Blob Storage Repository Plugin Builder
public class AzureBlobRepoPluginBuilder: RepoPluginBuilder {
    override public func connect(_ url: String) -> Repo? {
        do {
            return try AzureBlobRepo(url)
        } catch {
            print("Failed to connect to Azure Blob Storage repository: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: dylib "interface"

/// Function with C calling style for our dylib. We use it to instantiate the Repo object and return an instance
@_cdecl("createPlugin")
public func createPlugin() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(AzureBlobRepoPluginBuilder()).toOpaque()
}
