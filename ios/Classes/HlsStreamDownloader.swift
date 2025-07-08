import Foundation
import Combine

// MARK: - Task Status Enum
enum MTDownloadStatus: String, CaseIterable {
    case pending = "pending"
    case downloading = "downloading"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

// MARK: - Download Task Model
class MTDownloadTask {
    let id: String
    let url: String
    let fileName: String
    let headers: [String: String]
    
    // Thread-safe properties with proper locking
    private let lock = NSRecursiveLock()
    private var _status: MTDownloadStatus = .pending
    private var _downloadedBytes: Int64 = 0
    private var _totalBytes: Int64 = 0
    private var _filePath: String = ""
    private var _error: String? = nil
    private var _startTime: TimeInterval = 0
    private var _speedHistory: [Double] = []
    
    var status: MTDownloadStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _status
        }
        set {
            lock.lock()
            _status = newValue
            lock.unlock()
        }
    }
    
    var downloadedBytes: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _downloadedBytes
        }
        set {
            lock.lock()
            _downloadedBytes = newValue
            lock.unlock()
        }
    }
    
    var totalBytes: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _totalBytes
        }
        set {
            lock.lock()
            _totalBytes = newValue
            lock.unlock()
        }
    }
    
    var filePath: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _filePath
        }
        set {
            lock.lock()
            _filePath = newValue
            lock.unlock()
        }
    }
    
    var error: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _error
        }
        set {
            lock.lock()
            _error = newValue
            lock.unlock()
        }
    }
    
    var startTime: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _startTime
        }
        set {
            lock.lock()
            _startTime = newValue
            lock.unlock()
        }
    }
    
    var speedHistory: [Double] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _speedHistory
        }
        set {
            lock.lock()
            _speedHistory = newValue
            lock.unlock()
        }
    }
    
    init(id: String = UUID().uuidString, url: String, fileName: String, headers: [String: String] = [:]) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.headers = headers
    }
    
    func addSpeedSample(_ speed: Double) {
        lock.lock()
        _speedHistory.append(speed)
        if _speedHistory.count > 10 {
            _speedHistory.removeFirst()
        }
        lock.unlock()
    }
    
    func getAverageSpeed() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return _speedHistory.isEmpty ? 0 : _speedHistory.reduce(0, +) / Double(_speedHistory.count)
    }
}

// MARK: - Performance Metrics
struct PerformanceMetrics {
    var avgDownloadSpeed: Double = 0.0
    var connectionSuccessRate: Double = 1.0
    var lastSpeedUpdate: TimeInterval = 0
    var speedHistory: [Double] = []
    var totalConnections: Int = 0
    var successfulConnections: Int = 0
    
    mutating func recordConnection(success: Bool) {
        totalConnections += 1
        if success {
            successfulConnections += 1
        }
        connectionSuccessRate = Double(successfulConnections) / Double(totalConnections)
    }
}

// MARK: - Adaptive Configuration
struct AdaptiveConfig {
    var concurrentDownloaders: Int
    var maxConnections: Int
    var useChunking: Bool
    var chunkSize: Int
    var bufferSize: Int
    var maxRetries: Int
    var retryDelay: TimeInterval

    init(concurrentDownloaders: Int = 12,
         maxConnections: Int = 20,
         useChunking: Bool = false,
         chunkSize: Int = 256000,
         bufferSize: Int = 16384,
         maxRetries: Int = 3,
         retryDelay: TimeInterval = 1.0) {
        self.concurrentDownloaders = concurrentDownloaders
        self.maxConnections = maxConnections
        self.useChunking = useChunking
        self.chunkSize = chunkSize
        self.bufferSize = bufferSize
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }

    mutating func adapt(metrics: PerformanceMetrics, segmentSize: Int64) {
        // Size-based adaptation
        switch segmentSize {
        case 0...100_000: // Small segments (≤100KB)
            concurrentDownloaders = min(20, maxConnections)
            maxConnections = 30
            useChunking = false
            bufferSize = 8192
        case 100_001...1_000_000: // Medium segments (≤1MB)
            concurrentDownloaders = min(15, maxConnections)
            maxConnections = 25
            useChunking = false
            bufferSize = 16384
        default: // Large segments (>1MB)
            concurrentDownloaders = min(10, maxConnections)
            maxConnections = 15
            useChunking = true
            chunkSize = 512_000
            bufferSize = 32768
        }

        // Performance-based adaptation
        if metrics.avgDownloadSpeed > 0 {
            let networkCapacity = metrics.avgDownloadSpeed * 1.2
            let utilizationRatio = metrics.avgDownloadSpeed / networkCapacity
            
            if utilizationRatio < 0.7 && concurrentDownloaders < 25 {
                concurrentDownloaders = min(concurrentDownloaders + 2, 25)
            } else if utilizationRatio > 0.95 && concurrentDownloaders > 5 {
                concurrentDownloaders = max(concurrentDownloaders - 1, 5)
            }
        }
        
        // Connection success rate adaptation
        if metrics.connectionSuccessRate < 0.8 {
            maxRetries = min(maxRetries + 1, 5)
            retryDelay = min(retryDelay * 1.5, 5.0)
        } else if metrics.connectionSuccessRate > 0.95 {
            maxRetries = max(maxRetries - 1, 2)
            retryDelay = max(retryDelay * 0.8, 0.5)
        }
    }
}

