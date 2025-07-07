import Foundation
import Network

/**
 * High-performance HLS downloader with adaptive optimizations
 * Combines Swift async/await with TaskGroup management for maximum efficiency
 */
class HighPerformanceHlsDownloader {

    // MARK: - Performance Tracking and Configuration

    private struct PerformanceMetrics {
        var avgDownloadSpeed: Double = 0.0
        var connectionSuccessRate: Double = 1.0
        var lastSpeedUpdate: Int64 = 0
        var speedHistory: [Double] = []

        mutating func updateSpeed(_ speed: Double) {
            speedHistory.append(speed)
            if speedHistory.count > 20 {
                speedHistory.removeFirst()
            }
            avgDownloadSpeed = speedHistory.reduce(0, +) / Double(speedHistory.count)
            lastSpeedUpdate = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    private struct AdaptiveConfig {
        var concurrentDownloaders: Int
        var maxConnections: Int
        var useChunking: Bool
        var chunkSize: Int
        var bufferSize: Int

        mutating func adapt(metrics: PerformanceMetrics, segmentSize: Int64) {
            switch segmentSize {
            case ...100_000: // Small segments (≤100KB)
                concurrentDownloaders = 20
                maxConnections = 30
                useChunking = false
                bufferSize = 8192

            case ...1_000_000: // Medium segments (≤1MB)
                concurrentDownloaders = 15
                maxConnections = 25
                useChunking = false
                bufferSize = 16384

            default: // Large segments (>1MB)
                concurrentDownloaders = 10
                maxConnections = 15
                useChunking = true
                chunkSize = 512_000
                bufferSize = 32768
            }

            // Adapt based on performance
            if metrics.avgDownloadSpeed > 0 {
                let networkCapacity = metrics.avgDownloadSpeed * 1.2
                if metrics.avgDownloadSpeed < networkCapacity * 0.7 && concurrentDownloaders < 25 {
                    concurrentDownloaders = min(concurrentDownloaders + 2, 25)
                } else if metrics.avgDownloadSpeed > networkCapacity * 0.95 && concurrentDownloaders > 5 {
                    concurrentDownloaders = max(concurrentDownloaders - 1, 5)
                }
            }
        }
    }

    // Priority-based segment task
    private struct PrioritySegmentTask: Comparable {
        let segment: SegmentTask
        let priority: Int
        let segmentIndex: Int
        var retryCount: Int = 0
        var failed: Bool = false

        static func < (lhs: PrioritySegmentTask, rhs: PrioritySegmentTask) -> Bool {
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority // Higher priority first
            }
            return lhs.segmentIndex < rhs.segmentIndex
        }
    }

    // Progress update structure
    private struct ProgressUpdate {
        let bytesDownloaded: Int64
        let downloadTime: Int64
        let success: Bool
    }

    // MARK: - Properties

    private var urlSession: URLSession
    private var performanceMetrics = PerformanceMetrics()
    private var config = AdaptiveConfig(
        concurrentDownloaders: 12,
        maxConnections: 20,
        useChunking: false,
        chunkSize: 256_000,
        bufferSize: 16384
    )

    private let metricsLock = NSLock()
    private let configLock = NSLock()

    // MARK: - Initialization

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 20
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Main Download Function

    func downloadHlsStreamAdvanced(
        task: DownloadTask,
        basePath: String,
        onProgress: @escaping ([String: Any]) -> Void
    ) async throws {

        task.status = .downloading
        task.startTime = Int64(Date().timeIntervalSince1970 * 1000)

        let playlistDir = URL(fileURLWithPath: basePath).appendingPathComponent(
            task.fileName.replacingOccurrences(of: ".m3u8", with: "")
        )

        try FileManager.default.createDirectory(at: playlistDir, withIntermediateDirectories: true)

        guard let baseUri = URL(string: task.url) else {
            throw NSError(domain: "InvalidURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HLS URL"])
        }

        let totalDownloadedBytes = AtomicInt64(0)
        let downloadedSegments = AtomicInt(0)
        let totalSegments = AtomicInt(0)
        let isCompleted = AtomicBool(false)

