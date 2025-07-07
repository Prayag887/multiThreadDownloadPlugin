import Foundation
import AVFoundation

// MARK: - Download Status Enum
enum DownloadStatus: String, CaseIterable {
    case initializing = "initializing"
    case downloading = "downloading"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

// MARK: - Download Task Class
class DownloadTask {
    let url: String
    let filePath: String
    let fileName: String
    let headers: [String: String]
    let retryCount: Int
    let timeoutSeconds: Int

    var status: DownloadStatus = .initializing
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var error: String?
    var speedHistory: [Double] = []
    var startTime: Date = Date()
    var task: URLSessionTask?

    init(url: String, filePath: String, fileName: String, headers: [String: String], retryCount: Int, timeoutSeconds: Int) {
        self.url = url
        self.filePath = filePath
        self.fileName = fileName
        self.headers = headers
        self.retryCount = retryCount
        self.timeoutSeconds = timeoutSeconds
        self.startTime = Date()
    }
}

// MARK: - Parallel Download Manager
class ParallelDownloadManager {
    private var downloads: [String: DownloadTask] = [:]
    private let downloadsLock = NSLock()
    private var batchTask: Task<Void, Never>?
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

        // Initialize download tasks
        for url in urls {
            let fileName = extractFileName(from: url)
            let fullPath = URL(fileURLWithPath: basePath).appendingPathComponent(fileName).path
            let task = DownloadTask(
                url: url,
                filePath: fullPath,
                fileName: fileName,
                headers: headers,
                retryCount: retryCount,
                timeoutSeconds: timeoutSeconds
            )

            downloadsLock.lock()
            downloads[url] = task
            downloadsLock.unlock()
        }

        batchTask = Task {
            await withTaskGroup(of: Void.self) { group in
                let semaphore = AsyncSemaphore(value: maxConcurrentTasks)

                for url in urls {
                    group.addTask {
                        await semaphore.wait()
                        defer { semaphore.signal() }

                        guard let task = self.getDownloadTask(for: url) else { return }

                        do {
                            if url.lowercased().hasSuffix(".m3u8") {
                                await self.hlsDownloader.downloadHlsStreamAdvanced(
                                    task: task,
                                    basePath: basePath,
                                    onProgress: onProgress
                                )
                            } else {
                                await self.httpsDownloader.downloadSingleFile(
                                    task: task,
                                    onProgress: onProgress
                                )
                            }
                        } catch {
                            self.downloadsLock.lock()
                            task.status = .failed
                            task.error = error.localizedDescription
                            self.downloadsLock.unlock()
                            self.sendProgress(for: task, onProgress: onProgress)
                        }
                    }
                }
            }

            self.sendBatchProgress(onProgress: onProgress)

            // Notify batch completion
            await MainActor.run {
                self.onBatchComplete?()
                self.onBatchComplete = nil
            }
        }
    }

    private func getDownloadTask(for url: String) -> DownloadTask? {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }
        return downloads[url]
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

    // Check if ready for new batch
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

    private func extractFileName(from url: String) -> String {
        guard let urlComponents = URLComponents(string: url),
              let path = urlComponents.path.components(separatedBy: "/").last,
              !path.isEmpty,
              path.contains(".") else {
            return "download_\(Int(Date().timeIntervalSince1970 * 1000)).tmp"
        }
        return path
    }

    private func sendProgress(for task: DownloadTask, onProgress: @escaping ([String: Any]) -> Void) {
        let currentTime = Date()
        let timeElapsed = max(1.0, currentTime.timeIntervalSince(task.startTime))

        let avgSpeed = if !task.speedHistory.isEmpty {
            task.speedHistory.reduce(0, +) / Double(task.speedHistory.count)
        } else {
            Double(task.downloadedBytes) / timeElapsed
        }

        let progress = task.totalBytes > 0 ? Int((Double(task.downloadedBytes) * 100.0) / Double(task.totalBytes)) : -1

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

        DispatchQueue.main.async {
            onProgress(progressData)
        }
    }

    private func sendBatchProgress(onProgress: @escaping ([String: Any]) -> Void) {
        if let batchProgress = getBatchProgress() {
            var progressWithFlag = batchProgress
            progressWithFlag["isBatchProgress"] = true
            DispatchQueue.main.async {
                onProgress(progressWithFlag)
            }
        }
    }

    // MARK: - Public Methods