// MARK: - Segment Task
struct SegmentTask {
    let url: String
    let fileName: String
    let duration: Double
    let expectedSize: Int64?

    init(url: String, fileName: String, duration: Double = 10.0, expectedSize: Int64? = nil) {
        self.url = url
        self.fileName = fileName
        self.duration = duration
        self.expectedSize = expectedSize
    }
}

// MARK: - Priority Segment Task
class PrioritySegmentTask: Comparable {
    let segment: SegmentTask
    let priority: Int
    let segmentIndex: Int
    
    private let lock = NSLock()
    private var _retryCount: Int = 0
    private var _failed: Bool = false
    private var _lastAttempt: TimeInterval = 0
    
    var retryCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _retryCount
        }
        set {
            lock.lock()
            _retryCount = newValue
            _lastAttempt = Date().timeIntervalSince1970
            lock.unlock()
        }
    }
    
    var failed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _failed
        }
        set {
            lock.lock()
            _failed = newValue
            lock.unlock()
        }
    }
    
    var lastAttempt: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastAttempt
        }
    }

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

// MARK: - Variant Playlist
struct VariantPlaylist {
    let url: String
    let fileName: String
    let bandwidth: Int64
    let resolution: String
    let codecs: String

    init(url: String, fileName: String, bandwidth: Int64 = 0, resolution: String = "", codecs: String = "") {
        self.url = url
        self.fileName = fileName
        self.bandwidth = bandwidth
        self.resolution = resolution
        self.codecs = codecs
    }
}

// MARK: - Progress Update
struct ProgressUpdate {
    let bytesDownloaded: Int64
    let downloadTime: TimeInterval
    let success: Bool
    let error: Error?
    let segmentIndex: Int
    
    init(bytesDownloaded: Int64, downloadTime: TimeInterval, success: Bool, error: Error? = nil, segmentIndex: Int = -1) {
        self.bytesDownloaded = bytesDownloaded
        self.downloadTime = downloadTime
        self.success = success
        self.error = error
        self.segmentIndex = segmentIndex
    }
}

// MARK: - Thread-Safe Priority Queue
class ThreadSafePriorityQueue<T: Comparable> {
    private var heap: [T] = []
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var _isShutdown = false
    
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heap.isEmpty
    }
    
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return heap.count
    }
    
    func offer(_ element: T) {
        lock.lock()
        defer { lock.unlock() }
        
        if _isShutdown { return }
        
        heap.append(element)
        heap.sort()
        semaphore.signal()
    }
    
    func poll(timeout: TimeInterval = .infinity) -> T? {
        let timeoutTime = timeout == .infinity ? .distantFuture : DispatchTime.now() + timeout
        
        if semaphore.wait(timeout: timeoutTime) == .success {
            lock.lock()
            defer { lock.unlock() }
            
            if _isShutdown || heap.isEmpty {
                return nil
            }
            
            return heap.removeFirst()
        }
        return nil
    }
    
    func shutdown() {
        lock.lock()
        _isShutdown = true
        let signalCount = heap.count + 10 // Extra signals to wake up waiting threads
        lock.unlock()
        
        // Signal waiting threads
        for _ in 0..<signalCount {
            semaphore.signal()
        }
    }
}

// MARK: - Enhanced Atomic Types
class AtomicInt {
    private var _value: Int = 0
    private let lock = NSLock()

    init(_ value: Int = 0) {
        _value = value
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func add(_ amount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += amount
        return _value
    }

    @discardableResult
    func increment() -> Int {
        return add(1)
    }

    @discardableResult
    func setValue(_ newValue: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let oldValue = _value
        _value = newValue
        return oldValue
    }
    
    func compareAndSwap(expected: Int, newValue: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _value == expected {
            _value = newValue
            return true
        }
        return false
    }
}

class AtomicInt64 {
    private var _value: Int64 = 0
    private let lock = NSLock()

    init(_ value: Int64 = 0) {
        _value = value
    }

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func add(_ amount: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        _value += amount
        return _value
    }

