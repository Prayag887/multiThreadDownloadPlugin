import Foundation

struct DownloadUtils {

    static func extractFileName(url: String) -> String {
        do {
            guard let uri = URL(string: url) else {
                return "download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp"
            }

            let path = uri.path
            let fileName = String(path.split(separator: "/").last ?? "")

            if !fileName.isEmpty && fileName.contains(".") {
                return fileName
            } else {
                return "download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp"
            }
        } catch {
            return "download_\(Int64(Date().timeIntervalSince1970 * 1000)).tmp"
        }
    }

    static func isHlsUrl(url: String) -> Bool {
        return url.lowercased().hasSuffix(".m3u8")
    }

    static func createDirectoryIfNotExists(path: String) -> Bool {
        do {
            let directory = URL(fileURLWithPath: path)
            let fileManager = FileManager.default

            if !fileManager.fileExists(atPath: path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            }
            return true
        } catch {
            return false
        }
    }

    static func formatBytes(bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var unitIndex = 0

        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }

        return String(format: "%.2f %@", size, units[unitIndex])
    }

    static func formatSpeed(bytesPerSecond: Double) -> String {
        return "\(formatBytes(bytes: Int64(bytesPerSecond)))/s"
    }

    static func calculateETA(remainingBytes: Int64, speedBytesPerSecond: Double) -> String {
        if speedBytesPerSecond <= 0 {
            return "Unknown"
        }

        let remainingSeconds = Int64(Double(remainingBytes) / speedBytesPerSecond)
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60

        switch true {
        case hours > 0:
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        case minutes > 0:
            return String(format: "%02d:%02d", minutes, seconds)
        default:
            return String(format: "00:%02d", seconds)
        }
    }
}
