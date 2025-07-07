import Foundation
import Network

/**
 * Ultra-optimized HTTP client configuration for maximum throughput
 * Swift equivalent of Android OkHttp configuration with iOS-specific optimizations
 */
struct HttpClientConfig {

    // MARK: - Shared URLSession Instance

    /// Ultra-optimized URLSession for maximum throughput
    static let client: URLSession = {
        let configuration = URLSessionConfiguration.default

        // Connection pool settings (equivalent to OkHttp ConnectionPool)
        configuration.httpMaximumConnectionsPerHost = 200
        configuration.shouldUseExtendedBackgroundIdleMode = true

        // Timeout settings
        configuration.timeoutIntervalForRequest = 5.0 // Connect timeout
        configuration.timeoutIntervalForResource = 300.0 // Overall timeout

        // Protocol settings (HTTP/2 preferred)
        configuration.httpShouldUsePipelining = true
        configuration.httpShouldSetCookies = false

        // Performance optimizations
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil // Disable caching for downloads

        // Network service type for downloads
        configuration.networkServiceType = .background

        // Additional performance settings
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true

        // Custom session with optimized delegate queue
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 500 // Equivalent to maxRequests
        operationQueue.qualityOfService = .userInitiated

        return URLSession(
            configuration: configuration,
            delegate: OptimizedURLSessionDelegate(),
            delegateQueue: operationQueue
        )
    }()

    // MARK: - Alternative High-Performance Session

    /// Alternative session for concurrent downloads
    static let concurrentClient: URLSession = {
        let configuration = URLSessionConfiguration.default

        // Maximum concurrent connections
        configuration.httpMaximumConnectionsPerHost = 50

        // Aggressive timeout settings for fast failures
        configuration.timeoutIntervalForRequest = 3.0
        configuration.timeoutIntervalForResource = 120.0

        // Disable unnecessary features for performance
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false

        // Optimize for downloads
        configuration.networkServiceType = .video
        configuration.allowsCellularAccess = true

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 100
        queue.qualityOfService = .utility

        return URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }()

    // MARK: - Request Building

    /**
     * Builds an optimized URLRequest with default headers and range support
     * - Parameters:
     *   - url: The URL to request
     *   - headers: Additional headers to include
     *   - startByte: Starting byte for range requests (0 = no range)
     *   - endByte: Ending byte for range requests (nil = open-ended)
     * - Returns: Configured URLRequest
     */
    static func buildRequest(
        url: String,
        headers: [String: String] = [:],
        startByte: Int64 = 0,
        endByte: Int64? = nil
    ) -> URLRequest? {

        guard let requestURL = URL(string: url) else {
            print("HttpClientConfig: Invalid URL - \(url)")
            return nil
        }

        var request = URLRequest(url: requestURL)

        // Default headers for optimal performance
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")

        // Add range header if needed
        if startByte > 0 || endByte != nil {
            let rangeValue: String
            if let endByte = endByte {
                rangeValue = "bytes=\(startByte)-\(endByte)"
            } else {
                rangeValue = "bytes=\(startByte)-"
            }
            request.setValue(rangeValue, forHTTPHeaderField: "Range")
        }

        // Add custom headers (will override defaults if same key)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Performance optimizations
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true

        return request
    }

    // MARK: - Specialized Request Builders

    /**
     * Builds a HEAD request for getting content info
     */
    static func buildHeadRequest(
        url: String,
        headers: [String: String] = [:]
    ) -> URLRequest? {

        var request = buildRequest(url: url, headers: headers)
        request?.httpMethod = "HEAD"
        request?.timeoutInterval = 3.0 // Faster timeout for HEAD requests

        return request
    }

    /**
     * Builds a chunked download request
     */
    static func buildChunkRequest(
        url: String,
        headers: [String: String] = [:],
        chunkStart: Int64,
        chunkEnd: Int64
    ) -> URLRequest? {

        return buildRequest(
            url: url,
            headers: headers,
            startByte: chunkStart,
            endByte: chunkEnd
        )
    }

    /**
     * Builds a streaming request optimized for large files
     */
    static func buildStreamingRequest(
        url: String,
        headers: [String: String] = [:]
    ) -> URLRequest? {

        var request = buildRequest(url: url, headers: headers)

        // Optimize for streaming
        request?.setValue("1.1", forHTTPHeaderField: "Accept-Version")
        request?.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request?.timeoutInterval = 30.0

        return request
    }

    // MARK: - Network Monitoring Integration