    @discardableResult
    func setValue(_ newValue: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let oldValue = _value
        _value = newValue
        return oldValue
    }
    
    func compareAndSwap(expected: Int64, newValue: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _value == expected {
            _value = newValue
            return true
        }
        return false
    }
}

class AtomicBool {
    private var _value: Bool = false
    private let lock = NSLock()

    init(_ value: Bool = false) {
        _value = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func setValue(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let oldValue = _value
        _value = newValue
        return oldValue
    }
    
    func compareAndSwap(expected: Bool, newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _value == expected {
            _value = newValue
            return true
        }
        return false
    }
}

// MARK: - Thread-Safe Performance Metrics
class ThreadSafePerformanceMetrics {
    private var metrics = PerformanceMetrics()
    private let lock = NSLock()
    
    func recordConnection(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        metrics.recordConnection(success: success)
    }
    
    func updateSpeed(_ speed: Double) {
        lock.lock()
        defer { lock.unlock() }
        metrics.speedHistory.append(speed)
        if metrics.speedHistory.count > 20 {
            metrics.speedHistory.removeFirst()
        }
        metrics.avgDownloadSpeed = metrics.speedHistory.reduce(0, +) / Double(metrics.speedHistory.count)
        metrics.lastSpeedUpdate = Date().timeIntervalSince1970
    }
    
    func getSnapshot() -> PerformanceMetrics {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }
}

// MARK: - Main HLS Downloader Class
@available(iOS 13.0, *)
class HighPerformanceHlsDownloader {
    
    // MARK: - Properties
    private let session: URLSession
    private let performanceMetrics = ThreadSafePerformanceMetrics()
    private var config = AdaptiveConfig()
    private let configLock = NSLock()
    private var cancellationTokens: [String: AtomicBool] = [:]
    private let cancellationLock = NSLock()
    
    // MARK: - Initialization
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 30
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.shouldUseExtendedBackgroundIdleMode = true
        
        self.session = URLSession(configuration: configuration)
    }
    
    // MARK: - Main Download Function
    @available(iOS 15.0, *)
    func downloadHlsStreamAdvanced(
        task: MTDownloadTask,
        basePath: String,
        onProgress: @escaping ([String: Any]) -> Void
    ) async throws {
        
        // Set up cancellation token
        let cancellationToken = AtomicBool(false)
        cancellationLock.lock()
        cancellationTokens[task.id] = cancellationToken
        cancellationLock.unlock()
        
        defer {
            cancellationLock.lock()
            cancellationTokens.removeValue(forKey: task.id)
            cancellationLock.unlock()
        }
        
        // Update task status
        task.status = .downloading
        task.startTime = Date().timeIntervalSince1970
        
        let playlistDir = URL(fileURLWithPath: basePath)
            .appendingPathComponent(task.fileName.replacingOccurrences(of: ".m3u8", with: ""))
        
        try FileManager.default.createDirectory(at: playlistDir, withIntermediateDirectories: true)
        
        guard let baseURL = URL(string: task.url) else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        
        let totalDownloadedBytes = AtomicInt64(0)
        let downloadedSegments = AtomicInt(0)
        let totalSegments = AtomicInt(0)
        let errorCount = AtomicInt(0)
        
        do {
            // Check for cancellation
            try checkCancellation(cancellationToken)
            
            // Phase 1: Analyze HLS stream
            print("Analyzing HLS stream...")
            let (variants, avgSegmentSize) = try await analyzeHlsStream(
                masterUrl: task.url,
                headers: task.headers,
                baseUri: baseURL,
                cancellationToken: cancellationToken
            )
            
            // Phase 2: Configure
            configLock.lock()
            config.adapt(metrics: performanceMetrics.getSnapshot(), segmentSize: avgSegmentSize)
            let currentConfig = config
            configLock.unlock()
            
            // Phase 3: Create queues
            let segmentQueue = ThreadSafePriorityQueue<PrioritySegmentTask>()
            let progressSubject = PassthroughSubject<ProgressUpdate, Never>()
            
            // Phase 4: Process playlists
            print("Processing playlists...")
            try await processVariantPlaylists(
                variants: Array(variants.prefix(1)),
                baseUri: baseURL,
                headers: task.headers,
                segmentQueue: segmentQueue,
                totalSegments: totalSegments,
                playlistDir: playlistDir,
                cancellationToken: cancellationToken
            )
            
            print("Found \(totalSegments.value) segments to download")
            
            if totalSegments.value == 0 {
                throw NSError(domain: "No segments found in playlist", code: -1)
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
                            errorCount: errorCount,
                            progressSubject: progressSubject,
                            semaphore: semaphore,
                            cancellationToken: cancellationToken
                        )
                    }
                }
                
