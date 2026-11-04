import Foundation

public enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": LeafJuice.userAgent]
        return URLSession(configuration: config)
    }()

    static func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    public static func url(_ text: String) throws -> URL {
        guard let u = URL(string: text), u.scheme == "https" || u.scheme == "http" else {
            throw LeafError("Not a valid web address: \(text)")
        }
        return u
    }

    @discardableResult
    static func check(_ response: URLResponse, _ url: URL) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw LeafError("No HTTP response from \(url.host ?? "server").") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 404: throw LeafError("Not found at \(url.host ?? "server") (404). Check the source details.")
            case 403, 429: throw LeafError("\(url.host ?? "The server") is limiting requests (\(http.statusCode)). Try again later.")
            default: throw LeafError("\(url.host ?? "The server") answered with status \(http.statusCode).")
            }
        }
        return http
    }

    public static func data(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        let (data, response) = try await session.data(for: request(url, method: method, body: body))
        try check(response, url)
        return data
    }

    public static func json(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> Any {
        try JSONSerialization.jsonObject(with: await data(url, method: method, body: body))
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ url: URL) async throws -> T {
        try await decodeBody(type, data(url))
    }

    static func decodeBody<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date \(text)"))
        }
        return try decoder.decode(type, from: data)
    }

    public static func head(_ url: URL) async throws -> HTTPURLResponse {
        let (_, response) = try await session.data(for: request(url, method: "HEAD"))
        return try check(response, url)
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let onProgress: @Sendable (Double) -> Void
        init(_ p: @escaping @Sendable (Double) -> Void) { onProgress = p }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    /// Downloads to `destination`, refusing a file whose hash doesn't match.
    /// Returns the digests and the name the server gave the file, if any.
    @discardableResult
    public static func download(
        _ url: URL, to destination: URL, expect: ExpectedHashes = .init(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (digests: Hashing.Digests, suggestedName: String?) {
        let delegate = ProgressDelegate(progress ?? { _ in })
        let (temp, response) = try await session.download(for: request(url), delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temp) }
        let http = try check(response, url)
        let digests = try Hashing.digests(of: temp)
        guard expect.verify(digests) else {
            throw LeafError("The download from \(url.host ?? "the server") failed its checksum, so it was discarded.")
        }
        try FileOps.move(temp, to: destination)
        return (digests, http.suggestedFilename)
    }
}
