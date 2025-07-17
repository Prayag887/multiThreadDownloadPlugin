import Foundation

// MARK: - HTTPS Downloader
@available(iOS 15.0, *)
class HttpsDownloader {

    func downloadSingleFile(task: MTDownloadTask, onProgress: @escaping ([String: Any]) -> Void) async throws {
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
                    sendProgress(task: task, onProgress: onProgress)
                    lastProgressTime = currentTime
                }
            }

            // Write any remaining data in buffer
            if !buffer.isEmpty {
                try fileHandle.write(contentsOf: buffer)
            }

            task.status = .completed
            sendProgress(task: task, onProgress: onProgress)

        } catch {
            if error is CancellationError {
                task.status = .cancelled
            } else {
                task.status = .failed
                task.error = error.localizedDescription
            }
            sendProgress(task: task, onProgress: onProgress)
            throw error
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

    func sendProgress(task: MTDownloadTask, onProgress: ([String: Any]) -> Void) {
        let currentTime = Date().timeIntervalSince1970 * 1000
        let timeElapsed = max(1.0, currentTime - task.startTime)

        let avgSpeed: Double
        if !task.speedHistory.isEmpty {
            avgSpeed = task.speedHistory.reduce(0, +) / Double(task.speedHistory.count)
        } else {
            avgSpeed = Double(task.downloadedBytes) * 1000.0 / timeElapsed
        }

        let progress = task.totalBytes > 0 ? Int(Double(task.downloadedBytes) * 100.0 / Double(task.totalBytes)) : -1

        onProgress([
            "url": task.url,
            "filePath": task.filePath,
            "progress": progress,
            "bytesDownloaded": task.downloadedBytes,
            "totalBytes": task.totalBytes,
            "status": task.status.rawValue,
            "error": task.error ?? "",
            "speed": avgSpeed
        ])
    }
}

