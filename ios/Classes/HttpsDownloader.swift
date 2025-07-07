import Foundation

/**
 * High-performance HTTPS downloader with resume support and progress tracking
 * Swift equivalent of Android HttpsDownloader with iOS-specific optimizations
 */
class HttpsDownloader {

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let bufferSize = 32768 // 32KB buffer for optimal performance
    private let progressUpdateInterval: TimeInterval = 1.0 // 1 second

    // MARK: - Main Download Function

    /**
     * Downloads a single file with resume support and progress tracking
     * - Parameters:
     *   - task: The download task containing URL, file path, and configuration
     *   - onProgress: Progress callback with download statistics
     */
    func downloadSingleFile(
        task: DownloadTask,
        onProgress: @escaping ([String: Any]) -> Void
    ) async throws {

        // Ensure parent directory exists
        let fileURL = URL(fileURLWithPath: task.filePath)
        let parentDirectory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        // Check for existing file and set resume position
        if fileManager.fileExists(atPath: task.filePath) {
            let attributes = try fileManager.attributesOfItem(atPath: task.filePath)
            task.downloadedBytes = (attributes[.size] as? Int64) ?? 0
        } else {
            task.downloadedBytes = 0
        }

        // Initialize download state
        task.status = .downloading
        task.startTime = Int64(Date().timeIntervalSince1970 * 1000)
        task.lastSpeedUpdate = task.startTime

        // Get total file size
        let totalBytes = await getFileSize(task: task)
        task.totalBytes = totalBytes
        sendProgress(task: task, onProgress: onProgress)

        // Retry loop with exponential backoff
        for attempt in 0...task.retryCount {
            if task.status != .downloading { return }

            do {
                try await performDownload(task: task, onProgress: onProgress)

                // Download completed successfully
                if task.status == .downloading {
                    task.status = .completed
                    sendProgress(task: task, onProgress: onProgress)
                }
                return

            } catch {
                if attempt == task.retryCount {
                    // Final attempt failed
                    task.status = .failed
                    task.error = error.localizedDescription
                    sendProgress(task: task, onProgress: onProgress)
                    throw error
                }

                // Exponential backoff with jitter
                let backoffMs = (500 * (1 << attempt)) + Int.random(in: 0...500)
                try await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
            }
        }
    }

    // MARK: - Core Download Logic

    /**
     * Performs the actual download with streaming and progress tracking
     */
    private func performDownload(
        task: DownloadTask,
        onProgress: @escaping ([String: Any]) -> Void
    ) async throws {

        // Build request with resume support
        guard let request = HttpClientConfig.buildRequest(
            url: task.url,
            headers: task.headers,
            startByte: task.downloadedBytes
        ) else {
            throw DownloadError.invalidURL(task.url)
        }

        // Perform the network request
        let (data, response) = try await HttpClientConfig.client.data(for: request)

        // Validate response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            throw DownloadError.networkError("HTTP \(httpResponse.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))")
        }

        // Update total bytes if not set
        if task.totalBytes <= 0 {
            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let length = Int64(contentLength) {
                task.totalBytes = length + task.downloadedBytes
            }
        }

