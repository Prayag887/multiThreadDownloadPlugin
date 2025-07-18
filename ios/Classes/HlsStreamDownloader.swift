import Foundation
import Combine

// MARK: - Key Fixes Applied:
// 1. Fixed completion detection in downloadWorker
// 2. Added proper final progress sending
// 3. Fixed worker termination logic
// 4. Added completion state management
// 5. Fixed progress monitoring termination

// MARK: - Data Models (unchanged, keeping for completeness)

struct PerformanceMetrics {
    var avgDownloadSpeed: Double = 0.0
    var connectionSuccessRate: Double = 1.0
    var lastSpeedUpdate: TimeInterval = 0
    var speedHistory: [Double] = []
}

struct AdaptiveConfig {
    var concurrentDownloaders: Int
    var maxConnections: Int
    var useChunking: Bool
    var chunkSize: Int
    var bufferSize: Int

    init(concurrentDownloaders: Int = 12, maxConnections: Int = 20, useChunking: Bool = false, chunkSize: Int = 256000, bufferSize: Int = 16384) {
        self.concurrentDownloaders = concurrentDownloaders
        self.maxConnections = maxConnections
        self.useChunking = useChunking
        self.chunkSize = chunkSize
        self.bufferSize = bufferSize
    }

    mutating func adapt(metrics: PerformanceMetrics, segmentSize: Int64) {
        switch segmentSize {
        case 0...100_000: // Small segments (≤100KB)
            concurrentDownloaders = 20
            maxConnections = 30
            useChunking = false
            bufferSize = 8192
        case 100_001...1_000_000: // Medium segments (≤1MB)
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

struct SegmentTask {
    let url: String
    let fileName: String
    let duration: Double

    init(url: String, fileName: String, duration: Double = 10.0) {
        self.url = url
        self.fileName = fileName
        self.duration = duration
    }
}

class PrioritySegmentTask: Comparable {
    let segment: SegmentTask
    let priority: Int
    let segmentIndex: Int
    var retryCount: Int = 0
    var failed: Bool = false

    init(segment: SegmentTask, priority: Int, segmentIndex: Int) {
        self.segment = segment
        self.priority = priority
        self.segmentIndex = segmentIndex
    }

    static func < (lhs: PrioritySegmentTask, rhs: PrioritySegmentTask) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority // Higher priority first
        }
        return lhs.segmentIndex < rhs.segmentIndex
    }

    static func == (lhs: PrioritySegmentTask, rhs: PrioritySegmentTask) -> Bool {
        return lhs.priority == rhs.priority && lhs.segmentIndex == rhs.segmentIndex
    }
}

struct VariantPlaylist {
    let url: String
    let fileName: String
    let bandwidth: Int64
    let resolution: String