// MARK: - Parallel Download Manager
@available(iOS 15.0, *)
actor ParallelDownloadManager {

    private var downloads: [String: MTDownloadTask] = [:]
    private var batchQueue: [[String]] = [] // Queue for batches
    private var currentBatchIndex = 0
    private var isProcessingBatch = false

    private var batchTask: Task<Void, Never>?

    // Current batch settings
    private var currentBasePath: String = ""
    private var currentHeaders: [String: String] = [:]
    private var currentMaxConcurrentTasks = 3
    private var currentRetryCount = 3
    private var currentTimeoutSeconds = 30
    private var currentOnProgress: (([String: Any]) -> Void)?

    // Batch completion callback
    private var onBatchComplete: (() -> Void)?
    private var onAllBatchesComplete: (() -> Void)?

    private let httpsDownloader = HttpsDownloader()
    private let hlsDownloader = HighPerformanceHlsDownloader()

    // MARK: - Public Methods

    /// Queue multiple batches for sequential processing
    func queueBatches(
        batches: [[String]],
        basePath: String,
        headers: [String: String],
        maxConcurrentTasks: Int = 3,
        retryCount: Int = 3,
        timeoutSeconds: Int = 30,
        onProgress: @escaping ([String: Any]) -> Void,
        onBatchComplete: (() -> Void)? = nil,
        onAllBatchesComplete: (() -> Void)? = nil
    ) async {
        // Cancel existing processing
        batchTask?.cancel()

        // Set up batch processing
        batchQueue = batches
        currentBatchIndex = 0
        isProcessingBatch = false

        // Store settings
        currentBasePath = basePath
        currentHeaders = headers
        currentMaxConcurrentTasks = maxConcurrentTasks
        currentRetryCount = retryCount
        currentTimeoutSeconds = timeoutSeconds
        currentOnProgress = onProgress
        self.onBatchComplete = onBatchComplete
        self.onAllBatchesComplete = onAllBatchesComplete

        // Start processing
        Task {
            await startNextBatch()
        }
    }

    /// Start a single batch download (existing method, enhanced)
    func startBatchDownload(
        urls: [String],
        basePath: String,
        headers: [String: String],
        maxConcurrentTasks: Int = 3,
        retryCount: Int = 3,
        timeoutSeconds: Int = 30,
        onProgress: @escaping ([String: Any]) -> Void,
        onBatchComplete: (() -> Void)? = nil
    ) {
        // Queue as single batch
        Task {
            await queueBatches(
                batches: [urls],
                basePath: basePath,
                headers: headers,
                maxConcurrentTasks: maxConcurrentTasks,
                retryCount: retryCount,
                timeoutSeconds: timeoutSeconds,
                onProgress: onProgress,
                onBatchComplete: onBatchComplete
            )
        }
    }

    // MARK: - Private Batch Processing

    private func startNextBatch() async {
        guard currentBatchIndex < batchQueue.count else {
            // All batches completed
            await handleAllBatchesComplete()
            return
        }

        let urls = batchQueue[currentBatchIndex]
        isProcessingBatch = true

        // Clear previous downloads if ready for new batch
        if await isReadyForNewBatch() {
            await clearCompletedDownloads()
        }

        // Set up tasks for current batch
        await setupBatchTasks(urls: urls)

        // Start batch processing
        batchTask = Task {
            await processBatch(urls: urls)
        }
    }

    private func setupBatchTasks(urls: [String]) async {
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
        guard let onProgress = currentOnProgress else { return }

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

                    // Get task from downloads map
                    guard let self = self,
                          let originalTask = await self.getDownloadTask(for: url) else {
                        taskSemaphore.signal()
                        return
                    }

                    do {
                        var task = originalTask

                        if task.url.lowercased().hasSuffix(".m3u8") {
                            try await self.hlsDownloader.downloadHlsStreamAdvanced(
                                task: task,
                                basePath: await self.getCurrentBasePath(),
                                onProgress: onProgress
                            )
                        } else {
                            try await self.httpsDownloader.downloadSingleFile(
                                task: task,
                                onProgress: onProgress
                            )
                        }

                        // Save updated task state
                        await self.updateDownloadTask(url: url, task: task)

                    } catch {
                        // Handle task failure
                        await self.handleTaskFailure(url: url, error: error, onProgress: onProgress)
                    }

                    taskSemaphore.signal()
                }
            }
        }

        // Send final batch progress
        await sendBatchProgress(onProgress: onProgress)

        // Handle batch completion
        await handleBatchComplete()
    }

    private func handleBatchComplete() async {
        isProcessingBatch = false
        currentBatchIndex += 1

        // Send batch completion status
        if let onProgress = currentOnProgress {
            await sendBatchCompletionStatus(onProgress: onProgress)
        }

        // Call batch completion callback
        onBatchComplete?()

        // Start next batch after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            await self.startNextBatch()
        }
    }

    private func handleAllBatchesComplete() async {
        isProcessingBatch = false

        // Send all batches completion status
        if let onProgress = currentOnProgress {
            await sendAllBatchesCompletionStatus(onProgress: onProgress)
        }

        // Call all batches completion callback
        onAllBatchesComplete?()

        // Clean up
        onBatchComplete = nil
        onAllBatchesComplete = nil
        currentOnProgress = nil
    }

    // MARK: - Helper Methods for Actor Safety

    private func getDownloadTask(for url: String) -> MTDownloadTask? {
        return downloads[url]
    }

    private func updateDownloadTask(url: String, task: MTDownloadTask) {
        downloads[url] = task
    }

    private func handleTaskFailure(url: String, error: Error, onProgress: ([String: Any]) -> Void) {
        downloads[url]?.status = .failed
        downloads[url]?.error = error.localizedDescription
        if let updatedTask = downloads[url] {
            ParallelDownloadManager.sendProgress(task: updatedTask, onProgress: onProgress)
        }
    }

    private func getCurrentBasePath() -> String {
        return currentBasePath
    }

    // MARK: - Status Methods

    func isBatchComplete() -> Bool {
        if downloads.isEmpty { return true }

        let allTasks = Array(downloads.values)
        let totalTasks = allTasks.count
        let completedTasks = allTasks.filter {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }.count

        return completedTasks >= totalTasks
    }

    func isReadyForNewBatch() -> Bool {
        let jobNotActive = batchTask?.isCancelled != false
        let noActiveDownloads = !downloads.values.contains {
            $0.status == .downloading || $0.status == .initializing
        }
        let downloadsEmpty = downloads.isEmpty

        return jobNotActive && (downloadsEmpty || (isBatchComplete() && noActiveDownloads))
    }

    func isBatchActive() -> Bool {
        let batchProcessing = isProcessingBatch
        let jobActive = batchTask?.isCancelled == false
        let hasActiveDownloads = downloads.values.contains {
            $0.status == .downloading || $0.status == .initializing
        }

        return jobActive && hasActiveDownloads && batchProcessing
    }

    func getAllBatchesStatus() -> [String: Any] {
        let totalBatches = batchQueue.count
        let currentIndex = currentBatchIndex
        let processing = isProcessingBatch

        return [
            "totalBatches": totalBatches,
            "currentBatchIndex": currentIndex,
            "completedBatches": currentIndex,
            "remainingBatches": max(0, totalBatches - currentIndex),
            "isProcessing": processing,
            "overallProgress": totalBatches > 0 ? Int(Double(currentIndex) * 100.0 / Double(totalBatches)) : 100
        ]
    }

    // MARK: - Control Methods

    func pauseDownload(url: String) -> Bool {
        guard let task = downloads[url] else { return false }

        if task.status == .downloading {
            downloads[url]?.status = .paused
            downloads[url]?.job?.cancel()
            return true
        }
        return false
    }

    func resumeDownload(url: String, onProgress: @escaping ([String: Any]) -> Void) {
        guard let originalTask = downloads[url] else { return }

        if originalTask.status == .paused {
            downloads[url]?.speedHistory.removeAll()

            downloads[url]?.job = Task { [weak self] in
                guard let self = self else { return }
                let task = originalTask

                do {
                    if task.url.lowercased().hasSuffix(".m3u8") {
                        let basePath = URL(fileURLWithPath: task.filePath).deletingLastPathComponent().path
                        try await self.hlsDownloader.downloadHlsStreamAdvanced(
                            task: task,
                            basePath: basePath,
                            onProgress: onProgress
                        )
                    } else {
                        try await self.httpsDownloader.downloadSingleFile(
                            task: task,
                            onProgress: onProgress
                        )
                    }

                    await self.updateDownloadTask(url: url, task: task)

                } catch {
                    await self.handleTaskFailure(url: url, error: error, onProgress: onProgress)
                }
            }
        }
    }

    func cancelDownload(url: String) -> Bool {
        guard let task = downloads[url] else { return false }

        downloads[url]?.status = .cancelled
        downloads[url]?.job?.cancel()
        try? FileManager.default.removeItem(atPath: task.filePath)
        downloads.removeValue(forKey: url)
        return true
    }

    func pauseAllDownloads() -> Bool {
        var hasActive = false
        for (url, task) in downloads {
            if task.status == .downloading {
                downloads[url]?.status = .paused
                downloads[url]?.job?.cancel()
                hasActive = true
            }
        }
        batchTask?.cancel()
        return hasActive
    }

    func cancelAllDownloads() -> Bool {
        if let task = batchTask {
                batchTask = nil
                task.cancel()
            }

        batchQueue.removeAll()
        currentBatchIndex = 0
        isProcessingBatch = false

        onBatchComplete = nil
        onAllBatchesComplete = nil
        currentOnProgress = nil

        for (_, task) in downloads {
            task.job?.cancel()
            try? FileManager.default.removeItem(atPath: task.filePath)
        }
        downloads.removeAll()

        return true
    }

    // MARK: - Progress and Status Methods

    func getDownloadStatus(url: String) -> [String: Any]? {
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

    func getBatchProgress() -> [String: Any]? {
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

        let tasksWithSpeed = allTasks.filter { !$0.speedHistory.isEmpty }
        let averageSpeed: Double
        if !tasksWithSpeed.isEmpty {
            let totalSpeed = tasksWithSpeed.map { $0.speedHistory.reduce(0, +) / Double($0.speedHistory.count) }.reduce(0, +)
            averageSpeed = totalSpeed / Double(tasksWithSpeed.count)
        } else {
            averageSpeed = 0.0
        }

        // Add batch queue info
        let batchStatus = getAllBatchesStatus()

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
            "averageSpeed": averageSpeed,
            "isComplete": isBatchComplete(),
            "isReadyForNewBatch": isReadyForNewBatch(),
            "batchStatus": batchStatus,
            "individualProgress": allTasks.map { task in
                [
                    "url": task.url,
                    "progress": task.totalBytes > 0 ? Int(Double(task.downloadedBytes) * 100.0 / Double(task.totalBytes)) : 0,
                    "status": task.status.rawValue,
                    "speed": !task.speedHistory.isEmpty ? task.speedHistory.reduce(0, +) / Double(task.speedHistory.count) : 0.0
                ]
            }
        ]
    }

    func clearCompletedDownloads() -> Bool {
        let completedUrls = downloads.compactMap { (key, value) in
            value.status == .completed ? key : nil
        }

        completedUrls.forEach { url in
            downloads.removeValue(forKey: url)
        }

        return true
    }

    // MARK: - Private Helper Methods

    private func extractFileName(url: String) -> String {
        if let uri = URL(string: url) {
            let path = uri.path
            let fileName = URL(fileURLWithPath: path).lastPathComponent

            if !fileName.isEmpty && fileName.contains(".") {
                print("THIS IS FILE NAME: \(fileName)")
                return fileName
            } else {
                print("download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp")
                return "download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp"
            }
        } else {
            print("download_1\(Int64(Date().timeIntervalSince1970 * 1000)).tmp")
            return "download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp"
        }
    }

    static func sendProgress(task: MTDownloadTask, onProgress: ([String: Any]) -> Void) {
        let currentTime = Date().timeIntervalSince1970 * 1000
        let timeElapsed = max(1.0, currentTime - task.startTime)

        let avgSpeed: Double
        if !task.speedHistory.isEmpty {
            avgSpeed = task.speedHistory.reduce(0, +) / Double(task.speedHistory.count)
        } else {
            avgSpeed = Double(task.downloadedBytes) * 1000.0 / timeElapsed
        }

        let progress = task.totalBytes > 0 ? Int(Double(task.downloadedBytes) * 100.0 / Double(task.totalBytes)) : -1

        // Check if download is actually complete (handle edge cases where progress shows 97-99%)
        let isComplete = (task.downloadedBytes >= task.totalBytes) ||
        (task.status == .completed || task.status == .pending) ||
                         (progress >= 97 && task.downloadedBytes > 0 && task.totalBytes > 0)

//        let status = isComplete ? MTDownloadStatus.completed.rawValue : task.status.rawValue


        if progress < 50 || isComplete {
            print("PROGRESS HAS BEEN SENT: \(progress)")

            // Set status to complete and progress to 100 if download is actually complete
            let finalProgress = isComplete ? 100 : progress
//            let status = isComplete

            onProgress([
                "url": task.url,
                "filePath": task.filePath,
                "progress": finalProgress,
                "bytesDownloaded": task.downloadedBytes,
                "totalBytes": task.totalBytes,
                "status": task.status.rawValue,
                "error": task.error ?? "",
                "speed": avgSpeed
            ])
        } else {
            print("Downlaading ...")
        }
        print("=====================")
    }

    private func sendBatchProgress(onProgress: ([String: Any]) -> Void) {
        if let batchProgress = getBatchProgress() {
            var progress = batchProgress
            progress["isBatchProgress"] = true
            onProgress(progress)
        }
    }

    private func sendBatchCompletionStatus(onProgress: ([String: Any]) -> Void) {
        if let batchProgress = getBatchProgress() {
            var progress = batchProgress
            progress["isBatchProgress"] = true
            progress["batchCompleted"] = true
            onProgress(progress)
        }
    }

    private func sendAllBatchesCompletionStatus(onProgress: ([String: Any]) -> Void) {
        let batchStatus = getAllBatchesStatus()

        let completionStatus: [String: Any] = [
            "isBatchProgress": true,
            "allBatchesCompleted": true,
            "batchStatus": batchStatus,
            "overallProgress": 100,
            "message": "All batches completed successfully"
        ]

        onProgress(completionStatus)
    }
}
