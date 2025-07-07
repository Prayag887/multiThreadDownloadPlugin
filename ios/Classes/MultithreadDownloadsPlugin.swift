import Flutter
import UIKit

public class MultithreadDownloadsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var channel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    private let downloadManager = ParallelDownloadManager()
    private var downloadQueue = Queue<DownloadRequest>()
    private var isProcessingQueue = false
    private let queueLock = NSLock()
    
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
            self.requestId = String(Int(Date().timeIntervalSince1970 * 1000))
        }
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "multithread_downloads", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "multithread_downloads/progress", binaryMessenger: registrar.messenger())
        let instance = MultithreadDownloadsPlugin()
        instance.channel = channel
        instance.eventChannel = eventChannel
        
        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startDownload":
            handleStartDownload(call, result: result)
        case "pauseDownload":
            handlePauseDownload(call, result: result)
        case "resumeDownload":
            handleResumeDownload(call, result: result)
        case "cancelDownload":
            handleCancelDownload(call, result: result)
        case "pauseAllDownloads":
            result(downloadManager.pauseAllDownloads())
        case "resumeAllDownloads":
            downloadManager.resumeAllDownloads { [weak self] progress in
                self?.sendProgress(progress)
            }
            result(true)
        case "cancelAllDownloads":
            let cancelled = downloadManager.cancelAllDownloads()
            clearQueue()
            result(cancelled)
        case "pauseDownloads":
            handlePauseDownloads(call, result: result)
        case "resumeDownloads":
            handleResumeDownloads(call, result: result)
        case "cancelDownloads":
            handleCancelDownloads(call, result: result)
        case "getDownloadStatus":
            handleGetDownloadStatus(call, result: result)
        case "getDownloadStatuses":
            handleGetDownloadStatuses(call, result: result)
        case "getAllDownloads":
            result(downloadManager.getAllDownloads())
        case "getBatchProgress":
            result(downloadManager.getBatchProgress())
        case "clearCompletedDownloads":
            result(downloadManager.clearCompletedDownloads())
        case "getQueueSize":
            result(downloadQueue.count)
        case "getQueueStatus":
            result(getQueueStatus())
        case "clearQueue":
            clearQueue()
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func handleStartDownload(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let urls = args["urls"] as? [String],
              let filePath = args["filePath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
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
        
        downloadQueue.enqueue(downloadRequest)
        print("Added download request to queue. Queue size: \(downloadQueue.count)")
        
        sendQueueStatus()
        processDownloadQueue()
        
        result([
            "success": true,
            "queueSize": downloadQueue.count,
            "isProcessing": isProcessingQueue
        ])
    }
    
    private func handlePauseDownload(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String else {
            result(false)
            return
        }
        result(downloadManager.pauseDownload(url))
    }
    
    private func handleResumeDownload(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String else {
            result(false)
            return
        }
        downloadManager.resumeDownload(url) { [weak self] progress in
            self?.sendProgress(progress)
        }
        result(true)
    }
    
    private func handleCancelDownload(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String else {
            result(false)
            return
        }
        result(downloadManager.cancelDownload(url))
    }
    
    private func handlePauseDownloads(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let urls = args["urls"] as? [String] else {
            result(false)
            return
        }
        result(downloadManager.pauseDownloads(urls))
    }
    
    private func handleResumeDownloads(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let urls = args["urls"] as? [String] else {
            result(false)
            return
        }
        downloadManager.resumeDownloads(urls) { [weak self] progress in
            self?.sendProgress(progress)
        }
        result(true)
    }
    
    private func handleCancelDownloads(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let urls = args["urls"] as? [String] else {
            result(false)
            return
        }
        result(downloadManager.cancelDownloads(urls))
    }
    
    private func handleGetDownloadStatus(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String else {
            result(nil)
            return
        }
        result(downloadManager.getDownloadStatus(url))
    }
    
    private func handleGetDownloadStatuses(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let urls = args["urls"] as? [String] else {
            result([])
            return
        }
        result(downloadManager.getDownloadStatuses(urls))
    }
    
    private func processDownloadQueue() {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        if isProcessingQueue || downloadQueue.isEmpty {
            return
        }
        
        if !downloadManager.isReadyForNewBatch() {
            print("Download manager not ready for new batch, waiting...")
            return
        }
        
        isProcessingQueue = true
        
        guard let request = downloadQueue.dequeue() else {
            isProcessingQueue = false
            return
        }
        
        print("Processing download request with \(request.urls.count) URLs")
        
        downloadManager.startBatchDownload(
            urls: request.urls,
            filePath: request.filePath,
            headers: request.headers,
            maxConcurrentTasks: request.maxConcurrentTasks,
            retryCount: request.retryCount,
            timeoutSeconds: request.timeoutSeconds,
            onProgress: { [weak self] progress in
                self?.sendProgress(progress)
            },
            onBatchComplete: { [weak self] in
                print("Batch completed, processing next item in queue")
                self?.queueLock.lock()
                self?.isProcessingQueue = false
                self?.queueLock.unlock()
                
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
        return [
            "queueSize": downloadQueue.count,
            "isProcessing": isProcessingQueue,
            "isBatchActive": downloadManager.isBatchActive(),
            "currentBatchComplete": downloadManager.isBatchComplete(),
            "isReadyForNewBatch": downloadManager.isReadyForNewBatch()
        ]
    }
    
    private func sendQueueStatus() {
        var queueStatus = getQueueStatus()
        queueStatus["isQueueStatus"] = true
        sendProgress(queueStatus)
    }
    
    private func clearQueue() {
        queueLock.lock()
        downloadQueue.clear()
        isProcessingQueue = false
        queueLock.unlock()
        sendQueueStatus()
    }
    
    private func sendProgress(_ progress: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(progress)
        }
    }
    
    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        sendQueueStatus()
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
    
    deinit {
        downloadManager.cancelAllDownloads()
        clearQueue()
    }
}

// MARK: - Queue Implementation
class Queue<T> {
    private var items: [T] = []
    private let lock = NSLock()
    
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
    
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty
    }
    
    func enqueue(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }
    
    func dequeue() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
    }
}

