import Flutter
import UIKit

@available(iOS 15.0, *)
public class MultithreadDownloadsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    private var channel: FlutterMethodChannel!
    private var eventChannel: FlutterEventChannel!
    private var eventSink: FlutterEventSink?
    private let downloadManager = ParallelDownloadManager()
    
    private let queueAccessQueue = DispatchQueue(label: "download.queue.access", qos: .utility)
    private var downloadQueue: [DownloadRequest] = []
    private var isProcessingQueue = false
    
    struct DownloadRequest {
        let urls: [String]
        let filePath: String
        let fileName: String
        let headers: [String: String]
        let maxConcurrentTasks: Int
        let retryCount: Int
        let timeoutSeconds: Int
        let requestId: String
        
        init(urls: [String], filePath: String, fileName: String, headers: [String: String],
             maxConcurrentTasks: Int, retryCount: Int, timeoutSeconds: Int) {
            self.urls = urls
            self.filePath = filePath
            self.fileName = fileName
            self.headers = headers
            self.maxConcurrentTasks = maxConcurrentTasks
            self.retryCount = retryCount
            self.timeoutSeconds = timeoutSeconds
            self.requestId = UUID().uuidString
        }
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
            
        // ✅ NEW: HLS Queue Methods
        case "queueHlsDownloads":
            handleQueueHlsDownloads(call: call, result: result)

        case "queueSingleHlsDownload":
            handleQueueSingleHlsDownload(call: call, result: result)

        case "getHlsQueueStatus":
            handleGetHlsQueueStatus(result: result)

        case "pauseHlsQueue":
            handlePauseHlsQueue(result: result)

        case "resumeHlsQueue":
            handleResumeHlsQueue(result: result)

        case "cancelHlsQueue":
            handleCancelHlsQueue(result: result)

        // Existing methods
        case "pauseDownload":
            guard let url = call.arguments as? [String: Any],
                  let urlString = url["url"] as? String else {
                result(false)
                return
            }
            handlePauseDownload(url: urlString, result: result)

        case "resumeDownload":
            guard let url = call.arguments as? [String: Any],
                  let urlString = url["url"] as? String else {
                result(false)
                return
            }
            handleResumeDownload(url: urlString, result: result)

        case "cancelDownload":
            guard let url = call.arguments as? [String: Any],
                  let urlString = url["url"] as? String else {
                result(false)
                return
            }
            handleCancelDownload(url: urlString, result: result)

        case "pauseAllDownloads":
            handlePauseAllDownloads(result: result)

        case "cancelAllDownloads":
            handleCancelAllDownloads(result: result)

        case "getDownloadStatus":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(nil)
                return
            }
            handleGetDownloadStatus(url: url, result: result)

        case "getBatchProgress":
            handleGetBatchProgress(result: result)

        case "clearCompletedDownloads":
            handleClearCompletedDownloads(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - ✅ NEW: HLS Queue Handler Methods

    private func handleQueueHlsDownloads(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(["success": false, "error": "Invalid arguments"])
            return
        }

        let urls = args["urls"] as? [String] ?? []
        guard let basePath = args["basePath"] as? String else {
            result(["success": false, "error": "Missing basePath"])
            return
        }

        let headers = args["headers"] as? [String: String] ?? [:]
        let priority = args["priority"] as? Int ?? 0

        Task {
            let queueIds = await downloadManager.queueHlsDownloads(
                urls: urls,
                basePath: basePath,
                headers: headers,
                onProgress: { [weak self] progress in
                    self?.sendProgress(progress: progress)
                },
                priority: priority
            )

            await MainActor.run {
                result([
                    "success": true,
                    "queueIds": queueIds,
                    "count": queueIds.count
                ])
            }
        }
    }

    private func handleQueueSingleHlsDownload(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(["success": false, "error": "Invalid arguments"])
            return
        }

        guard let url = args["url"] as? String,
              let basePath = args["basePath"] as? String else {
            result(["success": false, "error": "Missing url or basePath"])
            return
        }

        let headers = args["headers"] as? [String: String] ?? [:]
        let priority = args["priority"] as? Int ?? 0

        Task {
            let queueId = await downloadManager.queueSingleHlsDownload(
                url: url,
                basePath: basePath,
                headers: headers,
                onProgress: { [weak self] progress in
                    self?.sendProgress(progress: progress)
                },
                priority: priority
            )

            await MainActor.run {
                if let queueId = queueId {
                    result([
                        "success": true,
                        "queueId": queueId
                    ])
                } else {
                    result([
                        "success": false,
                        "error": "Failed to queue HLS download - URL is not an HLS stream"
                    ])
                }
            }
        }
    }

    private func handleGetHlsQueueStatus(result: @escaping FlutterResult) {
        Task {
            let status = await downloadManager.getHlsQueueStatus()
            await MainActor.run {
                result(status)
            }
        }
    }

    private func handlePauseHlsQueue(result: @escaping FlutterResult) {
        Task {
            await downloadManager.pauseHlsQueue()
            await MainActor.run {
                result(true)
            }
        }
    }

    private func handleResumeHlsQueue(result: @escaping FlutterResult) {
        Task {
            await downloadManager.resumeHlsQueue()
            await MainActor.run {
                result(true)
            }
        }
    }

    private func handleCancelHlsQueue(result: @escaping FlutterResult) {
        Task {
            await downloadManager.cancelHlsQueue()
            await MainActor.run {
                result(true)
            }
        }
    }

    // MARK: - Existing Async Handler Methods (unchanged)

    private func handlePauseDownload(url: String, result: @escaping FlutterResult) {
        Task {
            let success = await downloadManager.pauseDownload(url: url)
            await MainActor.run {
                result(success)
            }
        }
    }

    private func handleResumeDownload(url: String, result: @escaping FlutterResult) {
        Task {
            await downloadManager.resumeDownload(url: url) { [weak self] progress in
                self?.sendProgress(progress: progress)
            }
            await MainActor.run {
                result(true)
            }
        }
    }

    private func handleCancelDownload(url: String, result: @escaping FlutterResult) {
        Task {
            let success = await downloadManager.cancelDownload(url: url)
            await MainActor.run {
                result(success)
            }
        }
    }

    private func handlePauseAllDownloads(result: @escaping FlutterResult) {
        Task {
            let success = await downloadManager.pauseAllDownloads()
            // ✅ ENHANCED: Also pause HLS queue
            await downloadManager.pauseHlsQueue()
            await MainActor.run {
                result(success)
            }
        }
    }

    private func handleCancelAllDownloads(result: @escaping FlutterResult) {
        Task {
            let cancelled = await downloadManager.cancelAllDownloads()
            // ✅ ENHANCED: Also cancel HLS queue
            await downloadManager.cancelHlsQueue()

            queueAccessQueue.sync {
                downloadQueue.removeAll()
                isProcessingQueue = false
            }

            await MainActor.run {
                result(cancelled)
            }
        }
    }

    private func handleGetDownloadStatus(url: String, result: @escaping FlutterResult) {
        Task {
            let status = await downloadManager.getDownloadStatus(url: url)
            await MainActor.run {
                result(status)
            }
        }
    }

    private func handleGetBatchProgress(result: @escaping FlutterResult) {
        Task {
            let progress = await downloadManager.getBatchProgress()
            await MainActor.run {
                result(progress)
            }
        }
    }

    private func handleClearCompletedDownloads(result: @escaping FlutterResult) {
        Task {
            let success = await downloadManager.clearCompletedDownloads()
            await MainActor.run {
                result(success)
            }
        }
    }

    // ✅ ENHANCED: Smart Download Detection
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

        let fileName = args["fileName"] as? String ?? ""
        let headers = args["headers"] as? [String: String] ?? [:]
        let maxConcurrentTasks = args["maxConcurrentTasks"] as? Int ?? 4
        let retryCount = args["retryCount"] as? Int ?? 3
        let timeoutSeconds = args["timeoutSeconds"] as? Int ?? 30
        let priority = args["priority"] as? Int ?? 0

        // ✅ SMART DETECTION: Separate HLS and regular downloads
        let hlsUrls = urls.filter { $0.lowercased().hasSuffix(".m3u8") }
        let regularUrls = urls.filter { !$0.lowercased().hasSuffix(".m3u8") }

        Task {
            var hlsQueueIds: [String] = []
            var regularDownloadSuccess = true

            // Handle HLS downloads with queue
            if !hlsUrls.isEmpty {
                hlsQueueIds = await downloadManager.queueHlsDownloads(
                    urls: hlsUrls,
                    basePath: filePath,
                    headers: headers,
                    onProgress: { [weak self] progress in
                        self?.sendProgress(progress: progress)
                    },
                    priority: priority
                )
                print("🎬 Queued \(hlsUrls.count) HLS downloads with IDs: \(hlsQueueIds)")
            }

            // Handle regular downloads with existing batch system
            if !regularUrls.isEmpty {
                let downloadRequest = DownloadRequest(
                    urls: regularUrls,
                    filePath: filePath,
                    fileName: fileName,
                    headers: headers,
                    maxConcurrentTasks: maxConcurrentTasks,
                    retryCount: retryCount,
                    timeoutSeconds: timeoutSeconds
                )

                self.queueAccessQueue.sync {
                    self.downloadQueue.append(downloadRequest)
                }

                self.processDownloadQueue()
                print("📁 Queued \(regularUrls.count) regular downloads")
            }

            await MainActor.run {
                result([
                    "success": true,
                    "hlsCount": hlsUrls.count,
                    "regularCount": regularUrls.count,
                    "hlsQueueIds": hlsQueueIds,
                    "message": "Queued \(hlsUrls.count) HLS and \(regularUrls.count) regular downloads"
                ])
            }
        }
    }

    private func processDownloadQueue() {
        Task {
            let shouldProcess = queueAccessQueue.sync {
                if isProcessingQueue || downloadQueue.isEmpty {
                    return false
                }

                isProcessingQueue = true
                return true
            }

            guard shouldProcess else { return }

            // Check if download manager is ready for new batch
            let isReady = await downloadManager.isReadyForNewBatch()

            if !isReady {
                queueAccessQueue.sync {
                    isProcessingQueue = false
                }
                return
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

            await downloadManager.startBatchDownload(
                urls: request.urls,
                basePath: request.filePath,
                headers: request.headers,
                maxConcurrentTasks: request.maxConcurrentTasks,
                retryCount: request.retryCount,
                timeoutSeconds: request.timeoutSeconds,
                onProgress: { [weak self] progress in
                    self?.sendProgress(progress: progress)
                },
                onBatchComplete: { [weak self] in
                    guard let self = self else { return }

                    self.queueAccessQueue.sync {
                        self.isProcessingQueue = false
                    }

                    self.processDownloadQueue()
                }
            )
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // ✅ ENHANCED: Better progress handling with HLS queue info
    private func sendProgress(progress: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            // Add timestamp and additional metadata
            var enhancedProgress = progress
            enhancedProgress["timestamp"] = Date().timeIntervalSince1970

            // Determine download type
            if let queueId = progress["queueId"] as? String {
                enhancedProgress["downloadType"] = "hls_queue"
            } else if let isBatchProgress = progress["isBatchProgress"] as? Bool, isBatchProgress {
                enhancedProgress["downloadType"] = "batch"
            } else {
                enhancedProgress["downloadType"] = "regular"
            }

            self?.eventSink?(enhancedProgress)
        }
    }

    deinit {
        Task {
            await downloadManager.cancelAllDownloads()
            await downloadManager.cancelHlsQueue()
            queueAccessQueue.sync {
                downloadQueue.removeAll()
                isProcessingQueue = false
            }
        }
    }
}