        do {
            // Phase 1: Analyze stream
            let (variants, avgSegmentSize) = try await analyzeHlsStream(
                masterUrl: task.url,
                headers: task.headers,
                baseUri: baseUri
            )

            // Phase 2: Configure
            configLock.lock()
            config.adapt(metrics: performanceMetrics, segmentSize: avgSegmentSize)
            let currentConfig = config
            configLock.unlock()

            // Phase 3: Create segment queue
            let segmentQueue = PriorityQueue<PrioritySegmentTask>()

            // Phase 4: Process playlists FIRST
            print("Processing playlists...")

            try await withTaskGroup(of: Void.self) { group in
                for (variantIndex, variant) in variants.prefix(1).enumerated() {
                    group.addTask {
                        await self.processVariantPlaylist(
                            variant: variant,
                            baseUri: baseUri,
                            headers: task.headers,
                            segmentQueue: segmentQueue,
                            totalSegments: totalSegments,
                            variantIndex: variantIndex,
                            playlistDir: playlistDir
                        )
                    }
                }
            }

            print("Found \(totalSegments.value) segments to download")

            guard totalSegments.value > 0 else {
                throw NSError(domain: "NoSegments", code: -1, userInfo: [NSLocalizedDescriptionKey: "No segments found in playlist"])
            }

            // Phase 5: Launch download workers
            let semaphore = AsyncSemaphore(value: currentConfig.maxConnections)

            print("Starting \(currentConfig.concurrentDownloaders) download workers...")

            try await withTaskGroup(of: Void.self) { group in
                // Add download workers
                for workerId in 0..<currentConfig.concurrentDownloaders {
                    group.addTask {
                        await self.downloadWorker(
                            workerId: workerId,
                            segmentQueue: segmentQueue,
                            playlistDir: playlistDir,
                            headers: task.headers,
                            config: currentConfig,
                            totalDownloadedBytes: totalDownloadedBytes,
                            downloadedSegments: downloadedSegments,
                            semaphore: semaphore,
                            isCompleted: isCompleted
                        )
                    }
                }

                // Add progress monitoring
                group.addTask {
                    await self.handleProgressUpdates(
                        task: task,
                        totalDownloadedBytes: totalDownloadedBytes,
                        downloadedSegments: downloadedSegments,
                        totalSegments: totalSegments,
                        onProgress: onProgress,
                        isCompleted: isCompleted
                    )
                }

                // Add performance monitoring
                group.addTask {
                    await self.monitorPerformance(
                        totalDownloadedBytes: totalDownloadedBytes,
                        startTime: task.startTime,
                        isCompleted: isCompleted
                    )
                }

                // Wait for completion
                while downloadedSegments.value < totalSegments.value {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    print("Progress: \(downloadedSegments.value)/\(totalSegments.value) segments downloaded")
                }

                isCompleted.setValue(true)
                group.cancelAll()
            }

            // Phase 6: Create final playlists
            try createMasterPlaylist(variants: Array(variants.prefix(1)), playlistDir: playlistDir)

            task.status = .completed
            task.downloadedBytes = totalDownloadedBytes.value
            task.filePath = playlistDir.appendingPathComponent("master.m3u8").path
            sendProgress(for: task, onProgress: onProgress)

        } catch {
            isCompleted.setValue(true)
            task.status = .failed
            task.error = error.localizedDescription
            sendProgress(for: task, onProgress: onProgress)
            throw error
        }
    }

    // MARK: - Download Worker