    init(url: String, fileName: String, bandwidth: Int64 = 0, resolution: String = "") {
        self.url = url
        self.fileName = fileName
        self.bandwidth = bandwidth
        self.resolution = resolution
    }
}

struct ProgressUpdate {
    let bytesDownloaded: Int64
    let downloadTime: TimeInterval
    let success: Bool
}

// MARK: - Async-Safe Thread-Safe Collections

@available(iOS 13.0, *)
actor AsyncPriorityQueue<T: Comparable> {
    private var heap: [T] = []
    private var waitingTasks: [CheckedContinuation<T?, Never>] = []
    private var isCompleted: Bool = false // ✅ Added completion state

    var isEmpty: Bool {
        heap.isEmpty
    }

    func offer(_ element: T) {
        guard !isCompleted else { return } // ✅ Don't accept new items if completed

        heap.append(element)
        heap.sort()

        // Resume any waiting tasks
        if !waitingTasks.isEmpty {
            let continuation = waitingTasks.removeFirst()
            if !heap.isEmpty {
                continuation.resume(returning: heap.removeFirst())
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    func poll() async -> T? {
        if !heap.isEmpty {
            return heap.removeFirst()
        }

        if isCompleted {
            return nil // ✅ Return nil if completed
        }

        return await withCheckedContinuation { continuation in
            waitingTasks.append(continuation)
        }
    }

    func pollWithTimeout(timeout: TimeInterval) async -> T? {
        if !heap.isEmpty {
            return heap.removeFirst()
        }

        if isCompleted {
            return nil // ✅ Return nil if completed
        }

        return await withTaskGroup(of: T?.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            group.addTask {
                return await self.poll()
            }

            guard let result = await group.next() else {
                group.cancelAll()
                return nil
            }

            group.cancelAll()

            if result == nil {
                await self.cleanupWaitingTasks()
            }

            return result
        }
    }

    // ✅ Added method to mark queue as completed
    func markCompleted() {
        isCompleted = true
        // Resume all waiting tasks with nil
        for continuation in waitingTasks {
            continuation.resume(returning: nil)
        }
        waitingTasks.removeAll()
    }

    private func cleanupWaitingTasks() async {
        for continuation in waitingTasks {
            continuation.resume(returning: nil)
        }
        waitingTasks.removeAll()
    }
}

// MARK: - Async-Safe Atomic Types

@available(iOS 13.0, *)
actor AsyncAtomicInt {
    private var _value: Int = 0

    init(_ value: Int = 0) {
        _value = value
    }

    var value: Int {
        _value
    }

    func add(_ amount: Int) {
        _value += amount
    }

    func increment() {
        _value += 1
    }

    func setValue(_ newValue: Int) {
        _value = newValue
    }
}

@available(iOS 13.0, *)
actor AsyncAtomicInt64 {
    private var _value: Int64 = 0

    init(_ value: Int64 = 0) {
        _value = value
    }

    var value: Int64 {
        _value
    }

    func add(_ amount: Int64) {
        _value += amount
    }

    func setValue(_ newValue: Int64) {
        _value = newValue
    }
}

@available(iOS 13.0, *)
actor AsyncAtomicBool {
    private var _value: Bool = false

    init(_ value: Bool = false) {
        _value = value
    }

    var value: Bool {
        _value
    }

    func setValue(_ newValue: Bool) {
        _value = newValue
    }
}

// MARK: - Async-Safe Performance Metrics Actor

@available(iOS 13.0, *)
actor PerformanceMetricsActor {
    private var metrics = PerformanceMetrics()

    func getMetrics() -> PerformanceMetrics {
        metrics
    }

    func updateSpeed(_ speed: Double, at time: TimeInterval) {
        metrics.speedHistory.append(speed)
        if metrics.speedHistory.count > 20 {
            metrics.speedHistory.removeFirst()
        }

        metrics.avgDownloadSpeed = metrics.speedHistory.reduce(0, +) / Double(metrics.speedHistory.count)
        metrics.lastSpeedUpdate = time
    }
}

// MARK: - Async-Safe Config Actor

@available(iOS 13.0, *)
actor ConfigActor {
    private var config = AdaptiveConfig()

    func getConfig() -> AdaptiveConfig {
        config
    }

    func adaptConfig(metrics: PerformanceMetrics, segmentSize: Int64) {
        config.adapt(metrics: metrics, segmentSize: segmentSize)
    }
}

// MARK: - Main HLS Downloader Class

@available(iOS 15.0, *)
class HighPerformanceHlsDownloader {

    // MARK: - Properties

    private let session: URLSession
    private let metricsActor = PerformanceMetricsActor()
    private let configActor = ConfigActor()

    // MARK: - Initialization

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 30
        configuration.urlCache = nil

        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Main Download Function (✅ FIXED)

   @available(iOS 15.0, *)
   func downloadHlsStreamAdvanced(
       task: MTDownloadTask,
       basePath: String,
       onProgress: @escaping ([String: Any]) -> Void
   ) async throws {

       task.status = .downloading
       task.startTime = Date().timeIntervalSince1970

       let playlistDir = URL(fileURLWithPath: basePath)
           .appendingPathComponent(task.fileName.replacingOccurrences(of: ".m3u8", with: ""))

       try FileManager.default.createDirectory(at: playlistDir, withIntermediateDirectories: true)

       guard let baseURL = URL(string: task.url) else {
           throw NSError(domain: "Invalid URL", code: -1)
       }

       let totalDownloadedBytes = AsyncAtomicInt64(0)
       let downloadedSegments = AsyncAtomicInt(0)
       let firstVariantSegmentCount = AsyncAtomicInt(0)
       let isCompleted = AsyncAtomicBool(false)

       do {
           // Phase 1: Analyze HLS stream
           print("Analyzing HLS stream...")
           let (variants, avgSegmentSize) = try await analyzeHlsStream(
               masterUrl: task.url,
               headers: task.headers,
               baseUri: baseURL
           )

           // Phase 2: Configure
           let currentMetrics = await metricsActor.getMetrics()
           await configActor.adaptConfig(metrics: currentMetrics, segmentSize: avgSegmentSize)
           let currentConfig = await configActor.getConfig()

           // Phase 3: Create queues and channels
           let segmentQueue = AsyncPriorityQueue<PrioritySegmentTask>()
           let progressSubject = PassthroughSubject<ProgressUpdate, Never>()

           // Phase 4: Process only the first playlist (first variant only)
           print("Processing first variant only...")
           try await processFirstVariantPlaylist(
               variants: Array(variants.prefix(1)),
               baseUri: baseURL,
               headers: task.headers,
               segmentQueue: segmentQueue,
               firstVariantSegmentCount: firstVariantSegmentCount,
               playlistDir: playlistDir
           )

           let segmentCount = await firstVariantSegmentCount.value
           print("Found \(segmentCount) segments to download in first variant")

           if segmentCount == 0 {
               throw NSError(domain: "No segments found in first variant", code: -1)
           }

           // Phase 5: Launch download workers
           print("Starting \(currentConfig.concurrentDownloaders) download workers...")
           let semaphore = DispatchSemaphore(value: currentConfig.maxConnections)

           await withTaskGroup(of: Void.self) { group in
               // Download workers
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
                           progressSubject: progressSubject,
                           semaphore: semaphore,
                           isCompleted: isCompleted,
                           task: task,
                           onProgress: onProgress
                       )
                   }
               }

               // Progress monitor
               group.addTask {
                   await self.handleProgressUpdatesFirstVariant(
                       progressSubject: progressSubject,
                       task: task,
                       totalDownloadedBytes: totalDownloadedBytes,
                       downloadedSegments: downloadedSegments,
                       firstVariantSegmentCount: firstVariantSegmentCount,
                       onProgress: onProgress,
                       isCompleted: isCompleted
                   )
               }

               // Performance monitor
               group.addTask {
                   await self.monitorPerformance(
                       totalDownloadedBytes: totalDownloadedBytes,
                       startTime: task.startTime,
                       isCompleted: isCompleted
                   )
               }

               // ✅ FIXED Completion checker
               group.addTask {
                   let targetCount = await firstVariantSegmentCount.value
                   print("Waiting for \(targetCount) segments to complete...")

                   while await downloadedSegments.value < targetCount {
                       try? await Task.sleep(nanoseconds: 500_000_000)
                       let current = await downloadedSegments.value
                       print("Progress: \(current)/\(targetCount) segments downloaded")
                   }

                   // ✅ Mark completion immediately when all segments are done
                   await isCompleted.setValue(true)
                   await segmentQueue.markCompleted() // ✅ Mark queue as completed

                   print("✅ All segments downloaded! Marking as completed...")

                   // ✅ Send final progress update
                   task.status = .completed
                   task.downloadedBytes = await totalDownloadedBytes.value
                   ParallelDownloadManager.sendProgress(task: task, onProgress: onProgress)

                   print("✅ Final progress sent!")
               }
           }

           // Phase 9: Final playlist creation (only for first variant)
           try createMasterPlaylist(variants: Array(variants.prefix(1)), playlistDir: playlistDir)

           // ✅ Ensure final state is set
           if task.status != .completed {
               task.status = .completed
               task.downloadedBytes = await totalDownloadedBytes.value
               task.filePath = playlistDir.appendingPathComponent("master.m3u8").path
               ParallelDownloadManager.sendProgress(task: task, onProgress: onProgress)
           }

       } catch {
           await isCompleted.setValue(true)
           task.status = .failed
           task.error = error.localizedDescription
           ParallelDownloadManager.sendProgress(task: task, onProgress: onProgress)
           throw error
       }
   }

    // MARK: - Helper Methods

    private func analyzeHlsStream(
        masterUrl: String,
        headers: [String: String],
        baseUri: URL
    ) async throws -> ([VariantPlaylist], Int64) {

        let masterContent = try await fetchPlaylistContent(url: masterUrl, headers: headers)
        let variants = parseMasterPlaylist(content: masterContent, baseUri: baseUri)
        let avgSegmentSize: Int64 = 500_000

        return (variants, avgSegmentSize)
    }

    private func processFirstVariantPlaylist(
        variants: [VariantPlaylist],
        baseUri: URL,
        headers: [String: String],
        segmentQueue: AsyncPriorityQueue<PrioritySegmentTask>,
        firstVariantSegmentCount: AsyncAtomicInt,
        playlistDir: URL
    ) async throws {

        guard let firstVariant = variants.first else {
            throw NSError(domain: "No variants found", code: -1)
        }

        do {
            print("Processing first variant: \(firstVariant.url)")
            let variantContent = try await fetchPlaylistContent(url: firstVariant.url, headers: headers)
            print("Variant content length: \(variantContent.count)")

            guard let variantUri = URL(string: firstVariant.url) else {
                throw NSError(domain: "Invalid variant URL", code: -1)
            }

            let segments = parseVariantPlaylist(content: variantContent, baseUri: variantUri, variantName: firstVariant.fileName)
            print("Found \(segments.count) segments in first variant")

            await firstVariantSegmentCount.setValue(segments.count)

            // Create prioritized tasks for first variant only
            for (index, segment) in segments.enumerated() {
                let priority = calculateSegmentPriority(index: index, totalSegments: segments.count, variantIndex: 0)
                let priorityTask = PrioritySegmentTask(segment: segment, priority: priority, segmentIndex: index)
                await segmentQueue.offer(priorityTask)
            }

            // Create local playlist for first variant
            try await Task.detached {
                try self.createLocalPlaylist(variant: firstVariant, segments: segments, playlistDir: playlistDir)
            }.value

        } catch {
            print("Error processing first variant \(firstVariant.url): \(error.localizedDescription)")
            throw error
        }
    }

    // ✅ FIXED Download Worker - Proper termination logic
    private func downloadWorker(
        workerId: Int,
        segmentQueue: AsyncPriorityQueue<PrioritySegmentTask>,
        playlistDir: URL,
        headers: [String: String],
        config: AdaptiveConfig,
        totalDownloadedBytes: AsyncAtomicInt64,
        downloadedSegments: AsyncAtomicInt,
        progressSubject: PassthroughSubject<ProgressUpdate, Never>,
        semaphore: DispatchSemaphore,
        isCompleted: AsyncAtomicBool,
        task: MTDownloadTask,
        onProgress: @escaping ([String: Any]) -> Void
    ) async {

        print("Worker \(workerId): Started")

        while await !isCompleted.value {
            // ✅ Poll for work with timeout, will return nil when queue is marked complete
            guard let priorityTask = await segmentQueue.pollWithTimeout(timeout: 1.0) else {
                // ✅ Check completion status before continuing or breaking
                if await isCompleted.value {
                    break
                } else {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                }
            }

            // ✅ Check for termination signal
            if priorityTask.priority == -1 {
                print("Worker \(workerId): Received termination signal")
                break
            }

            await withCheckedContinuation { continuation in
                semaphore.wait()
                continuation.resume()
            }

            do {
                let startTime = Date().timeIntervalSince1970
                let bytesDownloaded = try await downloadSegmentAdvanced(
                    segment: priorityTask.segment,
                    playlistDir: playlistDir,
                    headers: headers,
                    config: config
                )
                let downloadTime = Date().timeIntervalSince1970 - startTime

                // Add bytes and increment counter ONLY after successful download
                await totalDownloadedBytes.add(bytesDownloaded)
                await downloadedSegments.increment()

                progressSubject.send(ProgressUpdate(
                    bytesDownloaded: bytesDownloaded,
                    downloadTime: downloadTime,
                    success: true
                ))

                print("Worker \(workerId): Downloaded segment \(priorityTask.segmentIndex)")

            } catch {
                if priorityTask.retryCount < 3 {
                    priorityTask.retryCount += 1
                    let delay = pow(2.0, Double(priorityTask.retryCount)) * 0.2
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await segmentQueue.offer(priorityTask)
                } else {
                    priorityTask.failed = true
                    progressSubject.send(ProgressUpdate(
                        bytesDownloaded: 0,
                        downloadTime: 0,
                        success: false
                    ))
                    print("Worker \(workerId): Failed to download \(priorityTask.segment.fileName) after retries: \(error.localizedDescription)")
                }
            }

            semaphore.signal()
        }

        print("Worker \(workerId): Exiting")
    }

    // ✅ FIXED Progress Handler - Proper termination
    @available(iOS 15.0, *)
    private func handleProgressUpdatesFirstVariant(
        progressSubject: PassthroughSubject<ProgressUpdate, Never>,
        task: MTDownloadTask,
        totalDownloadedBytes: AsyncAtomicInt64,
        downloadedSegments: AsyncAtomicInt,
        firstVariantSegmentCount: AsyncAtomicInt,
        onProgress: @escaping ([String: Any]) -> Void,
        isCompleted: AsyncAtomicBool
    ) async {

        var lastUpdate: TimeInterval = 0
        let updateInterval: TimeInterval = 0.3 // 300ms

        for await progressUpdate in progressSubject.values {
            // ✅ Check if completed before processing
            if await isCompleted.value {
                print("Progress handler: Detected completion, breaking...")
                break
            }

            let now = Date().timeIntervalSince1970
            let downloadedCount = await downloadedSegments.value
            let totalCount = await firstVariantSegmentCount.value

            if now - lastUpdate >= updateInterval {
                task.downloadedBytes = await totalDownloadedBytes.value

                // Estimate total size based on first variant only
                if task.totalBytes <= 0 && downloadedCount > 0 {
                    let avgBytesPerSegment = task.downloadedBytes / Int64(downloadedCount)
                    task.totalBytes = avgBytesPerSegment * Int64(totalCount)
                }

                ParallelDownloadManager.sendProgress(task: task, onProgress: onProgress)
                lastUpdate = now
            }

            // ✅ Check if all segments are downloaded
            if downloadedCount >= totalCount && totalCount > 0 {
                print("Progress handler: All segments completed (\(downloadedCount)/\(totalCount))")
                break
            }
        }

        print("Progress handler: Exiting")
    }

    // ✅ FIXED Performance Monitor - Proper termination
    private func monitorPerformance(
        totalDownloadedBytes: AsyncAtomicInt64,
        startTime: TimeInterval,
        isCompleted: AsyncAtomicBool
    ) async {

        while await !isCompleted.value {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            let currentTime = Date().timeIntervalSince1970
            let timeElapsed = currentTime - startTime
            let bytesDownloaded = await totalDownloadedBytes.value
            let currentSpeed = Double(bytesDownloaded) * 1000.0 / timeElapsed

            await metricsActor.updateSpeed(currentSpeed, at: currentTime)
        }

        print("Performance monitor: Exiting")
    }

    // MARK: - Remaining methods unchanged...

    private func downloadSegmentAdvanced(
        segment: SegmentTask,
        playlistDir: URL,
        headers: [String: String],
        config: AdaptiveConfig
    ) async throws -> Int64 {

        let segmentFile = playlistDir.appendingPathComponent(segment.fileName)

        // Check if file already exists
        if FileManager.default.fileExists(atPath: segmentFile.path) {
            if let fileSize = try? FileManager.default.attributesOfItem(atPath: segmentFile.path)[.size] as? Int64, fileSize > 0 {
                return fileSize
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

    private func downloadSegmentStreaming(
        segment: SegmentTask,
        segmentFile: URL,
        headers: [String: String],
        config: AdaptiveConfig
    ) async throws -> Int64 {

        guard let url = URL(string: segment.url) else {
            throw NSError(domain: "Invalid segment URL: \(segment.url)", code: -1)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "Invalid response type", code: -1)
        }

        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "Download failed: \(segment.url) (\(httpResponse.statusCode))", code: httpResponse.statusCode)
        }

        try data.write(to: segmentFile)
        return Int64(data.count)
    }

    private func downloadSegmentChunked(
        segment: SegmentTask,
        segmentFile: URL,
        headers: [String: String],
        config: AdaptiveConfig
    ) async throws -> Int64 {

        // Get content length
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

        let chunks = Int((contentLength + Int64(config.chunkSize) - 1) / Int64(config.chunkSize))

        // Create file with proper size
        FileManager.default.createFile(atPath: segmentFile.path, contents: Data(count: Int(contentLength)))

        let fileHandle = try FileHandle(forWritingTo: segmentFile)
        defer { fileHandle.closeFile() }

        // Download chunks in parallel
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for chunkIndex in 0..<chunks {
                group.addTask {
                    let start = Int64(chunkIndex) * Int64(config.chunkSize)
                    let end = min(start + Int64(config.chunkSize) - 1, contentLength - 1)

                    guard let url = URL(string: segment.url) else {
                        throw NSError(domain: "Invalid URL", code: -1)
                    }

                    var request = URLRequest(url: url)
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

                    let (data, response) = try await self.session.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 206 else {
                        throw NSError(domain: "Chunk download failed", code: -1)
                    }

                    return (chunkIndex, data)
                }
            }

            // Write chunks in order
            for try await (chunkIndex, data) in group {
                let offset = Int64(chunkIndex) * Int64(config.chunkSize)
                fileHandle.seek(toFileOffset: UInt64(offset))
                fileHandle.write(data)
            }
        }

        return contentLength
    }

