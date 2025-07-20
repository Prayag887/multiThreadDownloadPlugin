import Flutter
import UIKit
import AVFoundation

// MARK: - Download Task Model
enum MTDownloadStatus: String, CaseIterable {
    case pending = "pending"
    case initializing = "initializing"
    case downloading = "downloading"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

@available(iOS 13.0, *)
class MTDownloadTask {
    let url: String
    let filePath: String
    let fileName: String
    var headers: [String: String]
    
    var status: MTDownloadStatus = .pending
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var startTime: Double = 0
    var speedHistory: [Double] = []
    var error: String?
    var retryCount: Int = 3
    var timeoutSeconds: Int = 30
    var job: Task<Void, Error>?
    
    init(url: String, filePath: String, fileName: String, headers: [String: String] = [:]) {
        self.url = url
        self.filePath = filePath
        self.fileName = fileName
        self.headers = headers
        self.startTime = Date().timeIntervalSince1970 * 1000
    }
}

@available(iOS 15.0, *)
public class MultithreadDownloadsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var channel: FlutterMethodChannel!
    private var eventChannel: FlutterEventChannel!
    private var eventSink: FlutterEventSink?

    // Download management
    private var downloads: [String: MTDownloadTask] = [:]
    private var batchQueue: [[String]] = []
    private var currentBatchIndex = 0
    private var isProcessingBatch = false
    private var batchTask: Task<Void, Never>?
    
    // Native HLS downloader components
    private var downloadSession: AVAssetDownloadURLSession?
    private var activeHLSDownloads: [String: AVAssetDownloadTask] = [:]
    
    // Current batch settings
    private var currentBasePath: String = ""
    private var currentHeaders: [String: String] = [:]
    private var currentMaxConcurrentTasks = 3
    private var currentRetryCount = 3
    private var currentTimeoutSeconds = 30

    // Thread-safe queue using serial dispatch queue
    private let queueAccessQueue = DispatchQueue(label: "download.queue.access", qos: .utility)
    private var downloadQueue: [DownloadRequest] = []
    private var isProcessingQueue = false

    struct DownloadRequest {
        let urls: [String]
        let filePath: String
        let headers: [String: String]
        let maxConcurrentTasks: Int
        let retryCount: Int
        let timeoutSeconds: Int
        let requestId: String

        init(urls: [String], filePath: String, headers: [String: String],
             maxConcurrentTasks: Int, retryCount: Int, timeoutSeconds: Int) {
            self.urls = urls
            self.filePath = filePath
            self.headers = headers
            self.maxConcurrentTasks = maxConcurrentTasks
            self.retryCount = retryCount
            self.timeoutSeconds = timeoutSeconds
            self.requestId = String(Int64(Date().timeIntervalSince1970 * 1000))
        }
    }

    public override init() {
        super.init()
        setupHLSDownloadSession()
    }

    private func setupHLSDownloadSession() {
        let config = URLSessionConfiguration.background(withIdentifier: "com.app.hlsdownloader")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        
        downloadSession = AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: OperationQueue.main
        )
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MultithreadDownloadsPlugin()
        instance.channel = FlutterMethodChannel(name: "multithread_downloads", binaryMessenger: registrar.messenger())
        instance.eventChannel = FlutterEventChannel(name: "multithread_downloads/progress", binaryMessenger: registrar.messenger())

        registrar.addMethodCallDelegate(instance, channel: instance.channel)
        instance.eventChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startDownload":
            handleStartDownload(call: call, result: result)

        case "pauseDownload":
            guard let url = call.arguments as? [String: Any],
                  let urlString = url["url"] as? String else {
                result(false)
                return
            }
            result(pauseDownload(url: urlString))

        case "resumeDownload":
            guard let url = call.arguments as? [String: Any],
                  let urlString = url["url"] as? String else {
                result(false)
                return
            }
            resumeDownload(url: urlString)
            result(true)

        case "cancelDownload":
            guard let url = call.arguments as? [String: Any],
                  let urlString = url["url"] as? String else {
                result(false)
                return
            }
            result(cancelDownload(url: urlString))