    func pauseDownload(_ url: String) -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }

        guard let task = downloads[url], task.status == .downloading else {
            return false
        }

        task.status = .paused
        task.task?.cancel()
        return true
    }

    func resumeDownload(_ url: String, onProgress: @escaping ([String: Any]) -> Void) {
        guard let task = getDownloadTask(for: url), task.status == .paused else {
            return
        }

        task.speedHistory.removeAll()

        Task {
            do {
                if url.lowercased().hasSuffix(".m3u8") {
                    let basePath = URL(fileURLWithPath: task.filePath).deletingLastPathComponent().path
                    await hlsDownloader.downloadHlsStreamAdvanced(
                        task: task,
                        basePath: basePath,
                        onProgress: onProgress
                    )
                } else {
                    await httpsDownloader.downloadSingleFile(
                        task: task,
                        onProgress: onProgress
                    )
                }
            } catch {
                downloadsLock.lock()
                task.status = .failed
                task.error = error.localizedDescription
                downloadsLock.unlock()
                sendProgress(for: task, onProgress: onProgress)
            }
        }
    }

    func cancelDownload(_ url: String) -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }

        guard let task = downloads[url] else { return false }

        task.status = .cancelled
        task.task?.cancel()

        // Delete file
        try? FileManager.default.removeItem(atPath: task.filePath)
        downloads.removeValue(forKey: url)

        return true
    }

    func pauseAllDownloads() -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }

        var hasActive = false
        for task in downloads.values {
            if task.status == .downloading {
                task.status = .paused
                task.task?.cancel()
                hasActive = true
            }
        }

        batchTask?.cancel()
        return hasActive
    }

    func resumeAllDownloads(onProgress: @escaping ([String: Any]) -> Void) {
        let pausedTasks = downloads.values.filter { $0.status == .paused }

        for task in pausedTasks {
            task.speedHistory.removeAll()

            Task {
                do {
                    if task.url.lowercased().hasSuffix(".m3u8") {
                        let basePath = URL(fileURLWithPath: task.filePath).deletingLastPathComponent().path
                        await hlsDownloader.downloadHlsStreamAdvanced(
                            task: task,
                            basePath: basePath,
                            onProgress: onProgress
                        )
                    } else {
                        await httpsDownloader.downloadSingleFile(
                            task: task,
                            onProgress: onProgress
                        )
                    }
                } catch {
                    downloadsLock.lock()
                    task.status = .failed
                    task.error = error.localizedDescription
                    downloadsLock.unlock()
                    sendProgress(for: task, onProgress: onProgress)
                }
            }
        }
    }

    func cancelAllDownloads() -> Bool {
        batchTask?.cancel()
        onBatchComplete = nil

        downloadsLock.lock()
        defer { downloadsLock.unlock() }

        for task in downloads.values {
            task.status = .cancelled
            task.task?.cancel()
            try? FileManager.default.removeItem(atPath: task.filePath)
        }

        downloads.removeAll()
        return true
    }

    func pauseDownloads(_ urls: [String]) -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }

        var hasActive = false
        for url in urls {
            if let task = downloads[url], task.status == .downloading {
                task.status = .paused
                task.task?.cancel()
                hasActive = true
            }
        }
        return hasActive
    }

    func resumeDownloads(_ urls: [String], onProgress: @escaping ([String: Any]) -> Void) {
        for url in urls {
            guard let task = getDownloadTask(for: url), task.status == .paused else {
                continue
            }

            task.speedHistory.removeAll()

            Task {
                do {
                    if url.lowercased().hasSuffix(".m3u8") {
                        let basePath = URL(fileURLWithPath: task.filePath).deletingLastPathComponent().path
                        await hlsDownloader.downloadHlsStreamAdvanced(
                            task: task,
                            basePath: basePath,
                            onProgress: onProgress
                        )
                    } else {
                        await httpsDownloader.downloadSingleFile(
                            task: task,
                            onProgress: onProgress
                        )
                    }
                } catch {
                    downloadsLock.lock()
                    task.status = .failed
                    task.error = error.localizedDescription
                    downloadsLock.unlock()
                    sendProgress(for: task, onProgress: onProgress)
                }
            }
        }
    }

    func cancelDownloads(_ urls: [String]) -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }

        var hasActive = false
        for url in urls {
            if let task = downloads[url] {
                task.status = .cancelled
                task.task?.cancel()
                try? FileManager.default.removeItem(atPath: task.filePath)
                downloads.removeValue(forKey: url)
                hasActive = true
            }
        }
        return hasActive
    }

    func getDownloadStatus(_ url: String) -> [String: Any]? {
        guard let task = getDownloadTask(for: url) else { return nil }

        let currentTime = Date()
        let timeElapsed = max(1.0, currentTime.timeIntervalSince(task.startTime))
        let avgSpeed = if !task.speedHistory.isEmpty {
            task.speedHistory.reduce(0, +) / Double(task.speedHistory.count)
        } else {
            Double(task.downloadedBytes) / timeElapsed
        }

        let progress = task.totalBytes > 0 ? Int((Double(task.downloadedBytes) * 100.0) / Double(task.totalBytes)) : 0

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

    func getDownloadStatuses(_ urls: [String]) -> [[String: Any]] {
        return urls.compactMap { getDownloadStatus($0) }
    }

    func getBatchProgress() -> [String: Any]? {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }

        guard !downloads.isEmpty else { return nil }

        let allTasks = Array(downloads.values)
        let totalBytes = allTasks.reduce(0) { $0 + $1.totalBytes }
        let downloadedBytes = allTasks.reduce(0) { $0 + $1.downloadedBytes }
        let completedCount = allTasks.filter { $0.status == .completed }.count
        let failedCount = allTasks.filter { $0.status == .failed }.count
        let cancelledCount = allTasks.filter { $0.status == .cancelled }.count
        let activeCount = allTasks.filter { $0.status == .downloading }.count
        let pausedCount = allTasks.filter { $0.status == .paused }.count

        let overallProgress = totalBytes > 0 ? Int((Double(downloadedBytes) * 100.0) / Double(totalBytes)) : 0

        let averageSpeed = allTasks
            .filter { !$0.speedHistory.isEmpty }
            .map { $0.speedHistory.reduce(0, +) / Double($0.speedHistory.count) }
            .reduce(0, +) / Double(max(1, allTasks.count))

        let individualProgress = allTasks.map { task in
            [
                "url": task.url,
                "progress": task.totalBytes > 0 ? Int((Double(task.downloadedBytes) * 100.0) / Double(task.totalBytes)) : 0,
                "status": task.status.rawValue,
                "speed": !task.speedHistory.isEmpty ? task.speedHistory.reduce(0, +) / Double(task.speedHistory.count) : 0.0
            ] as [String: Any]
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
            "individualProgress": individualProgress
        ]
    }

    func getAllDownloads() -> [[String: Any]] {
        return Array(downloads.keys).compactMap { getDownloadStatus($0) }
    }

    func clearCompletedDownloads() -> Bool {
        downloadsLock.lock()
        defer { downloadsLock.unlock() }

        downloads = downloads.filter { $0.value.status != .completed }
        return true
    }
}