    // MARK: - Utility Methods

    private func calculateSegmentPriority(index: Int, totalSegments: Int, variantIndex: Int) -> Int {
        let basePriority: Int

        // Calculate bounds and ensure they're valid
        let earlyBound = max(5, Int(Double(totalSegments) * 0.1))
        let mediumBound = max(earlyBound, Int(Double(totalSegments) * 0.3))

        switch index {
        case 0..<5:
            basePriority = 100 - index // Highest priority for first segments
        case 5..<earlyBound:
            basePriority = 80 - index // High priority for early segments
        case earlyBound..<mediumBound:
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
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if let contentLengthString = httpResponse.value(forHTTPHeaderField: "Content-Length") {
                return Int64(contentLengthString)
            }
        } catch {
            return nil
        }

        return nil
    }

    private func fetchPlaylistContent(url: String, headers: [String: String]) async throws -> String {
        guard let requestUrl = URL(string: url) else {
            throw NSError(domain: "Invalid URL format: \(url)", code: -1001)
        }

        // Check if this is actually an HLS URL
        guard url.lowercased().contains(".m3u8") else {
            throw NSError(domain: "Not an HLS playlist URL: \(url)", code: -1002)
        }

        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Set User-Agent to avoid blocking
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        print("Fetching playlist from: \(url)")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "Invalid response type", code: -1004)
        }

        print("HTTP Status: \(httpResponse.statusCode) for URL: \(url)")

        guard httpResponse.statusCode == 200 else {
            let errorMessage = "HTTP \(httpResponse.statusCode): Failed to fetch playlist from \(url)"
            throw NSError(domain: errorMessage, code: httpResponse.statusCode)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Invalid playlist encoding", code: -1005)
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Empty playlist content", code: -1006)
        }

        // Validate that it's actually an M3U8 playlist
        guard content.contains("#EXTM3U") else {
            throw NSError(domain: "Invalid M3U8 format: Content does not contain #EXTM3U", code: -1007)
        }

        print("Successfully fetched playlist (\(content.count) characters)")
        return content
    }

    private func resolveURL(_ urlString: String, baseUri: URL) -> String {
        // Handle absolute URLs
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return urlString
        }

        // Handle relative URLs
        if urlString.hasPrefix("/") {
            // Root-relative URL
            guard let scheme = baseUri.scheme, let host = baseUri.host else {
                return baseUri.appendingPathComponent(urlString).absoluteString
            }
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = baseUri.port
            components.path = urlString
            return components.url?.absoluteString ?? baseUri.appendingPathComponent(urlString).absoluteString
        } else {
            // Path-relative URL - resolve against directory of base URL
            let baseDirectory = baseUri.deletingLastPathComponent()
            return baseDirectory.appendingPathComponent(urlString).absoluteString
        }
    }

    private func parseMasterPlaylist(content: String, baseUri: URL) -> [VariantPlaylist] {
        var variants: [VariantPlaylist] = []
        let lines = content.components(separatedBy: .newlines)
        var currentBandwidth: Int64 = 0
        var currentResolution = ""

        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // Extract bandwidth with regex
                let bandwidthPattern = "BANDWIDTH=(\\d+)"
                if let regex = try? NSRegularExpression(pattern: bandwidthPattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let bandwidthRange = Range(match.range(at: 1), in: line)!
                    currentBandwidth = Int64(String(line[bandwidthRange])) ?? 0
                }

                // Extract resolution with regex
                let resolutionPattern = "RESOLUTION=(\\d+x\\d+)"
                if let regex = try? NSRegularExpression(pattern: resolutionPattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let resolutionRange = Range(match.range(at: 1), in: line)!
                    currentResolution = String(line[resolutionRange])
                }

            } else if !line.isEmpty && !line.hasPrefix("#") {
                // Resolve the variant URL properly
                let variantUrl = resolveURL(line, baseUri: baseUri)
                let variantFileName = URL(string: line)?.lastPathComponent ?? line

                // Validate the variant URL
                if variantUrl.lowercased().contains(".m3u8") {
                    variants.append(VariantPlaylist(
                        url: variantUrl,
                        fileName: variantFileName,
                        bandwidth: currentBandwidth,
                        resolution: currentResolution
                    ))
                    print("Found variant: \(variantUrl) (bandwidth: \(currentBandwidth))")
                } else {
                    print("Skipping non-M3U8 variant: \(variantUrl)")
                }

                // Reset for next variant
                currentBandwidth = 0
                currentResolution = ""
            }
        }

        let sortedVariants = variants.sorted { $0.bandwidth > $1.bandwidth }
        print("Parsed \(sortedVariants.count) valid variants from master playlist")
        return sortedVariants
    }

    private func parseVariantPlaylist(content: String, baseUri: URL, variantName: String) -> [SegmentTask] {
        var segments: [SegmentTask] = []
        let lines = content.components(separatedBy: .newlines)
        var segmentDuration: Double = 10.0

        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTINF:") {
                // Enhanced duration parsing
                let durationPattern = "#EXTINF:([\\d.]+)"
                if let regex = try? NSRegularExpression(pattern: durationPattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let durationRange = Range(match.range(at: 1), in: line)!
                    segmentDuration = Double(String(line[durationRange])) ?? 10.0
                }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                // Resolve segment URL properly
                let segmentUrl = resolveURL(line, baseUri: baseUri)
                let originalFileName = URL(string: line)?.lastPathComponent ?? line
                let segmentFileName = "\(variantName)_\(originalFileName)"

                segments.append(SegmentTask(
                    url: segmentUrl,
                    fileName: segmentFileName,
                    duration: segmentDuration
                ))
            }
        }

        print("Parsed \(segments.count) segments from variant playlist")
        return segments
    }

    private func createLocalPlaylist(variant: VariantPlaylist, segments: [SegmentTask], playlistDir: URL) throws {
        var playlistContent = "#EXTM3U\n"
        playlistContent += "#EXT-X-VERSION:3\n"

        let maxDuration = segments.map { Int($0.duration) }.max() ?? 10
        playlistContent += "#EXT-X-TARGETDURATION:\(maxDuration)\n"
        playlistContent += "#EXT-X-MEDIA-SEQUENCE:0\n"

        for segment in segments {
            playlistContent += "#EXTINF:\(segment.duration),\n"
            playlistContent += "\(segment.fileName)\n"
        }

        playlistContent += "#EXT-X-ENDLIST\n"

        let playlistFile = playlistDir.appendingPathComponent(variant.fileName)
        try playlistContent.write(to: playlistFile, atomically: true, encoding: .utf8)
    }

    private func createMasterPlaylist(variants: [VariantPlaylist], playlistDir: URL) throws {
        var masterContent = "#EXTM3U\n"
        masterContent += "#EXT-X-VERSION:3\n"

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

    // MARK: - Cleanup

    func cleanup() {
        session.invalidateAndCancel()
    }
}

