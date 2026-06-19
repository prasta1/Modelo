import Foundation

/// Intercepts URLSession requests in tests. Set `handler` to return a canned
/// (response, body). Captures the request (incl. streamed POST body).
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    static func reset() { handler = nil; lastRequest = nil; lastBody = nil }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

extension HTTPURLResponse {
    static func stub(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://stub")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }
}