        // Write data to file
        try await writeDataToFile(
            data: data,
            task: task,
            onProgress: onProgress
        )
    }

    /**
     * Writes data to file with progress tracking and speed calculation
     */
    private func writeDataToFile(
        data: Data,
        task: DownloadTask,
        onProgress: @escaping ([String: Any]) -> Void
    ) async throws {

        let fileURL = URL(fileURLWithPath: task.filePath)

        // Determine write mode (append for resume, create for new)
        let fileHandle: FileHandle

        if task.downloadedBytes > 0 {
            // Resume mode - append to existing file
            if !fileManager.fileExists(atPath: task.filePath) {
                fileManager.createFile(atPath: task.filePath, contents: nil)
            }
            fileHandle = try FileHandle(forWritingTo: fileURL)
            try fileHandle.seekToEnd()
        } else {
            // New download - create fresh file
            fileManager.createFile(atPath: task.filePath, contents: nil)
            fileHandle = try FileHandle(forWritingTo: fileURL)
        }

        defer {
            try? fileHandle.close()
        }

        // Stream write with progress tracking
        try await streamWrite(
            data: data,
            fileHandle: fileHandle,
            task: task,
            onProgress: onProgress
        )
    }

    /**
     * Streams data writing with chunked progress updates
     */
    private func streamWrite(
        data: Data,
        fileHandle: FileHandle,
        task: DownloadTask,
        onProgress: @escaping ([String: Any]) -> Void
    ) async throws {

        var lastUpdate = Date().timeIntervalSince1970 * 1000
        var bytesInInterval: Int64 = 0
        let totalDataSize = data.count
        var bytesWritten = 0

        // Process data in chunks for better memory management and progress updates
        while bytesWritten < totalDataSize && task.status == .downloading {
            let chunkSize = min(bufferSize, totalDataSize - bytesWritten)
            let range = bytesWritten..<(bytesWritten + chunkSize)
            let chunk = data.subdata(in: range)

            // Write chunk to file
            try fileHandle.write(contentsOf: chunk)

            // Update counters
            task.downloadedBytes += Int64(chunkSize)
            bytesInInterval += Int64(chunkSize)
            bytesWritten += chunkSize

            // Update progress periodically
            let now = Date().timeIntervalSince1970 * 1000
            if now - lastUpdate > progressUpdateInterval * 1000 {
                updateSpeedHistory(task: task, bytes: bytesInInterval, timeMs: Int64(now - lastUpdate))
                sendProgress(task: task, onProgress: onProgress)
                lastUpdate = now
                bytesInInterval = 0
            }

            // Small delay to prevent blocking the thread completely
            if bytesWritten % (bufferSize * 10) == 0 {
                await Task.yield()
            }
        }

        // Force sync to disk
        try fileHandle.synchronize()
    }

    // MARK: - File Size Detection

    /**
     * Gets the total file size from the server using a HEAD request
     * - Parameter task: The download task
     * - Returns: File size in bytes, or -1 if unable to determine
     */
    private func getFileSize(task: DownloadTask) async -> Int64 {
        do {
            guard let request = HttpClientConfig.buildHeadRequest(
                url: task.url,
                headers: task.headers
            ) else {
                return -1
            }

            let (_, response) = try await HttpClientConfig.client.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return -1
            }

            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let length = Int64(contentLength) {
                return length
            }

            return -1

        } catch {
            print("HttpsDownloader: Failed to get file size for \(task.url): \(error)")
            return -1
        }
    }

    // MARK: - Speed Tracking

    /**
     * Updates the download speed history for accurate speed calculation
     * - Parameters:
     *   - task: The download task
     *   - bytes: Number of bytes downloaded in the interval
     *   - timeMs: Time interval in milliseconds
     */
    private func updateSpeedHistory(task: DownloadTask, bytes: Int64, timeMs: Int64) {
        let speed = timeMs > 0 ? (Double(bytes) * 1000.0 / Double(timeMs)) : 0.0
        task.speedHistory.append(speed)

        // Keep only last 10 speed measurements
        if task.speedHistory.count > 10 {
            task.speedHistory.removeFirst()
        }
    }

    /**
     * Calculates average download speed from history
     * - Parameter task: The download task
     * - Returns: Average speed in bytes per second
     */
    private func calculateAverageSpeed(task: DownloadTask) -> Double {
        if !task.speedHistory.isEmpty {
            return task.speedHistory.reduce(0, +) / Double(task.speedHistory.count)
        } else {
            let currentTime = Int64(Date().timeIntervalSince1970 * 1000)
            let timeElapsed = max(1, currentTime - task.startTime)
            return Double(task.downloadedBytes) * 1000.0 / Double(timeElapsed)
        }
    }

    // MARK: - Progress Reporting

    /**
     * Sends progress update with comprehensive download statistics
     * - Parameters:
     *   - task: The download task
     *   - onProgress: Progress callback function
     */
    private func sendProgress(task: DownloadTask, onProgress: @escaping ([String: Any]) -> Void) {
        let avgSpeed = calculateAverageSpeed(task: task)

        let progress = task.totalBytes > 0 ?
            Int((Double(task.downloadedBytes) * 100.0) / Double(task.totalBytes)) : -1

        let remainingBytes = task.totalBytes - task.downloadedBytes
        let estimatedTimeRemaining = (avgSpeed > 0 && remainingBytes > 0) ?
            Int64(Double(remainingBytes) / avgSpeed) : -1

        let progressData: [String: Any] = [
            "url": task.url,
            "filePath": task.filePath,
            "progress": progress,
            "bytesDownloaded": task.downloadedBytes,
            "totalBytes": task.totalBytes,
            "status": task.status.rawValue,
            "statusString": task.status.stringValue,
            "error": task.error ?? "",
            "speed": avgSpeed,
            "estimatedTimeRemaining": estimatedTimeRemaining,
            "elapsedTime": (Date().timeIntervalSince1970 * 1000) - Double(task.startTime)
        ]

        // Dispatch to main queue for UI updates
        DispatchQueue.main.async {
            onProgress(progressData)
        }
    }
}

// MARK: - Download Error Types

extension HttpsDownloader {

