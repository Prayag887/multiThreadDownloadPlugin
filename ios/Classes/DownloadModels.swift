import Foundation

@available(iOS 13.0, *)
struct MTDownloadTask {
    var url: String
    var filePath: String
    var fileName: String
    var headers: [String: String]
    var retryCount: Int = 3
    var totalBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var status: MTDownloadStatus = .pending
    var error: String? = nil
    var startTime: Double = 0
    var lastSpeedUpdate: Double = 0
    var job: Task<Void, Error>? = nil
    var speedHistory: [Double] = []
    var timeoutSeconds: Int = 30
}

enum MTDownloadStatus: Int {
    case pending = 0
    case downloading = 1
    case paused = 2
    case completed = 3
    case failed = 4
    case cancelled = 5
    case initializing = 6
}