// MARK: - Legacy Atomic Types (for compatibility with existing MTDownloadTask)

class AtomicInt {
    private let queue = DispatchQueue(label: "AtomicInt", attributes: .concurrent)
    private var _value: Int = 0

    init(_ value: Int = 0) {
        _value = value
    }

    var value: Int {
        queue.sync { _value }
    }

    func add(_ amount: Int) {
        queue.async(flags: .barrier) {
            self._value += amount
        }
    }

    func increment() {
        add(1)
    }

    func setValue(_ newValue: Int) {
        queue.async(flags: .barrier) {
            self._value = newValue
        }
    }
}

class AtomicInt64 {
    private let queue = DispatchQueue(label: "AtomicInt64", attributes: .concurrent)
    private var _value: Int64 = 0

    init(_ value: Int64 = 0) {
        _value = value
    }

    var value: Int64 {
        queue.sync { _value }
    }

    func add(_ amount: Int64) {
        queue.async(flags: .barrier) {
            self._value += amount
        }
    }

    func setValue(_ newValue: Int64) {
        queue.async(flags: .barrier) {
            self._value = newValue
        }
    }
}

class AtomicBool {
    private let queue = DispatchQueue(label: "AtomicBool", attributes: .concurrent)
    private var _value: Bool = false

    init(_ value: Bool = false) {
        _value = value
    }

    var value: Bool {
        queue.sync { _value }
    }

    func setValue(_ newValue: Bool) {
        queue.async(flags: .barrier) {
            self._value = newValue
        }
    }
}