    private func downloadWorker(
        workerId: Int,
        segmentQueue: PriorityQueue<PrioritySegmentTask>,
        playlistDir: URL,
        headers: [String: String],
        config: AdaptiveConfig,
        totalDownloadedBytes: AtomicInt64,
        downloadedSegments: AtomicInt,
        semaphore: AsyncSemaphore,
        isCompleted: AtomicBool
    ) async {

        while !isCompleted.value {
            guard let priorityTask = segmentQueue.dequeue() else {
                // No work available, wait a bit
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                continue
            }

            await semaphore.wait()
            defer { semaphore.signal() }

            do {
                let startTime = Date()
                let bytesDownloaded = try await downloadSegmentAdvanced(
                    segment: priorityTask.segment,
                    playlistDir: playlistDir,
                    headers: headers,
                    config: config
                )
                let downloadTime = Date().timeIntervalSince(startTime)

                totalDownloadedBytes.add(bytesDownloaded)
                downloadedSegments.increment()

                // Update performance metrics
                metricsLock.lock()
                let speed = Double(bytesDownloaded) / downloadTime
                performanceMetrics.updateSpeed(speed)
                metricsLock.unlock()

            } catch {
                if priorityTask.retryCount < 3 {
                    var retryTask = priorityTask
                    retryTask.retryCount += 1

                    // Exponential backoff
                    let delayMs = UInt64(pow(2.0, Double(retryTask.retryCount)) * 200)
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)

                    segmentQueue.enqueue(retryTask)
                } else {
                    print("Worker \(workerId): Failed to download \(priorityTask.segment.fileName) after retries: \(error)")
                }
            }
        }