// MARK: - ParallelDownloadManager
class ParallelDownloadManager {
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var downloadStatuses: [String: [String: Any]] = [:]
    private let lock = NSLock()
    private var urlSession: URLSession?
    private var batchActive = false
    private var batchComplete = false
    private var currentBatchUrls: [String] = []
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }
    
    func startBatchDownload(
        urls: [String],
        filePath: String,
        headers: [String: String],
        maxConcurrentTasks: Int,
        retryCount: Int,
        timeoutSeconds: Int,
        onProgress: @escaping ([String: Any]) -> Void,
        onBatchComplete: @escaping () -> Void
    ) {
        lock.lock()
        batchActive = true
        batchComplete = false
        currentBatchUrls = urls
        lock.unlock()
        
        let dispatchGroup = DispatchGroup()
        let semaphore = DispatchSemaphore(value: maxConcurrentTasks)
        
        for url in urls {
            dispatchGroup.enter()
            
            DispatchQueue.global(qos: .background).async {
                semaphore.wait()
                
                self.downloadFile(
                    url: url,
                    filePath: filePath,
                    headers: headers,
                    retryCount: retryCount,
                    timeoutSeconds: timeoutSeconds,
                    onProgress: onProgress
                ) { success in
                    semaphore.signal()
                    dispatchGroup.leave()
                }
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            self.lock.lock()
            self.batchActive = false
            self.batchComplete = true
            self.currentBatchUrls = []
            self.lock.unlock()
            
            onBatchComplete()
        }
    }
    
    private func downloadFile(
        url: String,
        filePath: String,
        headers: [String: String],
        retryCount: Int,
        timeoutSeconds: Int,
        onProgress: @escaping ([String: Any]) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        guard let downloadURL = URL(string: url) else {
            completion(false)
            return
        }
        
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let task = urlSession?.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else {
                completion(false)
                return
            }
            
            if let error = error {
                print("Download error for \(url): \(error)")
                onProgress([
                    "url": url,
                    "status": "error",
                    "error": error.localizedDescription,
                    "progress": 0.0
                ])
                completion(false)
                return
            }
            
            guard let tempURL = tempURL else {
                completion(false)
                return
            }
            
            do {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileName = URL(string: url)?.lastPathComponent ?? "downloaded_file"
                let destinationURL = documentsPath.appendingPathComponent(fileName)
                
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                
                onProgress([
                    "url": url,
                    "status": "completed",
                    "progress": 1.0,
                    "filePath": destinationURL.path
                ])
                
                completion(true)
            } catch {
                print("File move error: \(error)")
                onProgress([
                    "url": url,
                    "status": "error",
                    "error": error.localizedDescription,
                    "progress": 0.0
                ])
                completion(false)
            }
        }
        
        lock.lock()
        downloadTasks[url] = task
        downloadStatuses[url] = [
            "url": url,
            "status": "downloading",
            "progress": 0.0
        ]
        lock.unlock()
        
        task?.resume()
    }
    
    func pauseDownload(_ url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let task = downloadTasks[url] else { return false }
        task.suspend()
        downloadStatuses[url]?["status"] = "paused"
        return true
    }
    
    func resumeDownload(_ url: String, onProgress: @escaping ([String: Any]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let task = downloadTasks[url] else { return }
        task.resume()
        downloadStatuses[url]?["status"] = "downloading"
    }
    
    func cancelDownload(_ url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let task = downloadTasks[url] else { return false }
        task.cancel()
        downloadTasks.removeValue(forKey: url)
        downloadStatuses.removeValue(forKey: url)
        return true
    }
    
    func pauseAllDownloads() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        for task in downloadTasks.values {
            task.suspend()
        }
        
        for url in downloadStatuses.keys {
            downloadStatuses[url]?["status"] = "paused"
        }
        
        return true
    }
    
    func resumeAllDownloads(onProgress: @escaping ([String: Any]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        
        for task in downloadTasks.values {
            task.resume()
        }
        
        for url in downloadStatuses.keys {
            downloadStatuses[url]?["status"] = "downloading"
        }
    }
    
    func cancelAllDownloads() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        for task in downloadTasks.values {
            task.cancel()
        }
        
        downloadTasks.removeAll()
        downloadStatuses.removeAll()
        batchActive = false
        batchComplete = false
        currentBatchUrls = []
        
        return true
    }
    
    func pauseDownloads(_ urls: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        for url in urls {
            if let task = downloadTasks[url] {
                task.suspend()
                downloadStatuses[url]?["status"] = "paused"
            }
        }
        return true
    }
    
    func resumeDownloads(_ urls: [String], onProgress: @escaping ([String: Any]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        
        for url in urls {
            if let task = downloadTasks[url] {
                task.resume()
                downloadStatuses[url]?["status"] = "downloading"
            }
        }
    }
    
    func cancelDownloads(_ urls: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        for url in urls {
            if let task = downloadTasks[url] {
                task.cancel()
                downloadTasks.removeValue(forKey: url)
                downloadStatuses.removeValue(forKey: url)
            }
        }
        return true
    }
    
    func getDownloadStatus(_ url: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return downloadStatuses[url]
    }
    
    func getDownloadStatuses(_ urls: [String]) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        
        return urls.compactMap { downloadStatuses[$0] }
    }
    
    func getAllDownloads() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        
        return Array(downloadStatuses.values)
    }
    
    func getBatchProgress() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        
        let totalTasks = downloadStatuses.count
        let completedTasks = downloadStatuses.values.filter { 
            ($0["status"] as? String) == "completed" 
        }.count
        
        return [
            "totalTasks": totalTasks,
            "completedTasks": completedTasks,
            "progress": totalTasks > 0 ? Double(completedTasks) / Double(totalTasks) : 0.0
        ]
    }
    
    func clearCompletedDownloads() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let completedUrls = downloadStatuses.compactMap { (key, value) in
            (value["status"] as? String) == "completed" ? key : nil
        }
        
        for url in completedUrls {
            downloadStatuses.removeValue(forKey: url)
            downloadTasks.removeValue(forKey: url)
        }
        
        return true
    }
    
    func isBatchActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return batchActive
    }
    
    func isBatchComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return batchComplete
    }
    
    func isReadyForNewBatch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !batchActive
    }
}