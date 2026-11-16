import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A request-local session prevents ambient cookies, credentials, caches, and redirects from joining this flow.
struct OpenAIWebTransport: ProviderHTTPTransport {
    static let maximumBodyBytes = 1_048_576

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return configuration
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(
            configuration: Self.makeConfiguration(), delegate: OpenAIWebRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        #if os(macOS)
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(Self.maximumBodyBytes) else {
            throw OpenAIWebError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBodyBytes else { throw OpenAIWebError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
        #else
        // Native browser sessions are macOS-only; keep the protocol usable by synthetic cross-platform tests.
        throw OpenAIWebError.profileAccess
        #endif
    }
}

final class OpenAIWebRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        // Deny same-origin redirects too: neither bearer credential may move to a different route.
        completionHandler(nil)
    }
}
