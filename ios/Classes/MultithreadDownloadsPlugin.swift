// ios/Classes/MultithreadedDownloadsPlugin.swift
import Flutter
import Foundation

public class MultithreadedDownloadsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private let downloadManager = DownloadManager()
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "multithread_downloads", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "multithread_downloads/progress", binaryMessenger: registrar.messenger())
        
        let instance = MultithreadedDownloadsPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startDownload":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String,
                  let filePath = args["filePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments", details: nil))
                return
            }
            
            let headers = args["headers"] as? [String: String] ?? [:]
            let maxConcurrentTasks = args["maxConcurrentTasks"] as? Int ?? 4
            let chunkSize = args["chunkSize"] as? Int ?? (1024 * 1024)
            let retryCount = args["retryCount"] as? Int ?? 3
            let timeoutSeconds = args["timeoutSeconds"] as? Int ?? 30
            
            downloadManager.startDownload(
                url: url,
                filePath: filePath,
                headers: headers,
                maxConcurrentTasks: maxConcurrentTasks,
                chunkSize: chunkSize,
                retryCount: retryCount,
                timeoutSeconds: timeoutSeconds
            ) { [weak self] progress in
                self?.sendProgress(progress)
            }
            result(true)
            
        case "pauseDownload":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(false)
                return
            }
            result(downloadManager.pauseDownload(url: url))
            
        case "resumeDownload":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(false)
                return
            }
            downloadManager.resumeDownload(url: url) { [weak self] progress in
                self?.sendProgress(progress)
            }
            result(true)
            
        case "cancelDownload":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(false)
                return
            }
            result(downloadManager.cancelDownload(url: url))
            
        case "getDownloadStatus":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(nil)
                return
            }
            result(downloadManager.getDownloadStatus(url: url))
            
        case "getAllDownloads":
            result(downloadManager.getAllDownloads())
            
        case "clearCompletedDownloads":
            result(downloadManager.clearCompletedDownloads())
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
    
    private func sendProgress(_ progress: [String: Any]) {
        DispatchQueue.main.async {
            self.eventSink?(progress)
        }
    }
}

// MARK: - Download Manager
class DownloadManager {
    private var downloads: [String: DownloadTask] = [:]
    private let downloadQueue = DispatchQueue(label: "download.queue", attributes: .concurrent)
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    func startDownload(
        url: String,
        filePath: String,
        headers: [String: String],
        maxConcurrentTasks: Int,
        chunkSize: Int,
        retryCount: Int,
        timeoutSeconds: Int,
        onProgress: @escaping ([String: Any]) -> Void
    ) {
        let task = DownloadTask(
            url: url,
            filePath: filePath,
            headers: headers,
            maxConcurrentTasks: maxConcurrentTasks,
            chunkSize: chunkSize,
            retryCount: retryCount,
            timeoutSeconds: timeoutSeconds
        )
        
        downloads[url] = task
        
        downloadQueue.async {
            self.downloadFile(task: task, onProgress: onProgress)
        }
    }
    
