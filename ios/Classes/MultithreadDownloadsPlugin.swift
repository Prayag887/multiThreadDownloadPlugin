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

    public struct DownloadRequest {
        public let urls: [String]
        public let filePath: String
        public let headers: [String: String]
        public let maxConcurrentTasks: Int
        public let retryCount: Int
        public let timeoutSeconds: Int
        public let requestId: String

        public init(urls: [String], filePath: String, headers: [String: String],
             maxConcurrentTasks: Int, retryCount: Int, timeoutSeconds: Int) {
            self.urls = urls
            self.filePath = filePath
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

        case "cancelAllDownloads":
            let cancelled = downloadManager.cancelAllDownloads()
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
            result(downloadManager.getDownloadStatus(url: url))

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

        let downloadRequest = DownloadRequest(
            urls: urls,
            filePath: filePath,
            headers: headers,
            maxConcurrentTasks: maxConcurrentTasks,
            retryCount: retryCount,
            timeoutSeconds: timeoutSeconds
        )

        queueAccessQueue.sync {
            downloadQueue.append(downloadRequest)
            print("Added download request to queue. Queue size: \(downloadQueue.count)")
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

        print("Processing download request: \(request.requestId)")

        sendBatchEvent(requestId: request.requestId,
                      status: "started",
                      urls: request.urls)

        downloadManager.startBatchDownload(
            urls: request.urls,
            basePath: request.filePath,
            headers: request.headers,
            maxConcurrentTasks: request.maxConcurrentTasks,
            retryCount: request.retryCount,
            timeoutSeconds: request.timeoutSeconds,
            onProgress: { [weak self] progress in
                var enhancedProgress = progress
                enhancedProgress["requestId"] = request.requestId
                enhancedProgress["isBatchProgress"] = true
                self?.sendProgress(progress: enhancedProgress)
            },
            onBatchComplete: { [weak self] in
                guard let self = self else { return }

                print("Batch \(request.requestId) completed")

                self.sendBatchEvent(requestId: request.requestId,
                                    status: "completed",
                                    urls: request.urls)

                self.queueAccessQueue.sync {
                    self.isProcessingQueue = false
                }

                self.sendQueueStatus()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.processDownloadQueue()
                }
            }
        )

        sendQueueStatus()
    }

    private func sendBatchEvent(requestId: String, status: String, urls: [String]) {
        let event: [String: Any] = [
            "batchEvent": true,
            "requestId": requestId,
            "status": status,
            "totalSegments": urls.count,
            "timestamp": Date().timeIntervalSince1970
        ]
        sendProgress(progress: event)
    }

    private func getQueueStatus() -> [String: Any] {
        return queueAccessQueue.sync {
            let currentRequestId = downloadQueue.first?.requestId ?? "none"

            return [
                "queueSize": downloadQueue.count,
                "isProcessing": isProcessingQueue,
                "currentRequestId": currentRequestId,
                "isBatchActive": downloadManager.isBatchActive(),
                "isReadyForNewBatch": downloadManager.isReadyForNewBatch()
            ]
        }
    }

    private func sendQueueStatus() {
        var queueStatus = getQueueStatus()
        queueStatus["isQueueStatus"] = true
        sendProgress(progress: queueStatus)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
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