// MARK: - AsyncSemaphore
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
}

// MARK: - HttpsDownloader
class HttpsDownloader {
    private var urlSession: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    func downloadSingleFile(task: DownloadTask, onProgress: @escaping ([String: Any]) -> Void) async throws {
        guard let url = URL(string: task.url) else {
            throw NSError(domain: "InvalidURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(task.timeoutSeconds)

        for (key, value) in task.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        task.status = .downloading
        task.startTime = Date()

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            task.totalBytes = Int64(httpResponse.expectedContentLength)
        }

        task.downloadedBytes = Int64(data.count)

        // Save file
        let fileURL = URL(fileURLWithPath: task.filePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)

        task.status = .completed

        // Send final progress
        let progressData: [String: Any] = [
            "url": task.url,
            "filePath": task.filePath,
            "progress": 100,
            "bytesDownloaded": task.downloadedBytes,
            "totalBytes": task.totalBytes,
            "status": task.status.rawValue,
            "error": "",
            "speed": 0.0
        ]

        DispatchQueue.main.async {
            onProgress(progressData)
        }
    }
}

// MARK: - HighPerformanceHlsDownloader
class HighPerformanceHlsDownloader {
    private var urlSession: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    func downloadHlsStreamAdvanced(task: DownloadTask, basePath: String, onProgress: @escaping ([String: Any]) -> Void) async {
        do {
            guard let url = URL(string: task.url) else {
                throw NSError(domain: "InvalidURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HLS URL"])
            }

            task.status = .downloading
            task.startTime = Date()

            // For HLS streams, we'll use AVAssetExportSession to download
            let asset = AVURLAsset(url: url)

            // Create export session
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                throw NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
            }

            let outputURL = URL(fileURLWithPath: task.filePath)

            // Create directory if needed
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4

            await withCheckedContinuation { continuation in
                exportSession.exportAsynchronously {
                    continuation.resume()
                }
            }

            switch exportSession.status {
            case .completed:
                task.status = .completed
                if let fileAttributes = try? FileManager.default.attributesOfItem(atPath: task.filePath),
                   let fileSize = fileAttributes[.size] as? Int64 {
                    task.totalBytes = fileSize
                    task.downloadedBytes = fileSize
                }

            case .failed:
                task.status = .failed
                task.error = exportSession.error?.localizedDescription ?? "Export failed"

            case .cancelled:
                task.status = .cancelled

            default:
                task.status = .failed
                task.error = "Unknown export status"
            }

            // Send final progress
            let progressData: [String: Any] = [
                "url": task.url,
                "filePath": task.filePath,
                "progress": task.status == .completed ? 100 : 0,
                "bytesDownloaded": task.downloadedBytes,
                "totalBytes": task.totalBytes,
                "status": task.status.rawValue,
                "error": task.error ?? "",
                "speed": 0.0
            ]

            DispatchQueue.main.async {
                onProgress(progressData)
            }

        } catch {
            task.status = .failed
            task.error = error.localizedDescription

            let progressData: [String: Any] = [
                "url": task.url,
                "filePath": task.filePath,
                "progress": 0,
                "bytesDownloaded": 0,
                "totalBytes": 0,
                "status": task.status.rawValue,
                "error": task.error ?? "",
                "speed": 0.0
            ]

            DispatchQueue.main.async {
                onProgress(progressData)
            }
        }
    }
}