                // Progress monitor
                group.addTask {
                    await self.handleProgressUpdates(
                        progressSubject: progressSubject,
                        task: task,
                        totalDownloadedBytes: totalDownloadedBytes,
                        downloadedSegments: downloadedSegments,
                        totalSegments: totalSegments,
                        onProgress: onProgress,
                        cancellationToken: cancellationToken
                    )
                }
                
                // Performance monitor
                group.addTask {
                    await self.monitorPerformance(
                        totalDownloadedBytes: totalDownloadedBytes,
                        startTime: task.startTime,
                        cancellationToken: cancellationToken
                    )
                }
                
                // Completion monitor
                group.addTask {
                    while !cancellationToken.value && downloadedSegments.value < totalSegments.value {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        print("Progress: \(downloadedSegments.value)/\(totalSegments.value) segments downloaded")
                    }
                    
                    // Shutdown queue
                    segmentQueue.shutdown()
                }
            }
            
            // Check if cancelled
            try checkCancellation(cancellationToken)
            
            // Phase 6: Create final playlists
            try createMasterPlaylist(variants: Array(variants.prefix(1)), playlistDir: playlistDir)
            
            // Update final task state
            task.status = .completed
            task.downloadedBytes = totalDownloadedBytes.value
            task.filePath = playlistDir.appendingPathComponent("master.m3u8").path
            sendProgress(task: task, onProgress: onProgress)
            
        } catch {
            // Handle failure
            task.status = cancellationToken.value ? .cancelled : .failed
            task.error = error.localizedDescription
            sendProgress(task: task, onProgress: onProgress)
            throw error
        }
    }
    
    // MARK: - Cancellation Support
    func cancelDownload(taskId: String) {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        cancellationTokens[taskId]?.setValue(true)
    }
    
    private func checkCancellation(_ token: AtomicBool) throws {
        if token.value {
            throw NSError(domain: "Download cancelled", code: NSUserCancelledError)
        }
    }
    
    // MARK: - Helper Methods
    private func analyzeHlsStream(
        masterUrl: String,
        headers: [String: String],
        baseUri: URL,
        cancellationToken: AtomicBool
    ) async throws -> ([VariantPlaylist], Int64) {
        
        try checkCancellation(cancellationToken)
        
        let masterContent = try await fetchPlaylistContent(url: masterUrl, headers: headers)
        let variants = parseMasterPlaylist(content: masterContent, baseUri: baseUri)
        
        // Estimate average segment size by analyzing first variant
        var avgSegmentSize: Int64 = 500_000 // Default estimate
        
        if let firstVariant = variants.first {
            do {
                let variantContent = try await fetchPlaylistContent(url: firstVariant.url, headers: headers)
                let segments = parseVariantPlaylist(content: variantContent, baseUri: URL(string: firstVariant.url)!, variantName: firstVariant.fileName)
                
                // Sample a few segments to estimate size
                if segments.count > 0 {
                    let sampleCount = min(3, segments.count)
                    var totalSize: Int64 = 0
                    
                    for i in 0..<sampleCount {
                        if let size = try? await getContentLength(url: segments[i].url, headers: headers) {
                            totalSize += size
                        }
                    }
                    
                    if totalSize > 0 {
                        avgSegmentSize = totalSize / Int64(sampleCount)
                    }
                }
            } catch {
                print("Warning: Could not analyze segment sizes, using default estimate")
            }
        }
        
        return (variants, avgSegmentSize)
    }
    
    private func processVariantPlaylists(
        variants: [VariantPlaylist],
        baseUri: URL,
        headers: [String: String],
        segmentQueue: ThreadSafePriorityQueue<PrioritySegmentTask>,
        totalSegments: AtomicInt,
        playlistDir: URL,
        cancellationToken: AtomicBool
    ) async throws {
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (variantIndex, variant) in variants.enumerated() {
                group.addTask {
                    try await self.processVariantPlaylist(
                        variant: variant,
                        baseUri: baseUri,
                        headers: headers,
                        segmentQueue: segmentQueue,
                        totalSegments: totalSegments,
                        variantIndex: variantIndex,
                        playlistDir: playlistDir,
                        cancellationToken: cancellationToken
                    )
                }
            }
            
            try await group.waitForAll()
        }
    }
    
    private func processVariantPlaylist(
        variant: VariantPlaylist,
        baseUri: URL,
        headers: [String: String],
        segmentQueue: ThreadSafePriorityQueue<PrioritySegmentTask>,
        totalSegments: AtomicInt,
        variantIndex: Int,
        playlistDir: URL,
        cancellationToken: AtomicBool
    ) async throws {
        
        try checkCancellation(cancellationToken)
        
        do {
            print("Processing variant: \(variant.url)")
            let variantContent = try await fetchPlaylistContent(url: variant.url, headers: headers)
            print("Variant content length: \(variantContent.count)")
            
            guard let variantUri = URL(string: variant.url) else {
                throw NSError(domain: "Invalid variant URL", code: -1)
            }
            
            let segments = parseVariantPlaylist(content: variantContent, baseUri: variantUri, variantName: variant.fileName)
            print("Found \(segments.count) segments in variant")
            
            totalSegments.add(segments.count)
            
            // Create prioritized tasks
            for (index, segment) in segments.enumerated() {
                try checkCancellation(cancellationToken)
                
                let priority = calculateSegmentPriority(index: index, totalSegments: segments.count, variantIndex: variantIndex)
                let priorityTask = PrioritySegmentTask(segment: segment, priority: priority, segmentIndex: index)
                segmentQueue.offer(priorityTask)
            }
            
            // Create local playlist
            try await Task.detached {
                try self.createLocalPlaylist(variant: variant, segments: segments, playlistDir: playlistDir)
            }.value
            
        } catch {
            print("Error processing variant \(variant.url): \(error.localizedDescription)")
            throw error
        }
    }
    
    private func downloadWorker(
        workerId: Int,
        segmentQueue: ThreadSafePriorityQueue<PrioritySegmentTask>,
        playlistDir: URL,
        headers: [String: String],
        config: AdaptiveConfig,
        totalDownloadedBytes: AtomicInt64,
        downloadedSegments: AtomicInt,
        errorCount: AtomicInt,
        progressSubject: PassthroughSubject<ProgressUpdate, Never>,
        semaphore: DispatchSemaphore,
        cancellationToken: AtomicBool
    ) async {
        
        print("Worker \(workerId): Starting")
        
        while !cancellationToken.value {
            // Poll for work with timeout
            guard let priorityTask = segmentQueue.poll(timeout: 1.0) else {
                if !cancellationToken.value && segmentQueue.isEmpty {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                } else {
                    break
                }
            }
            
            // Check for termination signal
            if priorityTask.priority == -1 || cancellationToken.value {
                break
            }
            
            // Acquire semaphore
            await withCheckedContinuation { continuation in
                semaphore.wait()
                continuation.resume()
            }
            
            defer { semaphore.signal() }
            
            do {
                let startTime = Date().timeIntervalSince1970
                let bytesDownloaded = try await downloadSegmentAdvanced(
                    segment: priorityTask.segment,
                    playlistDir: playlistDir,
                    headers: headers,
                    config: config,
                    cancellationToken: cancellationToken
                )
                let downloadTime = Date().timeIntervalSince1970 - startTime
                
                totalDownloadedBytes.add(bytesDownloaded)
                downloadedSegments.increment()
                
                // Record successful connection
                performanceMetrics.recordConnection(success: true)
                
                progressSubject.send(ProgressUpdate(
                    bytesDownloaded: bytesDownloaded,
                    downloadTime: downloadTime,
                    success: true,
                    segmentIndex: priorityTask.segmentIndex
                ))
                
            } catch {
                // Record failed connection
                performanceMetrics.recordConnection(success: false)
                
                if priorityTask.retryCount < config.maxRetries && !cancellationToken.value {
                    priorityTask.retryCount += 1
                    errorCount.increment()
                    
                    let delay = config.retryDelay * pow(2.0, Double(priorityTask.retryCount))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    segmentQueue.offer(priorityTask)
                } else {
                    priorityTask.failed = true
                    errorCount.increment()
                    progressSubject.send(ProgressUpdate(
                        bytesDownloaded: 0,
                        downloadTime: 0,
                        success: false,
                        error: error,
                        segmentIndex: priorityTask.segmentIndex
                    ))
                    print("Worker \(workerId): Failed to download \(priorityTask.segment.fileName) after \(config.maxRetries) retries: \(error.localizedDescription)")
                }
            }
        }
        
        print("Worker \(workerId): Exiting")
    }
    
    private func downloadSegmentAdvanced(
        segment: SegmentTask,
        playlistDir: URL,
        headers: [String: String],
        config: AdaptiveConfig,
        cancellationToken: AtomicBool
    ) async throws -> Int64 {
        
        try checkCancellation(cancellationToken)
        
        let segmentFile = playlistDir.appendingPathComponent(segment.fileName)
        
        // Check if file already exists and is complete
        if FileManager.default.fileExists(atPath: segmentFile.path) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: segmentFile.path),
               let fileSize = attributes[.size] as? Int64, fileSize > 0 {
                // Verify file integrity if expected size is known
                if let expectedSize = segment.expectedSize {
                    if fileSize >= expectedSize {
                        return fileSize
                    }
                } else {
                    return fileSize
                }
            }
        }
        
        if config.useChunking {
            return try await downloadSegmentChunked(
                segment: segment,
                segmentFile: segmentFile,
                headers: headers,
                config: config,
                cancellationToken: cancellationToken
            )
        } else {
            return try await downloadSegmentStreaming(
                segment: segment,
                segmentFile: segmentFile,
                headers: headers,
                config: config,
                cancellationToken: cancellationToken
            )
        }
    }
    
    private func downloadSegmentStreaming(
        segment: SegmentTask,
        segmentFile: URL,
        headers: [String: String],
        config: AdaptiveConfig,
        cancellationToken: AtomicBool
    ) async throws -> Int64 {
        
        try checkCancellation(cancellationToken)
        
        guard let url = URL(string: segment.url) else {
            throw NSError(domain: "Invalid segment URL: \(segment.url)", code: -1)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        // Set headers
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Set User-Agent if not provided
        if headers["User-Agent"] == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        }
        
        let (data, response) = try await session.data(for: request)
        
        try checkCancellation(cancellationToken)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "Invalid response type", code: -1)
        }
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "Download failed: \(segment.url) (HTTP \(httpResponse.statusCode))", code: httpResponse.statusCode)
        }
        
        // Write atomically
        let tempFile = segmentFile.appendingPathExtension("tmp")
        try data.write(to: tempFile)
        
        try checkCancellation(cancellationToken)
        
        try FileManager.default.moveItem(at: tempFile, to: segmentFile)
        return Int64(data.count)
    }
    
    private func downloadSegmentChunked(
        segment: SegmentTask,
        segmentFile: URL,
        headers: [String: String],
        config: AdaptiveConfig,
        cancellationToken: AtomicBool
    ) async throws -> Int64 {
        
        try checkCancellation(cancellationToken)
        
        // Get content length
        guard let contentLength = try await getContentLength(url: segment.url, headers: headers) else {
            return try await downloadSegmentStreaming(
                segment: segment,
                segmentFile: segmentFile,
                headers: headers,
                config: config,
                cancellationToken: cancellationToken
            )
        }
        
        if contentLength <= config.chunkSize {
            return try await downloadSegmentStreaming(
                segment: segment,
                segmentFile: segmentFile,
                headers: headers,
                config: config,
                cancellationToken: cancellationToken
            )
        }
        
        let chunks = Int((contentLength + Int64(config.chunkSize) - 1) / Int64(config.chunkSize))
        
        // Create temporary file
        let tempFile = segmentFile.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data(count: Int(contentLength)))
        
        let fileHandle = try FileHandle(forWritingTo: tempFile)
        defer {
            fileHandle.closeFile()
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        // Download chunks in parallel
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for chunkIndex in 0..<chunks {
                try checkCancellation(cancellationToken)
                
                group.addTask {
                    let start = Int64(chunkIndex) * Int64(config.chunkSize)
                    let end = min(start + Int64(config.chunkSize) - 1, contentLength - 1)
                    
                    guard let url = URL(string: segment.url) else {
                        throw NSError(domain: "Invalid URL", code: -1)
                    }
                    
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 30
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    
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
                try checkCancellation(cancellationToken)
                
                let offset = Int64(chunkIndex) * Int64(config.chunkSize)
                fileHandle.seek(toFileOffset: UInt64(offset))
                fileHandle.write(data)
            }
        }
        
        try checkCancellation(cancellationToken)
        
        // Move temp file to final location
        try FileManager.default.moveItem(at: tempFile, to: segmentFile)
        return contentLength
    }
    
    @available(iOS 15.0, *)
    private func handleProgressUpdates(
        progressSubject: PassthroughSubject<ProgressUpdate, Never>,
        task: MTDownloadTask,
        totalDownloadedBytes: AtomicInt64,
        downloadedSegments: AtomicInt,
        totalSegments: AtomicInt,
        onProgress: @escaping ([String: Any]) -> Void,
        cancellationToken: AtomicBool
    ) async {
        
        var lastUpdate: TimeInterval = 0
        let updateInterval: TimeInterval = 0.3 // 300ms
        
        for await update in progressSubject.values {
            if cancellationToken.value {
                break
            }
            
            let now = Date().timeIntervalSince1970
            
            if now - lastUpdate >= updateInterval || downloadedSegments.value >= totalSegments.value {
                task.downloadedBytes = totalDownloadedBytes.value
                
                // Estimate total size if not known
                if task.totalBytes <= 0 && downloadedSegments.value > 0 {
                    let avgBytesPerSegment = totalDownloadedBytes.value / Int64(downloadedSegments.value)
                    task.totalBytes = avgBytesPerSegment * Int64(totalSegments.value)
                }
                
                // Update speed metrics
                if update.success && update.downloadTime > 0 {
                    let speed = Double(update.bytesDownloaded) / update.downloadTime
                    task.addSpeedSample(speed)
                }
                
                sendProgress(task: task, onProgress: onProgress)
                lastUpdate = now
            }
            
            // Break if all segments downloaded
            if downloadedSegments.value >= totalSegments.value && totalSegments.value > 0 {
                break
            }
        }
    }
    
    private func monitorPerformance(
        totalDownloadedBytes: AtomicInt64,
        startTime: TimeInterval,
        cancellationToken: AtomicBool
    ) async {
        
        var lastBytes: Int64 = 0
        var lastTime = startTime
        
        while !cancellationToken.value {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            let currentTime = Date().timeIntervalSince1970
            let currentBytes = totalDownloadedBytes.value
            
            if currentBytes > lastBytes {
                let bytesDownloaded = currentBytes - lastBytes
                let timeElapsed = currentTime - lastTime
                
                if timeElapsed > 0 {
                    let currentSpeed = Double(bytesDownloaded) / timeElapsed
                    performanceMetrics.updateSpeed(currentSpeed)
                }
            }
            
            lastBytes = currentBytes
            lastTime = currentTime
        }
    }
    
    // MARK: - Utility Methods
    private func calculateSegmentPriority(index: Int, totalSegments: Int, variantIndex: Int) -> Int {
        let basePriority: Int
        
        switch index {
        case 0..<5:
            basePriority = 100 - index // Highest priority for first segments
        case 5..<Int(Double(totalSegments) * 0.1):
            basePriority = 80 - index // High priority for early segments
        case Int(Double(totalSegments) * 0.1)..<Int(Double(totalSegments) * 0.3):
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
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
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
        
        // Validate HLS URL
        guard url.lowercased().contains(".m3u8") else {
            throw NSError(domain: "Not an HLS playlist URL: \(url)", code: -1002)
        }
        
        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        // Set User-Agent
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
        
        // Validate M3U8 format
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
            // Path-relative URL
            let baseDirectory = baseUri.deletingLastPathComponent()
            return baseDirectory.appendingPathComponent(urlString).absoluteString
        }
    }
    
    private func parseMasterPlaylist(content: String, baseUri: URL) -> [VariantPlaylist] {
        var variants: [VariantPlaylist] = []
        let lines = content.components(separatedBy: .newlines)
        var currentBandwidth: Int64 = 0
        var currentResolution = ""
        var currentCodecs = ""
        
        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // Extract bandwidth
                let bandwidthPattern = "BANDWIDTH=(\\d+)"
                if let regex = try? NSRegularExpression(pattern: bandwidthPattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let bandwidthRange = Range(match.range(at: 1), in: line)!
                    currentBandwidth = Int64(String(line[bandwidthRange])) ?? 0
                }
                
                // Extract resolution
                let resolutionPattern = "RESOLUTION=(\\d+x\\d+)"
                if let regex = try? NSRegularExpression(pattern: resolutionPattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let resolutionRange = Range(match.range(at: 1), in: line)!
                    currentResolution = String(line[resolutionRange])
                }
                
                // Extract codecs
                let codecsPattern = "CODECS=\"([^\"]+)\""
                if let regex = try? NSRegularExpression(pattern: codecsPattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let codecsRange = Range(match.range(at: 1), in: line)!
                    currentCodecs = String(line[codecsRange])
                }
                
            } else if !line.isEmpty && !line.hasPrefix("#") {
                // Resolve variant URL
                let variantUrl = resolveURL(line, baseUri: baseUri)
                let variantFileName = URL(string: line)?.lastPathComponent ?? line
                
                // Validate variant URL
                if variantUrl.lowercased().contains(".m3u8") {
                    variants.append(VariantPlaylist(
                        url: variantUrl,
                        fileName: variantFileName,
                        bandwidth: currentBandwidth,
                        resolution: currentResolution,
                        codecs: currentCodecs
                    ))
                    print("Found variant: \(variantUrl) (bandwidth: \(currentBandwidth))")
                } else {
                    print("Skipping non-M3U8 variant: \(variantUrl)")
                }
                
                // Reset for next variant
                currentBandwidth = 0
                currentResolution = ""
                currentCodecs = ""
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
                // Resolve segment URL
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
        
        let maxDuration = segments.map { Int(ceil($0.duration)) }.max() ?? 10
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
            if !variant.codecs.isEmpty {
                streamInf += ",CODECS=\"\(variant.codecs)\""
            }
            masterContent += "#EXT-X-STREAM-INF:\(streamInf)\n"
            masterContent += "\(variant.fileName)\n"
        }
        
        let masterFile = playlistDir.appendingPathComponent("master.m3u8")
        try masterContent.write(to: masterFile, atomically: true, encoding: .utf8)
    }
    
    private func sendProgress(task: MTDownloadTask, onProgress: ([String: Any]) -> Void) {
        let currentTime = Date().timeIntervalSince1970
        let timeElapsed = max(1.0, currentTime - task.startTime)
        let avgSpeed = task.getAverageSpeed()
        
        let progress = task.totalBytes > 0 ? Int((Double(task.downloadedBytes) * 100.0 / Double(task.totalBytes))) : -1
        
        let remainingBytes = task.totalBytes - task.downloadedBytes
        let estimatedTimeRemaining = avgSpeed > 0 && remainingBytes > 0 ? Int64(Double(remainingBytes) / avgSpeed) : -1
        
        onProgress([
            "taskId": task.id,
            "url": task.url,
            "filePath": task.filePath,
            "progress": progress,
            "bytesDownloaded": task.downloadedBytes,
            "totalBytes": task.totalBytes,
            "status": task.status.rawValue,
            "error": task.error ?? "",
            "speed": avgSpeed,
            "estimatedTimeRemaining": estimatedTimeRemaining,
            "timeElapsed": timeElapsed
        ])
    }
    
    // MARK: - Cleanup
    func cleanup() {
        // Cancel all active downloads
        cancellationLock.lock()
        let tokens = Array(cancellationTokens.values)
        cancellationLock.unlock()
        
        for token in tokens {
            token.setValue(true)
        }
        
        // Invalidate session
        session.invalidateAndCancel()
    }
}