    enum DownloadError: Error, LocalizedError {
        case invalidURL(String)
        case networkError(String)
        case fileSystemError(String)
        case insufficientSpace(Int64, Int64) // required, available
        case cancelled
        case timeout

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "Invalid URL: \(url)"
            case .networkError(let message):
                return "Network error: \(message)"
            case .fileSystemError(let message):
                return "File system error: \(message)"
            case .insufficientSpace(let required, let available):
                return "Insufficient storage space. Required: \(DownloadUtils.formatBytes(required)), Available: \(DownloadUtils.formatBytes(available))"
            case .cancelled:
                return "Download was cancelled"
            case .timeout:
                return "Download timeout"
            }
        }
    }
}

// MARK: - Validation and Utilities

extension HttpsDownloader {

    /**
     * Validates available disk space before starting download
     * - Parameters:
     *   - task: The download task
     *   - bufferSize: Additional buffer space required (default 10% of file size)
     * - Throws: DownloadError.insufficientSpace if not enough space
     */
    func validateDiskSpace(for task: DownloadTask, bufferSize: Double = 0.1) throws {
        guard task.totalBytes > 0 else { return } // Skip validation if size unknown

        guard let availableSpace = DownloadUtils.getAvailableDiskSpace() else {
            print("HttpsDownloader: Unable to determine available disk space")
            return
        }

        let requiredSpace = Int64(Double(task.totalBytes) * (1.0 + bufferSize))

        if availableSpace < requiredSpace {
            throw DownloadError.insufficientSpace(requiredSpace, availableSpace)
        }
    }

    /**
     * Checks if the download can be resumed by verifying file integrity
     * - Parameter task: The download task
     * - Returns: True if resume is possible, false otherwise
     */
    func canResumeDownload(for task: DownloadTask) -> Bool {
        guard fileManager.fileExists(atPath: task.filePath) else { return false }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: task.filePath)
            let fileSize = (attributes[.size] as? Int64) ?? 0

            // File exists and has content, and is smaller than total size
            return fileSize > 0 && (task.totalBytes <= 0 || fileSize < task.totalBytes)
        } catch {
            return false
        }
    }

    /**
     * Cleans up partial download files
     * - Parameter task: The download task
     */
    func cleanup(for task: DownloadTask) {
        if task.status == .failed || task.status == .cancelled {
            try? fileManager.removeItem(atPath: task.filePath)
        }
    }

    /**
     * Verifies download integrity by checking file size
     * - Parameter task: The download task
     * - Returns: True if download appears complete and valid
     */
    func verifyDownload(for task: DownloadTask) -> Bool {
        guard fileManager.fileExists(atPath: task.filePath) else { return false }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: task.filePath)
            let actualSize = (attributes[.size] as? Int64) ?? 0

            // If we know the expected size, verify it matches
            if task.totalBytes > 0 {
                return actualSize == task.totalBytes
            } else {
                // If size unknown, just check file exists and has content
                return actualSize > 0
            }
        } catch {
            return false
        }
    }
}

// MARK: - Advanced Features

extension HttpsDownloader {

    /**
     * Downloads with automatic retry and exponential backoff
     * Enhanced version with more sophisticated retry logic
     */
    func downloadWithAdvancedRetry(
        task: DownloadTask,
        onProgress: @escaping ([String: Any]) -> Void,
        maxRetries: Int = 5,
        baseDelayMs: Int = 1000
    ) async throws {

        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                try await downloadSingleFile(task: task, onProgress: onProgress)
                return // Success

            } catch let error as URLError {
                lastError = error

                // Don't retry on certain errors
                switch error.code {
                case .fileDoesNotExist, .badURL, .unsupportedURL:
                    throw error
                default:
                    break
                }

                if attempt < maxRetries {
                    // Exponential backoff with jitter
                    let delay = baseDelayMs * (1 << attempt) + Int.random(in: 0...1000)
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                }

            } catch {
                lastError = error
                if attempt < maxRetries {
                    let delay = baseDelayMs * (1 << attempt) + Int.random(in: 0...1000)
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                }
            }
        }

        // All retries failed
        if let error = lastError {
            throw error
        }
    }

    /**
     * Downloads multiple files concurrently with shared progress tracking
     */
    func downloadMultipleFiles(
        tasks: [DownloadTask],
        maxConcurrency: Int = 5,
        onProgress: @escaping ([String: Any]) -> Void
    ) async throws {

        try await withTaskGroup(of: Void.self) { group in
            let semaphore = AsyncSemaphore(value: maxConcurrency)

            for task in tasks {
                group.addTask {
                    await semaphore.wait()
                    defer { semaphore.signal() }

                    do {
                        try await self.downloadSingleFile(task: task, onProgress: onProgress)
                    } catch {
                        print("Failed to download \(task.url): \(error)")
                    }
                }
            }
        }
    }
}