import Foundation

class HttpClientConfig {

    // Ultra-optimized URLSession for maximum throughput
    static let client: URLSession = {
        let config = URLSessionConfiguration.default

        // Connection pool equivalent (300 connections, 10 minute timeout)
        config.httpMaximumConnectionsPerHost = 200
        config.timeoutIntervalForRequest = 15.0  // read/write timeout
        config.timeoutIntervalForResource = 600.0  // 10 minutes

        // Default headers (equivalent to interceptor)
        config.httpAdditionalHeaders = [
            "Accept-Encoding": "gzip",
            "Connection": "keep-alive"
        ]

        // Optimizations
        config.httpShouldUsePipelining = true
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        // Operation queue for 500 max requests
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 500

        return URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }()

    static func buildRequest(
        url: String,
        headers: [String: String] = [:],
        startByte: Int64 = 0
    ) -> URLRequest? {

        guard let requestURL = URL(string: url) else { return nil }

        var request = URLRequest(url: requestURL)

        // Default headers
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")

        // Range header if needed
        if startByte > 0 {
            request.setValue("bytes=\(startByte)-", forHTTPHeaderField: "Range")
        }

        // Custom headers
        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }
}