    private func downloadFile(task: DownloadTask, onProgress: @escaping ([String: Any]) -> Void) {
        // Check if file exists for resume capability
        let fileURL = URL(fileURLWithPath: task.filePath)
        let fileManager = FileManager.default
        
        if fileManager.fileExists(atPath: task.filePath) {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: task.filePath)
                task.downloadedBytes = attributes[.size] as? Int64 ?? 0
            } catch {
                task.downloadedBytes = 0
            }
        }
        
        // Create directory if needed
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // Get file size
        guard let url = URL(string: task.url) else {
            task.status = .failed
            task.error = "Invalid URL"
            sendProgress(task: task, onProgress: onProgress)
            return
        }
        
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        for (key, value) in task.headers {
            headRequest.setValue(value, forHTTPHeaderField: key)
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var headError: Error?
        
        session.dataTask(with: headRequest) { _, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                headError = error
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                task.totalBytes = httpResponse.expectedContentLength
                task.acceptsRanges = httpResponse.allHeaderFields["Accept-Ranges"] as? String == "bytes"
            }
        }.resume()
        
        semaphore.wait()
        
        if let error = headError {
            task.status = .failed
            task.error = error.localizedDescription
            sendProgress(task: task, onProgress: onProgress)
            return
        }
        
        if task.totalBytes <= task.downloadedBytes {
            task.status = .completed
            task.downloadedBytes = task.totalBytes
            sendProgress(task: task, onProgress: onProgress)
            return
        }
        
        task.status = .downloading
        task.startTime = Date().timeIntervalSince1970
        sendProgress(task: task, onProgress: onProgress)
        
        if task.acceptsRanges && task.totalBytes > task.chunkSize && task.maxConcurrentTasks > 1 {
            downloadMultiThreaded(task: task, onProgress: onProgress)
        } else {
            downloadSingleThreaded(task: task, onProgress: onProgress)
        }
    }

    private func downloadMultiThreaded(task: DownloadTask, onProgress: @escaping ([String: Any]) -> Void) {
           let remainingBytes = task.totalBytes - task.downloadedBytes
           let numThreads = min(task.maxConcurrentTasks, Int((remainingBytes / Int64(task.chunkSize)) + 1))
           let chunkSize = remainingBytes / Int64(numThreads)

           let group = DispatchGroup()
           let fileHandle: FileHandle

           do {
               if !FileManager.default.fileExists(atPath: task.filePath) {
                   FileManager.default.createFile(atPath: task.filePath, contents: nil)
               }
               fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: task.filePath))
           } catch {
               task.status = .failed
               task.error = "Could not open file for writing"
               sendProgress(task: task, onProgress: onProgress)
               return
           }

           for i in 0..<numThreads {
               let startByte = task.downloadedBytes + Int64(i) * chunkSize
               let endByte = i == numThreads - 1 ? task.totalBytes - 1 : task.downloadedBytes + Int64(i + 1) * chunkSize - 1

               group.enter()
               downloadQueue.async {
                   self.downloadChunk(
                       task: task,
                       startByte: startByte,
                       endByte: endByte,
                       fileHandle: fileHandle,
                       onProgress: onProgress
                   ) {
                       group.leave()
                   }
               }
           }

           group.notify(queue: downloadQueue) {
               fileHandle.closeFile()
               if task.status == .downloading {
                   task.status = .completed
                   self.sendProgress(task: task, onProgress: onProgress)
               }
           }
       }

       private func downloadChunk(
           task: DownloadTask,
           startByte: Int64,
           endByte: Int64,
           fileHandle: FileHandle,
           onProgress: @escaping ([String: Any]) -> Void,
           completion: @escaping () -> Void
       ) {
           var retries = 0

           func attemptDownload() {
               guard let url = URL(string: task.url) else {
                   task.status = .failed
                   task.error = "Invalid URL"
                   completion()
                   return
               }

               var request = URLRequest(url: url)
               request.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")
               for (key, value) in task.headers {
                   request.setValue(value, forHTTPHeaderField: key)
               }

               session.dataTask(with: request) { data, response, error in
                   if let error = error {
                       retries += 1
                       if retries <= task.retryCount && task.status == .downloading {
                           DispatchQueue.global().asyncAfter(deadline: .now() + Double(retries)) {
                               attemptDownload()
                           }
                       } else {
                           task.status = .failed
                           task.error = "Chunk download failed: \(error.localizedDescription)"
                           completion()
                       }
                       return
                   }

                   guard let httpResponse = response as? HTTPURLResponse,
                         httpResponse.statusCode == 206 || httpResponse.statusCode == 200,
                         let data = data else {
                       retries += 1
                       if retries <= task.retryCount && task.status == .downloading {
                           DispatchQueue.global().asyncAfter(deadline: .now() + Double(retries)) {
                               attemptDownload()
                           }
                       } else {
                           task.status = .failed
                           task.error = "HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                           completion()
                       }
                       return
                   }

                   // Write data to file
                   fileHandle.seek(toFileOffset: UInt64(startByte))
                   fileHandle.write(data)

                   // Update progress
                   task.downloadedBytes += Int64(data.count)
                   self.sendProgress(task: task, onProgress: onProgress)

                   completion()
               }.resume()
           }

           attemptDownload()
       }

       private func downloadSingleThreaded(task: DownloadTask, onProgress: @escaping ([String: Any]) -> Void) {
           var retries = 0

           func attemptDownload() {
               guard let url = URL(string: task.url) else {
                   task.status = .failed
                   task.error = "Invalid URL"
                   sendProgress(task: task, onProgress: onProgress)
                   return
               }

               var request = URLRequest(url: url)
               if task.downloadedBytes > 0 {
                   request.setValue("bytes=\(task.downloadedBytes)-", forHTTPHeaderField: "Range")
               }
               for (key, value) in task.headers {
                   request.setValue(value, forHTTPHeaderField: key)
               }

               let downloadTask = session.downloadTask(with: request) { tempURL, response, error in
                   if let error = error {
                       retries += 1
                       if retries <= task.retryCount && task.status == .downloading {
                           DispatchQueue.global().asyncAfter(deadline: .now() + Double(retries)) {
                               attemptDownload()
                           }
                       } else {
                           task.status = .failed
                           task.error = "Download failed: \(error.localizedDescription)"
                           self.sendProgress(task: task, onProgress: onProgress)
                       }
                       return
                   }

                   guard let httpResponse = response as? HTTPURLResponse,
                         httpResponse.statusCode == 200 || httpResponse.statusCode == 206,
                         let tempURL = tempURL else {
                       retries += 1
                       if retries <= task.retryCount && task.status == .downloading {
                           DispatchQueue.global().asyncAfter(deadline: .now() + Double(retries)) {
                               attemptDownload()
                           }
                       } else {
                           task.status = .failed
                           task.error = "HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                           self.sendProgress(task: task, onProgress: onProgress)
                       }
                       return
                   }

                   do {
                       let destinationURL = URL(fileURLWithPath: task.filePath)

                       if task.downloadedBytes > 0 {
                           // Append to existing file
                           let tempData = try Data(contentsOf: tempURL)
                           let fileHandle = try FileHandle(forWritingTo: destinationURL)
                           fileHandle.seekToEndOfFile()
                           fileHandle.write(tempData)
                           fileHandle.closeFile()
                       } else {
                           // Move temp file to destination
                           if FileManager.default.fileExists(atPath: task.filePath) {
                               try FileManager.default.removeItem(at: destinationURL)
                           }
                           try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                       }

                       if task.status == .downloading {
                           task.status = .completed
                           task.downloadedBytes = task.totalBytes
                           self.sendProgress(task: task, onProgress: onProgress)
                       }
                   } catch {
                       task.status = .failed
                       task.error = "File operation failed: \(error.localizedDescription)"
                       self.sendProgress(task: task, onProgress: onProgress)
                   }
               }

               // Track progress for single-threaded downloads
               task.urlSessionTask = downloadTask
               downloadTask.resume()
           }

           attemptDownload()
       }

       private func sendProgress(task: DownloadTask, onProgress: @escaping ([String: Any]) -> Void) {
           let currentTime = Date().timeIntervalSince1970
           let timeElapsed = max(1, currentTime - task.startTime)
           let speed = timeElapsed > 0 ? Double(task.downloadedBytes) / timeElapsed : 0.0
           let progress = task.totalBytes > 0 ? Int((Double(task.downloadedBytes) * 100.0) / Double(task.totalBytes)) : 0

           let progressMap: [String: Any] = [
               "url": task.url,
               "filePath": task.filePath,
               "progress": progress,
               "bytesDownloaded": task.downloadedBytes,
               "totalBytes": task.totalBytes,
               "status": task.status.rawValue,
               "error": task.error as Any,
               "speed": speed
           ]

           onProgress(progressMap)
       }

       func pauseDownload(url: String) -> Bool {
           guard let task = downloads[url] else { return false }
           if task.status == .downloading {
               task.status = .paused
               task.urlSessionTask?.cancel()
               return true
           }
           return false
       }

       func resumeDownload(url: String, onProgress: @escaping ([String: Any]) -> Void) {
           guard let task = downloads[url] else { return }
           if task.status == .paused {
               downloadQueue.async {
                   self.downloadFile(task: task, onProgress: onProgress)
               }
           }
       }

       func cancelDownload(url: String) -> Bool {
           guard let task = downloads[url] else { return false }
           task.status = .cancelled
           task.urlSessionTask?.cancel()

           // Delete partial file
           try? FileManager.default.removeItem(atPath: task.filePath)

           downloads.removeValue(forKey: url)
           return true
       }

       func getDownloadStatus(url: String) -> [String: Any]? {
           guard let task = downloads[url] else { return nil }

           let currentTime = Date().timeIntervalSince1970
           let timeElapsed = max(1, currentTime - task.startTime)
           let speed = timeElapsed > 0 ? Double(task.downloadedBytes) / timeElapsed : 0.0
           let progress = task.totalBytes > 0 ? Int((Double(task.downloadedBytes) * 100.0) / Double(task.totalBytes)) : 0

           return [
               "url": task.url,
               "filePath": task.filePath,
               "progress": progress,
               "bytesDownloaded": task.downloadedBytes,
               "totalBytes": task.totalBytes,
               "status": task.status.rawValue,
               "error": task.error as Any,
               "speed": speed
           ]
       }

       func getAllDownloads() -> [[String: Any]] {
           return downloads.values.compactMap { task in
               getDownloadStatus(url: task.url)
           }
       }

       func clearCompletedDownloads() -> Bool {
           let completedUrls = downloads.filter { $0.value.status == .completed }.map { $0.key }
           completedUrls.forEach { url in
               downloads.removeValue(forKey: url)
           }
           return true
       }
    }

    // MARK: - Data Models
    class DownloadTask {
       let url: String
       let filePath: String
       let headers: [String: String]
       let maxConcurrentTasks: Int
       let chunkSize: Int
       let retryCount: Int
       let timeoutSeconds: Int

       var totalBytes: Int64 = 0
       var downloadedBytes: Int64 = 0
       var status: DownloadStatus = .pending
       var error: String?
       var startTime: TimeInterval = 0
       var acceptsRanges: Bool = false
       var urlSessionTask: URLSessionTask?

       init(url: String, filePath: String, headers: [String: String], maxConcurrentTasks: Int, chunkSize: Int, retryCount: Int, timeoutSeconds: Int) {
           self.url = url
           self.filePath = filePath
           self.headers = headers
           self.maxConcurrentTasks = maxConcurrentTasks
           self.chunkSize = chunkSize
           self.retryCount = retryCount
           self.timeoutSeconds = timeoutSeconds
       }
    }

    enum DownloadStatus: Int {
       case pending = 0
       case downloading = 1
       case paused = 2
       case completed = 3
       case failed = 4
       case cancelled = 5
    }

