import Flutter
import UIKit

@available(iOS 15.0, *)
public class MultithreadDownloadsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var channel: FlutterMethodChannel!
    private var eventChannel: FlutterEventChannel!
    private var eventSink: FlutterEventSink?
    private let downloadManager = ParallelDownloadManager()

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
            result(downloadManager.pauseDownload(url: urlString))

        case "resumeDownload":
            guard let url = call.arguments as? [String: Any],
                  let urlString = url["url"] as? String else {
                result(false)
                return
            }
            downloadManager.resumeDownload(url: urlString) { [weak self] progress in
                self?.sendProgress(progress: progress)
            }
            result(true)

        case "cancelDownload":
            guard let url = call.arguments as? [String: Any],
                  let urlString = url["url"] as? String else {
                result(false)
                return
            }
            result(downloadManager.cancelDownload(url: urlString))

        case "pauseAllDownloads":
            result(downloadManager.pauseAllDownloads())

//        case "resumeAllDownloads":
//            downloadManager.resumeAllDownloads { [weak self] progress in
//                self?.sendProgress(progress: progress)
//            }
//            result(true)

        case "cancelAllDownloads":
            let cancelled = downloadManager.cancelAllDownloads()
            queueAccessQueue.sync {
                downloadQueue.removeAll()
                isProcessingQueue = false
            }
            sendQueueStatus()
            result(cancelled)

//        case "pauseDownloads":
//            guard let args = call.arguments as? [String: Any],
//                  let urls = args["urls"] as? [String] else {
//                result(false)
//                return
//            }
//            result(downloadManager.pauseDownloads(urls: urls))
//
//        case "resumeDownloads":
//            guard let args = call.arguments as? [String: Any],
//                  let urls = args["urls"] as? [String] else {
//                result(false)
//                return
//            }
//            downloadManager.resumeDownloads(urls: urls) { [weak self] progress in
//                self?.sendProgress(progress: progress)
//            }
//            result(true)

//        case "cancelDownloads":
//            guard let args = call.arguments as? [String: Any],
//                  let urls = args["urls"] as? [String] else {
//                result(false)
//                return
//            }
//            result(downloadManager.cancelDownloads(urls: urls))

        case "getDownloadStatus":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(nil)
                return
            }
            result(downloadManager.getDownloadStatus(url: url))

//        case "getDownloadStatuses":
//            guard let args = call.arguments as? [String: Any],
//                  let urls = args["urls"] as? [String] else {
//                result([])
//                return
//            }
//            result(downloadManager.getDownloadStatuses(urls: urls))

//        case "getAllDownloads":
//            result(downloadManager.getAllDownloads())

        case "getBatchProgress":
            result(downloadManager.getBatchProgress())

        case "clearCompletedDownloads":
            result(downloadManager.clearCompletedDownloads())

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

        print("headers::: \(headers)")

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
            print("Added download request to queue. Queue size: \(downloadQueue.count)")
        }

        // Send queue status update
        sendQueueStatus()

        // Process queue
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

            if !downloadManager.isReadyForNewBatch() {
                print("Download manager not ready for new batch, waiting...")
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

        print("Processing download request with \(request.urls.count) URLs")

        downloadManager.startBatchDownload(
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
                print("Batch completed, processing next item in queue")
                self?.queueAccessQueue.sync {
                    self?.isProcessingQueue = false
                }
                self?.sendQueueStatus()

                // Small delay to ensure cleanup is complete before processing next batch
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.processDownloadQueue()
                }
            }
        )

        sendQueueStatus()
    }

    private func getQueueStatus() -> [String: Any] {
        return queueAccessQueue.sync {
            [
                "queueSize": downloadQueue.count,
                "isProcessing": isProcessingQueue,
                "isBatchActive": downloadManager.isBatchActive(),
                "currentBatchComplete": downloadManager.isBatchComplete(),
                "isReadyForNewBatch": downloadManager.isReadyForNewBatch()
            ]
        }
    }

    private func sendQueueStatus() {
        var queueStatus = getQueueStatus()
        queueStatus["isQueueStatus"] = true
        sendProgress(progress: queueStatus)
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        // Send initial queue status
        sendQueueStatus()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func sendProgress(progress: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(progress)
        }
    }

    deinit {
        downloadManager.cancelAllDownloads()
        queueAccessQueue.sync {
            downloadQueue.removeAll()
            isProcessingQueue = false
        }
    }
}