        case "pauseAllDownloads":
            result(pauseAllDownloads())

        case "cancelAllDownloads":
            let cancelled = cancelAllDownloads()
            queueAccessQueue.sync {
                downloadQueue.removeAll()
                isProcessingQueue = false
            }
            sendQueueStatus()
            result(cancelled)

        case "getDownloadStatus":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(nil)
                return
            }
            result(getDownloadStatus(url: url))

        case "getBatchProgress":
            result(getBatchProgress())

        case "clearCompletedDownloads":
            result(clearCompletedDownloads())

        case "getQueueSize":
            queueAccessQueue.sync {
                result(downloadQueue.count)
            }

        case "getQueueStatus":
            result(getQueueStatus())

        case "clearQueue":
            queueAccessQueue.sync {
                downloadQueue.removeAll()
            }
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Download Management Methods

    private func handleStartDownload(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(["success": false, "error": "Invalid arguments"])
            return
        }

        let urls = args["urls"] as? [String] ?? []
        guard let filePath = args["filePath"] as? String else {
            result(["success": false, "error": "Missing filePath"])
            return
        }

        let headers = args["headers"] as? [String: String] ?? [:]
        let maxConcurrentTasks = args["maxConcurrentTasks"] as? Int ?? 50
        let retryCount = args["retryCount"] as? Int ?? 3
        let timeoutSeconds = args["timeoutSeconds"] as? Int ?? 30

        let downloadRequest = DownloadRequest(
            urls: urls,
            filePath: filePath,
            headers: headers,
            maxConcurrentTasks: maxConcurrentTasks,
            retryCount: retryCount,
            timeoutSeconds: timeoutSeconds
        )

        // Add to queue
        queueAccessQueue.sync {
            downloadQueue.append(downloadRequest)
        }

        sendQueueStatus()
        processDownloadQueue()

        let queueSize = queueAccessQueue.sync { downloadQueue.count }
        let isProcessing = queueAccessQueue.sync { isProcessingQueue }

        result([
            "success": true,
            "queueSize": queueSize,
            "isProcessing": isProcessing
        ])
    }

    private func processDownloadQueue() {
        queueAccessQueue.sync {
            if isProcessingQueue || downloadQueue.isEmpty {
                return
            }

            if !isReadyForNewBatch() {
                return
            }

            isProcessingQueue = true
        }

        let request = queueAccessQueue.sync {
            downloadQueue.isEmpty ? nil : downloadQueue.removeFirst()
        }

        guard let request = request else {
            queueAccessQueue.sync {
                isProcessingQueue = false
            }
            return
        }

        // Set up batch processing
        currentBasePath = request.filePath
        currentHeaders = request.headers
        currentMaxConcurrentTasks = request.maxConcurrentTasks
        currentRetryCount = request.retryCount
        currentTimeoutSeconds = request.timeoutSeconds

        startBatchDownload(urls: request.urls)
        sendQueueStatus()
    }

    private func startBatchDownload(urls: [String]) {
        // Clear previous downloads if ready for new batch
        if isReadyForNewBatch() {
            clearCompletedDownloads()
        }

        // Set up tasks for current batch
        setupBatchTasks(urls: urls)

        // Start batch processing
        batchTask = Task {
            await processBatch(urls: urls)
        }
    }

    private func setupBatchTasks(urls: [String]) {
        for url in urls {
            let fileName = extractFileName(url: url)

            // Clean and turn it into a folder name
            let folderName = fileName
                .replacingOccurrences(of: ".m3u8", with: "")
                .replacingOccurrences(of: "/", with: "_")

            let safeFolderName = folderName.isEmpty ? "download" : folderName
            let downloadDir = URL(fileURLWithPath: currentBasePath).appendingPathComponent(safeFolderName).path

            // Ensure the directory exists
            try? FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true, attributes: nil)

            // Set up the task
            let task = MTDownloadTask(
                url: url,
                filePath: downloadDir,
                fileName: fileName,
                headers: currentHeaders
            )

            task.retryCount = currentRetryCount
            task.timeoutSeconds = currentTimeoutSeconds

            downloads[url] = task
        }
    }

    private func processBatch(urls: [String]) async {
        // Create semaphore for concurrent task control
        let taskSemaphore = DispatchSemaphore(value: currentMaxConcurrentTasks)

        // Map urls to async tasks
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    await withCheckedContinuation { continuation in
                        taskSemaphore.wait()
                        continuation.resume()
                    }

                    guard let self = self,
                          let task = self.downloads[url] else {
                        taskSemaphore.signal()
                        return
                    }

                    do {
                        if task.url.lowercased().hasSuffix(".m3u8") {
                            try await self.downloadHLS(task: task)
                        } else {
                            try await self.downloadHTTPS(task: task)
                        }
                    } catch {
                        await self.handleTaskFailure(url: url, error: error)
                    }

                    taskSemaphore.signal()
                }
            }
        }

        await handleBatchComplete()
    }

    private func handleBatchComplete() async {
        queueAccessQueue.sync {
            isProcessingQueue = false
        }

        sendBatchProgress()
        sendQueueStatus()

        // Start next batch after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.processDownloadQueue()
        }
    }

    private func handleTaskFailure(url: String, error: Error) async {
        downloads[url]?.status = .failed
        downloads[url]?.error = error.localizedDescription
        if let task = downloads[url] {
            sendProgress(task: task)
        }
    }

    // MARK: - HLS Download Methods

    private func downloadHLS(task: MTDownloadTask) async throws {
        guard let url = URL(string: task.url) else {
            throw URLError(.badURL)
        }

        task.status = .initializing
        task.startTime = Date().timeIntervalSince1970 * 1000

        // Create AVURLAsset
        let asset = AVURLAsset(url: url)

        // Create destination URL
        let destinationURL = URL(fileURLWithPath: task.filePath).appendingPathComponent(task.fileName)

        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Configure download options
        var options: [String: Any] = [:]
        if !task.headers.isEmpty {
            options[AVAssetDownloadTaskMediaSelectionKey] = task.headers
        }

        // Create download task
        guard let downloadTask = downloadSession?.makeAssetDownloadTask(
            asset: asset,
            assetTitle: task.fileName,
            assetArtworkData: nil,
            options: options
        ) else {
            throw URLError(.cannotCreateFile)
        }

        // Store the download task
        activeHLSDownloads[task.url] = downloadTask

        // Start download
        task.status = .downloading
        downloadTask.resume()

        sendProgress(task: task)
    }

    // MARK: - HTTPS Download Methods

    private func downloadHTTPS(task: MTDownloadTask) async throws {
        guard let url = URL(string: task.url) else {
            throw URLError(.badURL)
        }

        // Create the full file path
        let fileURL = URL(fileURLWithPath: task.filePath).appendingPathComponent(task.fileName)

        // Check if file partially exists for resume
        var startByte: Int64 = 0
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            startByte = attributes[.size] as? Int64 ?? 0
            task.downloadedBytes = startByte
        }

        // Configure URL request
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(task.timeoutSeconds)

        // Add headers
        for (key, value) in task.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Add range header for resume
        if startByte > 0 {
            request.setValue("bytes=\(startByte)-", forHTTPHeaderField: "Range")
        }

        task.status = .downloading
        let startTime = Date().timeIntervalSince1970 * 1000

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

            // Get content length
            if let httpResponse = response as? HTTPURLResponse {
                let contentLength = httpResponse.expectedContentLength
                if contentLength > 0 {
                    task.totalBytes = startByte + contentLength
                } else if let contentLengthHeader = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                let length = Int64(contentLengthHeader) {
                    task.totalBytes = startByte + length
                }
            }

            // Create or open file for writing
            let fileHandle: FileHandle
            if startByte > 0 {
                fileHandle = try FileHandle(forWritingTo: fileURL)
                try fileHandle.seek(toOffset: UInt64(startByte))
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
                fileHandle = try FileHandle(forWritingTo: fileURL)
            }

            defer {
                try? fileHandle.close()
            }

            var lastProgressTime = startTime
            let progressInterval: Double = 500 // Update every 500ms

            // Download data
            var buffer = Data()
            for try await byte in asyncBytes {
                try Task.checkCancellation()

                buffer.append(byte)
                task.downloadedBytes += 1

                // Write buffer when it reaches a certain size (e.g., 8KB)
                if buffer.count >= 8192 {
                    try fileHandle.write(contentsOf: buffer)
                    buffer.removeAll()
                }

                // Update progress periodically
                let currentTime = Date().timeIntervalSince1970 * 1000
                if currentTime - lastProgressTime >= progressInterval {
                    updateSpeedHistory(task: task, currentTime: currentTime)
                    sendProgress(task: task)
                    lastProgressTime = currentTime
                }
            }

            // Write any remaining data in buffer
            if !buffer.isEmpty {
                try fileHandle.write(contentsOf: buffer)
            }

            task.status = .completed
            sendProgress(task: task)

        } catch {
            if error is CancellationError {
                task.status = .cancelled
            } else {
                task.status = .failed
                task.error = error.localizedDescription
            }
            sendProgress(task: task)
            throw error
        }
    }

    // MARK: - Control Methods

    private func pauseDownload(url: String) -> Bool {
        guard let task = downloads[url] else { return false }

        if task.status == .downloading {
            if task.url.lowercased().hasSuffix(".m3u8") {
                activeHLSDownloads[url]?.suspend()
            }
            downloads[url]?.status = .paused
            downloads[url]?.job?.cancel()
            return true
        }
        return false
    }

    private func resumeDownload(url: String) {
        guard let task = downloads[url] else { return }

        if task.status == .paused {
            if task.url.lowercased().hasSuffix(".m3u8") {
                activeHLSDownloads[url]?.resume()
                downloads[url]?.status = .downloading
            } else {
                downloads[url]?.speedHistory.removeAll()
                downloads[url]?.job = Task { [weak self] in
                    guard let self = self else { return }
                    do {
                        try await self.downloadHTTPS(task: task)
                    } catch {
                        await self.handleTaskFailure(url: url, error: error)
                    }
                }
            }
        }
    }

    private func cancelDownload(url: String) -> Bool {
        guard let task = downloads[url] else { return false }

        downloads[url]?.status = .cancelled
        downloads[url]?.job?.cancel()

        // Handle HLS downloads
        if task.url.lowercased().hasSuffix(".m3u8") {
            activeHLSDownloads[url]?.cancel()
            activeHLSDownloads.removeValue(forKey: url)
        }

        try? FileManager.default.removeItem(atPath: task.filePath)
        downloads.removeValue(forKey: url)
        return true
    }

    private func pauseAllDownloads() -> Bool {
        var hasActive = false
        for (url, task) in downloads {
            if task.status == .downloading {
                downloads[url]?.status = .paused
                downloads[url]?.job?.cancel()
                
                if task.url.lowercased().hasSuffix(".m3u8") {
                    activeHLSDownloads[url]?.suspend()
                }
                hasActive = true
            }
        }
        batchTask?.cancel()
        return hasActive
    }

    private func cancelAllDownloads() -> Bool {
        batchTask?.cancel()
        batchTask = nil

        for (url, task) in downloads {
            task.job?.cancel()
            
            if task.url.lowercased().hasSuffix(".m3u8") {
                activeHLSDownloads[url]?.cancel()
            }
            
            try? FileManager.default.removeItem(atPath: task.filePath)
        }
        
        downloads.removeAll()
        activeHLSDownloads.removeAll()
        return true
    }

    // MARK: - Status and Progress Methods

    private func getDownloadStatus(url: String) -> [String: Any]? {
        guard let task = downloads[url] else { return nil }

        let currentTime = Date().timeIntervalSince1970 * 1000
        let timeElapsed = max(1.0, currentTime - task.startTime)
        let avgSpeed: Double
        if !task.speedHistory.isEmpty {
            avgSpeed = task.speedHistory.reduce(0, +) / Double(task.speedHistory.count)
        } else {
            avgSpeed = Double(task.downloadedBytes) * 1000.0 / timeElapsed
        }
        let progress = task.totalBytes > 0 ? Int(Double(task.downloadedBytes) * 100.0 / Double(task.totalBytes)) : 0

        return [
            "url": task.url,
            "filePath": task.filePath,
            "progress": progress,
            "bytesDownloaded": task.downloadedBytes,
            "totalBytes": task.totalBytes,
            "status": task.status.rawValue,
            "error": task.error ?? "",
            "speed": avgSpeed
        ]
    }

    private func getBatchProgress() -> [String: Any]? {
        if downloads.isEmpty { return nil }

        let allTasks = Array(downloads.values)
        let totalBytes = allTasks.reduce(0) { $0 + $1.totalBytes }
        let downloadedBytes = allTasks.reduce(0) { $0 + $1.downloadedBytes }
        let completedCount = allTasks.filter { $0.status == .completed }.count
        let failedCount = allTasks.filter { $0.status == .failed }.count
        let cancelledCount = allTasks.filter { $0.status == .cancelled }.count
        let activeCount = allTasks.filter { $0.status == .downloading }.count
        let pausedCount = allTasks.filter { $0.status == .paused }.count

        let overallProgress = totalBytes > 0 ? Int(Double(downloadedBytes) * 100.0 / Double(totalBytes)) : 0

        return [
            "urls": allTasks.map { $0.url },
            "overallProgress": overallProgress,
            "totalBytesDownloaded": downloadedBytes,
            "totalBytes": totalBytes,
            "completedDownloads": completedCount,
            "failedDownloads": failedCount,
            "cancelledDownloads": cancelledCount,
            "activeDownloads": activeCount,
            "pausedDownloads": pausedCount,
            "totalDownloads": allTasks.count,
            "isComplete": isBatchComplete(),
            "isReadyForNewBatch": isReadyForNewBatch()
        ]
    }

    private func clearCompletedDownloads() -> Bool {
        let completedUrls = downloads.compactMap { (key, value) in
            value.status == .completed ? key : nil
        }

        completedUrls.forEach { url in
            downloads.removeValue(forKey: url)
        }

        return true
    }

    private func isBatchComplete() -> Bool {
        if downloads.isEmpty { return true }

        let allTasks = Array(downloads.values)
        let totalTasks = allTasks.count
        let completedTasks = allTasks.filter {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }.count

        return completedTasks >= totalTasks
    }

    private func isReadyForNewBatch() -> Bool {
        let jobNotActive = batchTask?.isCancelled != false
        let noActiveDownloads = !downloads.values.contains {
            $0.status == .downloading || $0.status == .initializing
        }
        let downloadsEmpty = downloads.isEmpty

        return jobNotActive && (downloadsEmpty || (isBatchComplete() && noActiveDownloads))
    }

    // MARK: - Helper Methods

    private func extractFileName(url: String) -> String {
        if let uri = URL(string: url) {
            let path = uri.path
            let fileName = URL(fileURLWithPath: path).lastPathComponent

            if !fileName.isEmpty && fileName.contains(".") {
                return fileName
            } else {
                return "download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp"
            }
        } else {
            return "download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp"
        }
    }

    private func updateSpeedHistory(task: MTDownloadTask, currentTime: Double) {
        let timeElapsed = max(1.0, currentTime - task.startTime)
        let currentSpeed = Double(task.downloadedBytes) * 1000.0 / timeElapsed

        task.speedHistory.append(currentSpeed)

        // Keep only last 10 speed measurements
        if task.speedHistory.count > 10 {
            task.speedHistory.removeFirst()
        }
    }

    private func sendProgress(task: MTDownloadTask) {
        let currentTime = Date().timeIntervalSince1970 * 1000
        let timeElapsed = max(1.0, currentTime - task.startTime)

        let avgSpeed: Double
        if !task.speedHistory.isEmpty {
            avgSpeed = task.speedHistory.reduce(0, +) / Double(task.speedHistory.count)
        } else {
            avgSpeed = Double(task.downloadedBytes) * 1000.0 / timeElapsed
        }

        let progress = task.totalBytes > 0 ? Int(Double(task.downloadedBytes) * 100.0 / Double(task.totalBytes)) : -1

        let progressData: [String: Any] = [
            "url": task.url,
            "filePath": task.filePath,
            "progress": progress,
            "bytesDownloaded": task.downloadedBytes,
            "totalBytes": task.totalBytes,
            "status": task.status.rawValue,
            "error": task.error ?? "",
            "speed": avgSpeed
        ]

        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(progressData)
        }
    }

    private func sendBatchProgress() {
        if let batchProgress = getBatchProgress() {
            var progress = batchProgress
            progress["isBatchProgress"] = true
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(progress)
            }
        }
    }

    private func getQueueStatus() -> [String: Any] {
        return queueAccessQueue.sync {
            [
                "queueSize": downloadQueue.count,
                "isProcessing": isProcessingQueue,
                "isBatchActive": batchTask?.isCancelled == false,
                "currentBatchComplete": isBatchComplete(),
                "isReadyForNewBatch": isReadyForNewBatch()
            ]
        }
    }

    private func sendQueueStatus() {
        var queueStatus = getQueueStatus()
        queueStatus["isQueueStatus"] = true
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(queueStatus)
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        sendQueueStatus()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    deinit {
        cancelAllDownloads()
        queueAccessQueue.sync {
            downloadQueue.removeAll()
            isProcessingQueue = false
        }
    }
}

