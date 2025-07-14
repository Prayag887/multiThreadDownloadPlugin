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
    
    // MARK: - Async Handler Methods
    
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
            await MainActor.run {
                result(success)
            }
        }
    }
    
    private func handleCancelAllDownloads(result: @escaping FlutterResult) {
        Task {
            let cancelled = await downloadManager.cancelAllDownloads()
            
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
        
        let downloadRequest = DownloadRequest(
            urls: urls,
            filePath: filePath,
            fileName: fileName,
            headers: headers,
            maxConcurrentTasks: maxConcurrentTasks,
            retryCount: retryCount,
            timeoutSeconds: timeoutSeconds
        )
        
        queueAccessQueue.sync {
            downloadQueue.append(downloadRequest)
        }
        
        processDownloadQueue()
        
        result(true)
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
    
    private func sendProgress(progress: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(progress)
        }
    }
    
    deinit {
        Task {
            await downloadManager.cancelAllDownloads()
            queueAccessQueue.sync {
                downloadQueue.removeAll()
                isProcessingQueue = false
            }
        }
    }
}