// MARK: - Usage Example
@available(iOS 15.0, *)
class HLSDownloadManager {
    private let downloader = HighPerformanceHlsDownloader()
    private let downloadQueue = DispatchQueue(label: "hls.download.queue", qos: .userInitiated)
    
    func downloadStream(url: String, fileName: String, basePath: String, headers: [String: String] = [:]) async throws {
        let task = MTDownloadTask(
            url: url,
            fileName: fileName,
            headers: headers
        )
        
        print("Starting download: \(url)")
        
        try await downloader.downloadHlsStreamAdvanced(
            task: task,
            basePath: basePath,
            onProgress: { progress in
                DispatchQueue.main.async {
                    self.handleProgress(progress)
                }
            }
        )
        
        print("Download completed: \(task.filePath)")
    }
    
    func cancelDownload(taskId: String) {
        downloader.cancelDownload(taskId: taskId)
    }
    
    private func handleProgress(_ progress: [String: Any]) {
        guard let taskId = progress["taskId"] as? String,
              let url = progress["url"] as? String,
              let status = progress["status"] as? String,
              let progressPercent = progress["progress"] as? Int,
              let bytesDownloaded = progress["bytesDownloaded"] as? Int64,
              let totalBytes = progress["totalBytes"] as? Int64,
              let speed = progress["speed"] as? Double else {
            return
        }
        
        let speedMBps = speed / (1024 * 1024)
        let downloadedMB = Double(bytesDownloaded) / (1024 * 1024)
        let totalMB = Double(totalBytes) / (1024 * 1024)
        
        print("Task: \(taskId)")
        print("Status: \(status)")
        print("Progress: \(progressPercent >= 0 ? "\(progressPercent)%" : "Unknown")")
        print("Downloaded: \(String(format: "%.1f", downloadedMB)) MB / \(String(format: "%.1f", totalMB)) MB")
        print("Speed: \(String(format: "%.1f", speedMBps)) MB/s")
        
        if let error = progress["error"] as? String, !error.isEmpty {
            print("Error: \(error)")
        }
        
        if let eta = progress["estimatedTimeRemaining"] as? Int64, eta > 0 {
            print("ETA: \(eta) seconds")
        }
        
        print("---")
    }
    
    deinit {
        downloader.cleanup()
    }
}

// MARK: - Example Usage
/*
Task {
    let manager = HLSDownloadManager()
    
    do {
        try await manager.downloadStream(
            url: "https://example.com/stream/master.m3u8",
            fileName: "stream.m3u8",
            basePath: "/path/to/downloads",
            headers: [
                "User-Agent": "CustomApp/1.0",
                "Authorization": "Bearer your-token-here"
            ]
        )
    } catch {
        print("Download failed: \(error)")
    }
}
*/