    private static let networkMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor", qos: .utility))
        return monitor
    }()

    /// Current network status
    static var isNetworkAvailable: Bool {
        return networkMonitor.currentPath.status == .satisfied
    }

    /// Whether using cellular connection
    static var isUsingCellular: Bool {
        return networkMonitor.currentPath.isExpensive
    }

    /// Whether using constrained network
    static var isNetworkConstrained: Bool {
        return networkMonitor.currentPath.isConstrained
    }

    // MARK: - Configuration Helpers

    /**
     * Creates a custom URLSession for specific use cases
     */
    static func createCustomSession(
        maxConnections: Int = 50,
        timeoutInterval: TimeInterval = 30,
        allowsCellular: Bool = true,
        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
    ) -> URLSession {

        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxConnections
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval * 10
        configuration.allowsCellularAccess = allowsCellular
        configuration.requestCachePolicy = cachePolicy
        configuration.urlCache = nil

        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = maxConnections * 2
        operationQueue.qualityOfService = .userInitiated

        return URLSession(configuration: configuration, delegate: nil, delegateQueue: operationQueue)
    }

    /**
     * Gets optimal configuration based on current network conditions
     */
    static func getOptimalConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default

        if isUsingCellular {
            // Conservative settings for cellular
            configuration.httpMaximumConnectionsPerHost = 10
            configuration.timeoutIntervalForRequest = 15.0
            configuration.allowsExpensiveNetworkAccess = true
        } else {
            // Aggressive settings for WiFi
            configuration.httpMaximumConnectionsPerHost = 50
            configuration.timeoutIntervalForRequest = 5.0
        }

        if isNetworkConstrained {
            // Reduce concurrent connections on constrained networks
            configuration.httpMaximumConnectionsPerHost = max(configuration.httpMaximumConnectionsPerHost / 2, 5)
        }

        // Common optimizations
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldUsePipelining = true
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true

        return configuration
    }
}

// MARK: - Custom URLSession Delegate

private class OptimizedURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            print("URLSession became invalid: \(error)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("Task completed with error: \(error)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Follow redirects with optimized headers
        var optimizedRequest = request
        optimizedRequest.setValue("keep-alive", forHTTPHeaderField: "Connection")
        optimizedRequest.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(optimizedRequest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Handle SSL challenges efficiently
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Extension for Additional Utilities

extension HttpClientConfig {

    /**
     * Validates URL format and accessibility
     */
    static func validateURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        guard url.host != nil else { return false }
        return true
    }

    /**
     * Estimates optimal chunk size based on network conditions
     */
    static func getOptimalChunkSize() -> Int {
        if isUsingCellular {
            return 256 * 1024 // 256KB for cellular
        } else if isNetworkConstrained {
            return 512 * 1024 // 512KB for constrained networks
        } else {
            return 1024 * 1024 // 1MB for WiFi
        }
    }

    /**
     * Gets recommended concurrent connection count
     */
    static func getRecommendedConcurrency() -> Int {
        if isUsingCellular {
            return 8
        } else if isNetworkConstrained {
            return 12
        } else {
            return 20
        }
    }

    /**
     * Creates headers for resume support
     */
    static func createResumeHeaders(from lastByte: Int64) -> [String: String] {
        return [
            "Range": "bytes=\(lastByte + 1)-",
            "If-Range": "*"
        ]
    }

    /**
     * Creates headers for chunked downloads
     */
    static func createChunkHeaders(start: Int64, end: Int64) -> [String: String] {
        return [
            "Range": "bytes=\(start)-\(end)",
            "Accept-Encoding": "identity" // Disable compression for chunks
        ]
    }
}

// MARK: - Performance Monitoring

extension HttpClientConfig {

    struct PerformanceMetrics {
        let connectionTime: TimeInterval
        let downloadSpeed: Double // bytes per second
        let errorRate: Double
        let retryCount: Int
    }

    /**
     * Monitors download performance
     */
    static func monitorPerformance(for task: URLSessionTask) -> PerformanceMetrics? {
        guard let metrics = task.currentRequest?.url?.absoluteString else { return nil }

        // This would typically be implemented with custom tracking
        // For now, return default metrics
        return PerformanceMetrics(
            connectionTime: 0.5,
            downloadSpeed: 1024 * 1024, // 1MB/s default
            errorRate: 0.05,
            retryCount: 0
        )
    }
}

// MARK: - Debug and Logging

extension HttpClientConfig {

    /**
     * Enables detailed logging for debugging
     */
    static func enableDebugLogging() {
        #if DEBUG
        // Enable URLSession logging in debug builds
        setenv("CFNETWORK_DIAGNOSTICS", "3", 1)
        #endif
    }

    /**
     * Logs request details for debugging
     */
    static func logRequest(_ request: URLRequest) {
        #if DEBUG
        print("=== HTTP Request ===")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Method: \(request.httpMethod ?? "GET")")
        print("Headers:")
        request.allHTTPHeaderFields?.forEach { key, value in
            print("  \(key): \(value)")
        }
        print("==================")
        #endif
    }

    /**
     * Logs response details for debugging
     */
    static func logResponse(_ response: HTTPURLResponse, data: Data?) {
        #if DEBUG
        print("=== HTTP Response ===")
        print("Status: \(response.statusCode)")
        print("Headers:")
        response.allHeaderFields.forEach { key, value in
            print("  \(key): \(value)")
        }
        if let data = data {
            print("Data size: \(data.count) bytes")
        }
        print("====================")
        #endif
    }
}