import Foundation

@available(iOS 15.0, *)
class ParallelDownloadManager {
    
    private var downloads: [String: MTDownloadTask] = [:]
    private let downloadsLock = NSLock()
    private var batchTask: Task<Void, Never>?
    
    // Add batch completion callback
    private var onBatchComplete: (() -> Void)?
    
    private let httpsDownloader = HttpsDownloader()
    private let hlsDownloader = HighPerformanceHlsDownloader()
    
    @available(iOS 15.0, *)
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
            let fullPath = URL(fileURLWithPath: basePath).appendingPathComponent(fileName).path
            var task = MTDownloadTask(url: url, filePath: fullPath, fileName: fileName, headers: headers)
            task.filePath = fullPath
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
    
    // Check if batch is complete
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
    
    // This function is now being used properly
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
    
    // Check if batch is actively downloading
    func isBatchActive() -> Bool {
        let jobActive = batchTask?.isCancelled == false
        
        downloadsLock.lock()
        let hasActiveDownloads = downloads.values.contains {
            $0.status == .downloading || $0.status == .initializing
        }
        downloadsLock.unlock()
        
        return jobActive && hasActiveDownloads
    }
    
    private func extractFileName(url: String) -> String {
        do {
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
    
    // Rest of the methods remain the same...
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
    
    func resumeAllDownloads(onProgress: @escaping ([String: Any]) -> Void) {
        downloadsLock.lock()
        let pausedUrls = downloads.compactMap { (url, task) in
            task.status == .paused ? url : nil
        }
        downloadsLock.unlock()
        
        if !pausedUrls.isEmpty {
            for url in pausedUrls {
                downloadsLock.lock()
                guard let originalTask = downloads[url] else {
                    downloadsLock.unlock()
                    continue
                }

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
    
    func pauseDownloads(urls: [String]) -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
        var hasActive = false
        for url in urls {
            if let task = downloads[url] {
                if task.status == .downloading {
                    downloads[url]?.status = .paused
                    downloads[url]?.job?.cancel()
                    hasActive = true
                }
            }
        }
        return hasActive
    }
    
    func resumeDownloads(urls: [String], onProgress: @escaping ([String: Any]) -> Void) {
        for url in urls {
            downloadsLock.lock()
            guard let originalTask = downloads[url] else {
                downloadsLock.unlock()
                continue
            }

            if originalTask.status == .paused {
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
            }
            downloadsLock.unlock()
        }
    }
    
    func cancelDownloads(urls: [String]) -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        
        var hasActive = false
        for url in urls {
            if let task = downloads[url] {
                downloads[url]?.status = .cancelled
                downloads[url]?.job?.cancel()
                try? FileManager.default.removeItem(atPath: task.filePath)
                downloads.removeValue(forKey: url)
                hasActive = true
            }
        }
        return hasActive
    }
    
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
    
    func getDownloadStatuses(urls: [String]) -> [[String: Any]] {
        return urls.compactMap { getDownloadStatus(url: $0) }
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
    
    func getAllDownloads() -> [[String: Any]] {
        downloadsLock.lock()
        let urls = Array(downloads.keys)
        downloadsLock.unlock()
        
        return urls.compactMap { getDownloadStatus(url: $0) }
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
}
