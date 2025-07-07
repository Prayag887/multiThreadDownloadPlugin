import Foundation

@available(iOS 13.0, *)
class HttpsDownloader {

    func downloadSingleFile(
        task: MTDownloadTask,
        onProgress: @escaping ([String: Any]) -> Void
    ) async throws {
        var task = task

        let fileURL = URL(fileURLWithPath: task.filePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Resume from existing file if present
        if FileManager.default.fileExists(atPath: task.filePath) {
            let attributes = try FileManager.default.attributesOfItem(atPath: task.filePath)
            task.downloadedBytes = attributes[.size] as? Int64 ?? 0
        } else {
            task.downloadedBytes = 0
        }

        task.status = .downloading
        task.startTime = Date().timeIntervalSince1970 * 1000
        task.lastSpeedUpdate = task.startTime

        let totalBytes = await getFileSize(task: task)
        task.totalBytes = totalBytes
        sendProgress(task: task, onProgress: onProgress)

        // Retry logic
        for attempt in 0...task.retryCount {
            if task.status != .downloading { return }

            do {
                guard let request = HttpClientConfig.buildRequest(
                    url: task.url,
                    headers: task.headers,
                    startByte: task.downloadedBytes
                ) else {
                    throw NSError(domain: "Invalid URL", code: -1)
                }

                let (data, response) = try await HttpClientConfig.client.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "Invalid response", code: -1)
                }

                if !httpResponse.isSuccessful && httpResponse.statusCode != 206 {
                    throw NSError(domain: "HTTP \(httpResponse.statusCode)", code: httpResponse.statusCode)
                }

                // Update total bytes if not known
                if task.totalBytes <= 0 {
                    if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                       let length = Int64(contentLength) {
                        task.totalBytes = length + task.downloadedBytes
                    }
                }

                // Write data to file
                let fileHandle: FileHandle
                if task.downloadedBytes > 0 {
                    // Append mode
                    fileHandle = try FileHandle(forWritingTo: fileURL)
                    fileHandle.seekToEndOfFile()
                } else {
                    // Create new file
                    FileManager.default.createFile(atPath: task.filePath, contents: nil)
                    fileHandle = try FileHandle(forWritingTo: fileURL)
                }

                defer { fileHandle.closeFile() }

                // Process data in chunks with progress updates
                let bufferSize = 32768 // Larger buffer for better performance
                var offset = 0
                var lastUpdate: Double = 0
                var bytesInInterval: Int64 = 0

                while offset < data.count && task.status == .downloading {
                    let chunkSize = min(bufferSize, data.count - offset)
                    let chunk = data.subdata(in: offset..<(offset + chunkSize))

                    fileHandle.write(chunk)
                    task.downloadedBytes += Int64(chunkSize)
                    bytesInInterval += Int64(chunkSize)
                    offset += chunkSize

                    let now = Date().timeIntervalSince1970 * 1000
                    if now - lastUpdate > 1000 {
                        updateSpeedHistory(task: task, bytes: bytesInInterval, timeMs: Int64(now - lastUpdate))
                        sendProgress(task: task, onProgress: onProgress)
                        lastUpdate = now
                        bytesInInterval = 0
                    }
                }

                if task.status == .downloading {
                    task.status = .completed
                    sendProgress(task: task, onProgress: onProgress)
                }
                return

            } catch {
                if attempt == task.retryCount {
                    task.status = .failed
                    task.error = error.localizedDescription
                    throw error
                }

                // Exponential backoff with jitter
                let delay = (500 * (1 << attempt)) + Int.random(in: 0...500)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
        }
    }

    private func getFileSize(task: MTDownloadTask) async -> Int64 {
        do {
            guard let request = HttpClientConfig.buildRequest(url: task.url, headers: task.headers) else {
                return -1
            }

            let (_, response) = try await HttpClientConfig.client.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.isSuccessful else {
                return -1
            }

            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") {
                return Int64(contentLength) ?? -1
            }

            return -1
        } catch {
            return -1
        }
    }

    private func updateSpeedHistory(task: MTDownloadTask, bytes: Int64, timeMs: Int64) {
        var task = task
        let speed = timeMs > 0 ? (Double(bytes) * 1000.0 / Double(timeMs)) : 0.0
        task.speedHistory.append(speed)
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

// Extension for HTTPURLResponse
extension HTTPURLResponse {
    var isSuccessful: Bool {
        return 200...299 ~= statusCode
    }
}