// MARK: - AVAssetDownloadDelegate
@available(iOS 15.0, *)
extension MultithreadDownloadsPlugin: AVAssetDownloadDelegate {
    
    public func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        // Find the corresponding task
        guard let url = findTaskURL(for: assetDownloadTask),
              let task = downloads[url] else { return }
        
        // Calculate progress based on time ranges
        var percentComplete: Double = 0.0
        
        for value in loadedTimeRanges {
            let loadedTimeRange = value.timeRangeValue
            let loadedDuration = CMTimeGetSeconds(loadedTimeRange.duration)
            let totalDuration = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
            
            if totalDuration > 0 {
                percentComplete += loadedDuration / totalDuration
            }
        }
        
        percentComplete = min(percentComplete, 1.0)
        
        // Update task progress
        if task.totalBytes == 0 {
            task.totalBytes = 100 // Use percentage-based progress for HLS
        }
        
        task.downloadedBytes = Int64(percentComplete * 100)
        
        let currentTime = Date().timeIntervalSince1970 * 1000
        updateSpeedHistory(task: task, currentTime: currentTime)
        
        // Send progress update
        sendProgress(task: task)
    }
    
    public func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let url = findTaskURL(for: assetDownloadTask),
              let task = downloads[url] else { return }
        
        // Move downloaded file to final destination
        let destinationURL = URL(fileURLWithPath: task.filePath).appendingPathComponent(task.fileName)
        
        do {
            // Remove existing file if it exists
            try? FileManager.default.removeItem(at: destinationURL)
            
            // Move the downloaded file
            try FileManager.default.moveItem(at: location, to: destinationURL)
            
            // Update task status
            task.status = .completed
            task.downloadedBytes = task.totalBytes
            
            // Clean up
            activeHLSDownloads.removeValue(forKey: url)
            
        } catch {
            task.status = .failed
            task.error = error.localizedDescription
        }
        
        // Send final progress
        sendProgress(task: task)
    }
    
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let assetDownloadTask = task as? AVAssetDownloadTask,
              let url = findTaskURL(for: assetDownloadTask),
              let downloadTask = downloads[url] else { return }
        
        if let error = error {
            downloadTask.status = .failed
            downloadTask.error = error.localizedDescription
        }
        
        // Clean up
        activeHLSDownloads.removeValue(forKey: url)
        
        // Send final progress
        sendProgress(task: downloadTask)
    }
    
    private func findTaskURL(for assetDownloadTask: AVAssetDownloadTask) -> String? {
        return activeHLSDownloads.first { $0.value == assetDownloadTask }?.key
    }
}
