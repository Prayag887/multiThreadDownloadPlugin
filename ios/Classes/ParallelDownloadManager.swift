import Foundation


// MARK: - Download Task Model
@available(iOS 13.0, *)
class MTDownloadTask {
    let url: String
    var filePath: String
    let fileName: String
    let headers: [String: String]
    var status: MTDownloadStatus = .initializing
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var startTime: Double = Date().timeIntervalSince1970 * 1000
    var speedHistory: [Double] = []
    var error: String?
    var job: Task<Void, Error>?
    var retryCount: Int = 3
    var timeoutSeconds: Int = 30

    init(url: String, filePath: String, fileName: String, headers: [String: String] = [:]) {
        self.url = url
        self.filePath = filePath
        self.fileName = fileName
        self.headers = headers
    }
}

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

    private func sendProgress(task: MTDownloadTask, onProgress: ([String: Any]) -> Void) {
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
class ParallelDownloadManager {
    
    private var downloads: [String: MTDownloadTask] = [:]
    private let downloadsLock = NSLock()
    private var batchTask: Task<Void, Never>?
    
    // Add batch completion callback
    private var onBatchComplete: (() -> Void)?
    
    private let httpsDownloader = HttpsDownloader()
    private let hlsDownloader = HighPerformanceHlsDownloader()
    
    func startBatchDownload(
        urls: [String],
        basePath: String,
        headers: [String: String],
        maxConcurrentTasks: Int,
        retryCount: Int,
        timeoutSeconds: Int,
        onProgress: @escaping ([String: Any]) -> Void,
        onBatchComplete: (() -> Void)? = nil
    ) {
        // Cancel any existing batch
        batchTask?.cancel()
        
        // Clear previous downloads if batch is complete or no active downloads
        if isReadyForNewBatch() {
            clearCompletedDownloads()
        }
        
        // Store the batch completion callback
        self.onBatchComplete = onBatchComplete
        
        urls.forEach { url in
            let fileName = extractFileName(url: url)
            
            // Clean and turn it into a folder name
            let folderName = fileName
                .replacingOccurrences(of: ".m3u8", with: "")
                .replacingOccurrences(of: "/", with: "_")
            
            let safeFolderName = folderName.isEmpty ? "download" : folderName
            let downloadDir = URL(fileURLWithPath: basePath).appendingPathComponent(safeFolderName).path
            
            // Ensure the directory exists
            try? FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true, attributes: nil)
            
            // Set up the task
            var task = MTDownloadTask(
                url: url,
                filePath: downloadDir,
                fileName: fileName,
                headers: headers
            )
            
            task.retryCount = retryCount
            task.timeoutSeconds = timeoutSeconds
            
            downloadsLock.lock()
            downloads[url] = task
            downloadsLock.unlock()
        }
        
        batchTask = Task {
            // Create semaphore for concurrent task control
            let taskSemaphore = DispatchSemaphore(value: maxConcurrentTasks)
            
            // Map urls to async tasks
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { [weak self] in
                        await withCheckedContinuation { continuation in
                            taskSemaphore.wait()
                            continuation.resume()
                        }
                        
                        // Get task from downloads map
                        self?.downloadsLock.lock()
                        guard let originalTask = self?.downloads[url] else {
                            self?.downloadsLock.unlock()
                            taskSemaphore.signal()
                            return
                        }
                        self?.downloadsLock.unlock()
                        
                        do {
                            var task = originalTask
                            
                            if task.url.lowercased().hasSuffix(".m3u8") {
                                try await self?.hlsDownloader.downloadHlsStreamAdvanced(task: task, basePath: basePath, onProgress: onProgress)
                            } else {
                                try await self?.httpsDownloader.downloadSingleFile(task: task, onProgress: onProgress)
                            }
                            
                            // Optional: Save updated task state back if needed
                            self?.downloads[url] = task
                        } catch {
                            // Modify task directly in dictionary
                            self?.downloadsLock.lock()
                            self?.downloads[url]?.status = .failed
                            self?.downloads[url]?.error = error.localizedDescription
                            if let updatedTask = self?.downloads[url] {
                                self?.downloadsLock.unlock()
                                self?.sendProgress(task: updatedTask, onProgress: onProgress)
                            } else {
                                self?.downloadsLock.unlock()
                            }
                        }
                        
                        taskSemaphore.signal()
                    }
                }
            }
            
            sendBatchProgress(onProgress: onProgress)
            
            // Notify batch completion
            self.onBatchComplete?()
            self.onBatchComplete = nil
        }
    }
    
    // MARK: - Status Methods
    func isBatchComplete() -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
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
        
        downloadsLock.lock()
        let noActiveDownloads = downloads.values.allSatisfy {
            $0.status != .downloading && $0.status != .initializing
        }
        let downloadsEmpty = downloads.isEmpty
        downloadsLock.unlock()
        
        return jobNotActive && (downloadsEmpty || (isBatchComplete() && noActiveDownloads))
    }
    
    func isBatchActive() -> Bool {
        let jobActive = batchTask?.isCancelled == false
        
        downloadsLock.lock()
        let hasActiveDownloads = downloads.values.contains {
            $0.status == .downloading || $0.status == .initializing
        }
        downloadsLock.unlock()
        
        return jobActive && hasActiveDownloads
    }
    
    // MARK: - Control Methods
    func pauseDownload(url: String) -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
        guard let task = downloads[url] else { return false }
        
        if task.status == .downloading {
            downloads[url]?.status = .paused
            downloads[url]?.job?.cancel()
            return true
        }
        return false
    }
    
    func resumeDownload(url: String, onProgress: @escaping ([String: Any]) -> Void) {
        downloadsLock.lock()
        guard let originalTask = downloads[url] else {
            downloadsLock.unlock()
            return
        }
        downloadsLock.unlock()
        
        if originalTask.status == .paused {
            downloadsLock.lock()
            downloads[url]?.speedHistory.removeAll()
            
            downloads[url]?.job = Task { [weak self] in
                var task = originalTask
                
                do {
                    if task.url.lowercased().hasSuffix(".m3u8") {
                        let basePath = URL(fileURLWithPath: task.filePath).deletingLastPathComponent().path
                        try await self?.hlsDownloader.downloadHlsStreamAdvanced(
                            task: task,
                            basePath: basePath,
                            onProgress: onProgress
                        )
                    } else {
                        try await self?.httpsDownloader.downloadSingleFile(
                            task: task,
                            onProgress: onProgress
                        )
                    }
                    
                    self?.downloadsLock.lock()
                    self?.downloads[url] = task
                    self?.downloadsLock.unlock()
                    
                } catch {
                    self?.downloadsLock.lock()
                    self?.downloads[url]?.status = .failed
                    self?.downloads[url]?.error = error.localizedDescription
                    
                    if let updatedTask = self?.downloads[url] {
                        self?.downloadsLock.unlock()
                        self?.sendProgress(task: updatedTask, onProgress: onProgress)
                    } else {
                        self?.downloadsLock.unlock()
                    }
                }
            }
            
            downloadsLock.unlock()
        }
    }
    
    func cancelDownload(url: String) -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
        guard let task = downloads[url] else { return false }
        
        downloads[url]?.status = .cancelled
        downloads[url]?.job?.cancel()
        try? FileManager.default.removeItem(atPath: task.filePath)
        downloads.removeValue(forKey: url)
        return true
    }
    
    func pauseAllDownloads() -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
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
        batchTask?.cancel()
        onBatchComplete = nil
        
        downloadsLock.lock()
        for (_, task) in downloads {
            task.job?.cancel()
            try? FileManager.default.removeItem(atPath: task.filePath)
        }
        downloads.removeAll()
        downloadsLock.unlock()
        
        return true
    }
    
    // MARK: - Progress and Status Methods
    func getDownloadStatus(url: String) -> [String: Any]? {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
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
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
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
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
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
        do {
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
        } catch {
            return "download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp"
        }
    }

    private func sendProgress(task: MTDownloadTask, onProgress: ([String: Any]) -> Void) {
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

    private func sendBatchProgress(onProgress: ([String: Any]) -> Void) {
        if let batchProgress = getBatchProgress() {
            var progress = batchProgress
            progress["isBatchProgress"] = true
            onProgress(progress)
        }
    }
}

// MARK: - Example Usage
@available(iOS 15.0, *)
class ExampleUsage {
    private let downloadManager = ParallelDownloadManager()

    func startExampleDownload() {
        let urls = [
            "https://example.com/file1.mp4",
            "https://example.com/file2.pdf",
            "https://example.com/stream.m3u8"
        ]

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path

        downloadManager.startBatchDownload(
            urls: urls,
            basePath: documentsPath,
            headers: ["User-Agent": "MyApp/1.0"],
            maxConcurrentTasks: 3,
            retryCount: 3,
            timeoutSeconds: 30,
            onProgress: { progress in
                if let isBatchProgress = progress["isBatchProgress"] as? Bool, isBatchProgress {
                    print("Batch Progress: \(progress["overallProgress"] ?? 0)%")
                } else {
                    print("File Progress: \(progress["url"] ?? "") - \(progress["progress"] ?? 0)%")
                }
            },
            onBatchComplete: {
                print("All downloads completed!")
            }
        )
    }
}