        print("Worker \(workerId): Exiting")
    }

    // MARK: - Stream Analysis

    private func analyzeHlsStream(
        masterUrl: String,
        headers: [String: String],
        baseUri: URL
    ) async throws -> ([VariantPlaylist], Int64) {

        let masterContent = try await fetchPlaylistContent(url: masterUrl, headers: headers)
        let variants = parseMasterPlaylist(content: masterContent, baseUri: baseUri)
        let avgSegmentSize: Int64 = 500_000 // Default estimate

        return (variants, avgSegmentSize)
    }

    // MARK: - Playlist Processing

    private func processVariantPlaylist(
        variant: VariantPlaylist,
        baseUri: URL,
        headers: [String: String],
        segmentQueue: PriorityQueue<PrioritySegmentTask>,
        totalSegments: AtomicInt,
        variantIndex: Int,
        playlistDir: URL
    ) async {

        do {
            print("Processing variant: \(variant.url)")
            let variantContent = try await fetchPlaylistContent(url: variant.url, headers: headers)
            print("Variant content length: \(variantContent.count)")

            guard let variantUri = URL(string: variant.url) else {
                print("Invalid variant URL: \(variant.url)")
                return
            }

            let segments = parseVariantPlaylist(
                content: variantContent,
                baseUri: variantUri,
                variantName: variant.fileName
            )

            print("Found \(segments.count) segments in variant")
            totalSegments.add(segments.count)

            // Create prioritized tasks
            for (index, segment) in segments.enumerated() {
                let priority = calculateSegmentPriority(
                    index: index,
                    totalSegments: segments.count,
                    variantIndex: variantIndex
                )
                let priorityTask = PrioritySegmentTask(
                    segment: segment,
                    priority: priority,
                    segmentIndex: index
                )
                segmentQueue.enqueue(priorityTask)
            }

            // Create local playlist
            try createLocalPlaylist(
                variant: variant,
                segments: segments,
                playlistDir: playlistDir
            )

        } catch {
            print("Error processing variant \(variant.url): \(error)")
        }
    }

    // MARK: - Segment Download

    private func downloadSegmentAdvanced(
        segment: SegmentTask,
        playlistDir: URL,
        headers: [String: String],
        config: AdaptiveConfig
    ) async throws -> Int64 {

        let segmentFile = playlistDir.appendingPathComponent(segment.fileName)

        // Check if file already exists and has content
        if FileManager.default.fileExists(atPath: segmentFile.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: segmentFile.path)
            if let size = attributes?[.size] as? Int64, size > 0 {
                return size
            }
        }

        if config.useChunking {
            return try await downloadSegmentChunked(
                segment: segment,
                segmentFile: segmentFile,
                headers: headers,
                config: config
            )
        } else {
            return try await downloadSegmentStreaming(
                segment: segment,
                segmentFile: segmentFile,
                headers: headers,
                config: config
            )
        }
    }

    // MARK: - Streaming Download

    private func downloadSegmentStreaming(
        segment: SegmentTask,
        segmentFile: URL,
        headers: [String: String],
        config: AdaptiveConfig
    ) async throws -> Int64 {

        guard let url = URL(string: segment.url) else {
            throw NSError(domain: "InvalidURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid segment URL"])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "DownloadError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download failed: \(segment.url)"])
        }

        try data.write(to: segmentFile)
        return Int64(data.count)
    }

    // MARK: - Chunked Download

    private func downloadSegmentChunked(
        segment: SegmentTask,
        segmentFile: URL,
        headers: [String: String],
        config: AdaptiveConfig
    ) async throws -> Int64 {

        // Get content length first
        guard let contentLength = try await getContentLength(url: segment.url, headers: headers) else {
            return try await downloadSegmentStreaming(
                segment: segment,
                segmentFile: segmentFile,
                headers: headers,
                config: config
            )
        }

        if contentLength <= config.chunkSize {
            return try await downloadSegmentStreaming(
                segment: segment,
                segmentFile: segmentFile,
                headers: headers,
                config: config
            )
        }

        let chunks = (contentLength + Int64(config.chunkSize) - 1) / Int64(config.chunkSize)

        // Pre-allocate file
        FileManager.default.createFile(atPath: segmentFile.path, contents: Data(count: Int(contentLength)))
        let fileHandle = try FileHandle(forWritingTo: segmentFile)
        defer { try? fileHandle.close() }

        return try await withTaskGroup(of: (Int64, Data).self, returning: Int64.self) { group in
            for chunkIndex in 0..<chunks {
                group.addTask {
                    let start = chunkIndex * Int64(config.chunkSize)
                    let end = min(start + Int64(config.chunkSize) - 1, contentLength - 1)

                    guard let url = URL(string: segment.url) else {
                        throw NSError(domain: "InvalidURL", code: -1)
                    }

                    var request = URLRequest(url: url)
                    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let (data, response) = try await self.urlSession.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 206 else {
                        throw NSError(domain: "ChunkError", code: -1)
                    }

                    return (start, data)
                }
            }

            var totalBytes: Int64 = 0
            for try await (offset, chunkData) in group {
                try fileHandle.seek(toOffset: UInt64(offset))
                try fileHandle.write(contentsOf: chunkData)
                totalBytes += Int64(chunkData.count)
            }

            return totalBytes
        }
    }

    // MARK: - Progress Handling

    private func handleProgressUpdates(
        task: DownloadTask,
        totalDownloadedBytes: AtomicInt64,
        downloadedSegments: AtomicInt,
        totalSegments: AtomicInt,
        onProgress: @escaping ([String: Any]) -> Void,
        isCompleted: AtomicBool
    ) async {

        var lastUpdate: Int64 = 0
        let updateInterval: Int64 = 300 // 300ms

        while !isCompleted.value {
            let now = Int64(Date().timeIntervalSince1970 * 1000)

            if now - lastUpdate >= updateInterval || downloadedSegments.value >= totalSegments.value {
                task.downloadedBytes = totalDownloadedBytes.value

                // Estimate total size if not known
                if task.totalBytes <= 0 && downloadedSegments.value > 0 {
                    let avgBytesPerSegment = totalDownloadedBytes.value / Int64(downloadedSegments.value)
                    task.totalBytes = avgBytesPerSegment * Int64(totalSegments.value)
                }

                sendProgress(for: task, onProgress: onProgress)
                lastUpdate = now
            }

            // Break if all segments downloaded
            if downloadedSegments.value >= totalSegments.value && totalSegments.value > 0 {
                break
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    // MARK: - Performance Monitoring

    private func monitorPerformance(
        totalDownloadedBytes: AtomicInt64,
        startTime: Int64,
        isCompleted: AtomicBool
    ) async {

        while !isCompleted.value {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            let currentTime = Int64(Date().timeIntervalSince1970 * 1000)
            let timeElapsed = currentTime - startTime
            let currentSpeed = Double(totalDownloadedBytes.value) * 1000.0 / Double(timeElapsed)

            metricsLock.lock()
            performanceMetrics.updateSpeed(currentSpeed)
            metricsLock.unlock()
        }
    }

    // MARK: - Helper Methods

    private func calculateSegmentPriority(index: Int, totalSegments: Int, variantIndex: Int) -> Int {
        let basePriority: Int

        switch index {
        case 0..<5:
            basePriority = 100 - index // Highest priority for first segments
        case 0..<Int(Double(totalSegments) * 0.1):
            basePriority = 80 - index // High priority for early segments
        case 0..<Int(Double(totalSegments) * 0.3):
            basePriority = 60 // Medium priority
        default:
            basePriority = 40 // Normal priority
        }

        return basePriority - (variantIndex * 10) // Prefer higher quality variants
    }

    private func getContentLength(url: String, headers: [String: String]) async throws -> Int64? {
        guard let requestUrl = URL(string: url) else { return nil }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "HEAD"

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return Int64(httpResponse.expectedContentLength)
            }
        } catch {
            return nil
        }

        return nil
    }

    private func fetchPlaylistContent(url: String, headers: [String: String]) async throws -> String {
        guard let requestUrl = URL(string: url) else {
            throw NSError(domain: "InvalidURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid playlist URL"])
        }

        var request = URLRequest(url: requestUrl)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "PlaylistError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch playlist: \(url)"])
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "EncodingError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid playlist encoding"])
        }

        return content
    }

    private func parseMasterPlaylist(content: String, baseUri: URL) -> [VariantPlaylist] {
        var variants: [VariantPlaylist] = []
        let lines = content.components(separatedBy: .newlines)
        var currentBandwidth: Int64 = 0
        var currentResolution = ""

        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // Parse bandwidth
                if let bandwidthMatch = line.range(of: "BANDWIDTH=(\\d+)", options: .regularExpression) {
                    let bandwidthString = String(line[bandwidthMatch]).replacingOccurrences(of: "BANDWIDTH=", with: "")
                    currentBandwidth = Int64(bandwidthString) ?? 0
                }

                // Parse resolution
                if let resolutionMatch = line.range(of: "RESOLUTION=(\\d+x\\d+)", options: .regularExpression) {
                    currentResolution = String(line[resolutionMatch]).replacingOccurrences(of: "RESOLUTION=", with: "")
                }

            } else if !line.isEmpty && !line.hasPrefix("#") {
                let variantUrl = baseUri.appendingPathComponent(line).absoluteString
                let variantFileName = String(line.split(separator: "/").last ?? "")
                variants.append(VariantPlaylist(
                    url: variantUrl,
                    fileName: variantFileName,
                    bandwidth: currentBandwidth,
                    resolution: currentResolution
                ))
            }
        }

        return variants.sorted { $0.bandwidth > $1.bandwidth }
    }

    private func parseVariantPlaylist(content: String, baseUri: URL, variantName: String) -> [SegmentTask] {
        var segments: [SegmentTask] = []
        let lines = content.components(separatedBy: .newlines)
        var segmentDuration: Double = 10.0

        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTINF:") {
                if let durationMatch = line.range(of: "#EXTINF:([\\d.]+)", options: .regularExpression) {
                    let durationString = String(line[durationMatch]).replacingOccurrences(of: "#EXTINF:", with: "").replacingOccurrences(of: ",", with: "")
                    segmentDuration = Double(durationString) ?? 10.0
                }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                let segmentUrl = baseUri.appendingPathComponent(line).absoluteString
                let segmentFileName = "\(variantName)_\(String(line.split(separator: "/").last ?? ""))"
                segments.append(SegmentTask(
                    url: segmentUrl,
                    fileName: segmentFileName,
                    size: 0,
                    downloaded: false,
                    bytes: 0,
                    duration: segmentDuration
                ))
            }
        }

        return segments
    }

    private func createLocalPlaylist(variant: VariantPlaylist, segments: [SegmentTask], playlistDir: URL) throws {
        let maxDuration = segments.map { Int($0.duration) }.max() ?? 10

        var playlistContent = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(maxDuration)
        #EXT-X-MEDIA-SEQUENCE:0

        """

        for segment in segments {
            playlistContent += "#EXTINF:\(segment.duration),\n"
            playlistContent += "\(segment.fileName)\n"
        }

        playlistContent += "#EXT-X-ENDLIST\n"

        let playlistFile = playlistDir.appendingPathComponent(variant.fileName)
        try playlistContent.write(to: playlistFile, atomically: true, encoding: .utf8)
    }

    private func createMasterPlaylist(variants: [VariantPlaylist], playlistDir: URL) throws {
        var masterContent = """
        #EXTM3U
        #EXT-X-VERSION:3

        """

        for variant in variants {
            var streamInf = "BANDWIDTH=\(variant.bandwidth)"
            if !variant.resolution.isEmpty {
                streamInf += ",RESOLUTION=\(variant.resolution)"
            }
            masterContent += "#EXT-X-STREAM-INF:\(streamInf)\n"
            masterContent += "\(variant.fileName)\n"
        }

        let masterFile = playlistDir.appendingPathComponent("master.m3u8")
        try masterContent.write(to: masterFile, atomically: true, encoding: .utf8)
    }

    private func sendProgress(for task: DownloadTask, onProgress: @escaping ([String: Any]) -> Void) {
        let currentTime = Int64(Date().timeIntervalSince1970 * 1000)
        let timeElapsed = max(1, currentTime - task.startTime)
        let currentSpeed = Double(task.downloadedBytes) * 1000.0 / Double(timeElapsed)

        task.speedHistory.append(currentSpeed)
        if task.speedHistory.count > 10 {
            task.speedHistory.removeFirst()
        }

        let avgSpeed = task.speedHistory.isEmpty ? currentSpeed : task.speedHistory.reduce(0, +) / Double(task.speedHistory.count)

        let progress = task.totalBytes > 0 ? Int((Double(task.downloadedBytes) * 100.0) / Double(task.totalBytes)) : -1

        let remainingBytes = task.totalBytes - task.downloadedBytes
        let estimatedTimeRemaining = (avgSpeed > 0 && remainingBytes > 0) ? Int64(Double(remainingBytes) / avgSpeed * 1000) : -1

        let progressData: [String: Any] = [
            "url": task.url,
            "filePath": task.filePath,
            "progress": progress,
            "bytesDownloaded": task.downloadedBytes,
            "totalBytes": task.totalBytes,
            "status": task.status.rawValue,
            "error": task.error ?? "",
            "speed": avgSpeed,
            "estimatedTimeRemaining": estimatedTimeRemaining
        ]

        DispatchQueue.main.async {
            onProgress(progressData)
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        urlSession.invalidateAndCancel()
    }
}

// MARK: - Atomic Types

private class AtomicInt64 {
    private var _value: Int64 = 0
    private let lock = NSLock()

    init(_ initialValue: Int64 = 0) {
        _value = initialValue
    }

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func setValue(_ newValue: Int64) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }

    func add(_ amount: Int64) {
        lock.lock()
        defer { lock.unlock() }
        _value += amount
    }

    func increment() {
        add(1)
    }
}

private class AtomicInt {
    private var _value: Int = 0
    private let lock = NSLock()

    init(_ initialValue: Int = 0) {
        _value = initialValue
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func setValue(_ newValue: Int) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }

    func add(_ amount: Int) {
        lock.lock()
        defer { lock.unlock() }
        _value += amount
    }

    func increment() {
        add(1)
    }
}

private class AtomicBool {
    private var _value: Bool = false
    private let lock = NSLock()

    init(_ initialValue: Bool = false) {
        _value = initialValue
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func setValue(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }
}

// MARK: - Priority Queue

private class PriorityQueue<Element: Comparable> {
    private var elements: [Element] = []
    private let lock = NSLock()

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return elements.isEmpty
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return elements.count
    }

    func enqueue(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }

        elements.append(element)
        elements.sort() // Keep sorted for priority order
    }

    func dequeue() -> Element? {
        lock.lock()
        defer { lock.unlock() }

        guard !elements.isEmpty else { return nil }
        return elements.removeFirst()
    }

    func peek() -> Element? {
        lock.lock()
        defer { lock.unlock() }
        return elements.first
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        elements.removeAll()
    }
}

// MARK: - AsyncSemaphore (Enhanced)

actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.count = value
    }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if waiters.isEmpty {
            count += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }

    func getValue() -> Int {
        return count
    }
}

// MARK: - Enhanced HTTP Client for iOS

extension HighPerformanceHlsDownloader {

    private func createOptimizedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default

        // Connection settings
        configuration.httpMaximumConnectionsPerHost = 20
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 300

        // Cache settings
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        // Performance settings
        configuration.shouldUseExtendedBackgroundIdleMode = true
        configuration.networkServiceType = .video // Optimize for video content

        // HTTP settings
        configuration.httpShouldUsePipelining = true
        configuration.httpShouldSetCookies = false

        return URLSession(configuration: configuration)
    }
}

// MARK: - Network Monitoring (iOS Specific)

extension HighPerformanceHlsDownloader {

    private func setupNetworkMonitoring() {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "NetworkMonitor")

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            self.configLock.lock()
            defer { self.configLock.unlock() }

            if path.status == .satisfied {
                if path.isExpensive {
                    // Cellular connection - reduce concurrent downloads
                    self.config.concurrentDownloaders = min(self.config.concurrentDownloaders, 8)
                    self.config.maxConnections = min(self.config.maxConnections, 12)
                } else {
                    // WiFi connection - can use more resources
                    self.config.concurrentDownloaders = min(self.config.concurrentDownloaders + 2, 20)
                    self.config.maxConnections = min(self.config.maxConnections + 5, 30)
                }
            }
        }

        monitor.start(queue: queue)
    }
}

// MARK: - Error Handling Extensions

extension HighPerformanceHlsDownloader {

    enum DownloadError: Error, LocalizedError {
        case invalidURL(String)
        case networkError(String)
        case fileSystemError(String)
        case parsingError(String)
        case timeoutError
        case insufficientStorage

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "Invalid URL: \(url)"
            case .networkError(let message):
                return "Network error: \(message)"
            case .fileSystemError(let message):
                return "File system error: \(message)"
            case .parsingError(let message):
                return "Parsing error: \(message)"
            case .timeoutError:
                return "Download timeout"
            case .insufficientStorage:
                return "Insufficient storage space"
            }
        }
    }

    private func handleDownloadError(_ error: Error, for segment: SegmentTask) -> Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return DownloadError.timeoutError
            case .notConnectedToInternet, .networkConnectionLost:
                return DownloadError.networkError("No internet connection")
            case .cannotFindHost, .cannotConnectToHost:
                return DownloadError.networkError("Cannot connect to server")
            default:
                return DownloadError.networkError(urlError.localizedDescription)
            }
        }

        return error
    }
}

// MARK: - Performance Optimization Extensions

extension HighPerformanceHlsDownloader {

    private func optimizeForSegmentSize(_ segmentSize: Int64) {
        configLock.lock()
        defer { configLock.unlock() }

        switch segmentSize {
        case 0...50_000: // Very small segments
            config.concurrentDownloaders = 25
            config.bufferSize = 4096
            config.useChunking = false

        case 50_001...200_000: // Small segments
            config.concurrentDownloaders = 20
            config.bufferSize = 8192
            config.useChunking = false

        case 200_001...1_000_000: // Medium segments
            config.concurrentDownloaders = 15
            config.bufferSize = 16384
            config.useChunking = false

        case 1_000_001...5_000_000: // Large segments
            config.concurrentDownloaders = 10
            config.bufferSize = 32768
            config.useChunking = true
            config.chunkSize = 512_000

        default: // Very large segments
            config.concurrentDownloaders = 8
            config.bufferSize = 65536
            config.useChunking = true
            config.chunkSize = 1_000_000
        }
    }

    private func adaptToNetworkConditions() {
        metricsLock.lock()
        let metrics = performanceMetrics
        metricsLock.unlock()

        configLock.lock()
        defer { configLock.unlock() }

        if metrics.avgDownloadSpeed > 0 {
            let speedMBps = metrics.avgDownloadSpeed / (1024 * 1024)

            switch speedMBps {
            case 0...1: // Slow connection
                config.concurrentDownloaders = min(config.concurrentDownloaders, 5)
                config.maxConnections = min(config.maxConnections, 8)

            case 1...5: // Medium connection
                config.concurrentDownloaders = min(config.concurrentDownloaders, 12)
                config.maxConnections = min(config.maxConnections, 18)

            default: // Fast connection
                config.concurrentDownloaders = min(config.concurrentDownloaders + 2, 25)
                config.maxConnections = min(config.maxConnections + 5, 35)
            }
        }
    }
}