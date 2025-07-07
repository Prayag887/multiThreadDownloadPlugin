import Foundation

// MARK: - Download Utils
struct DownloadUtils {

    /// Extracts filename from URL, generates fallback if unable to parse
    static func extractFileName(from url: String) -> String {
        do {
            guard let urlComponents = URLComponents(string: url) else {
                return generateFallbackFileName()
            }

            let path = urlComponents.path
            let fileName = URL(fileURLWithPath: path).lastPathComponent

            if !fileName.isEmpty && fileName.contains(".") {
                return fileName
            } else {
                return generateFallbackFileName()
            }
        } catch {
            return generateFallbackFileName()
        }
    }

    /// Alternative method using URL class
    static func extractFileNameUsingURL(from urlString: String) -> String {
        guard let url = URL(string: urlString) else {
            return generateFallbackFileName()
        }

        let fileName = url.lastPathComponent

        if !fileName.isEmpty && fileName.contains(".") && fileName != "/" {
            return fileName
        } else {
            return generateFallbackFileName()
        }
    }

    /// Generates a fallback filename with timestamp
    private static func generateFallbackFileName() -> String {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        return "download_\(timestamp).tmp"
    }

    /// Checks if URL is an HLS stream
    static func isHlsUrl(_ url: String) -> Bool {
        return url.lowercased().hasSuffix(".m3u8")
    }

    /// Checks if URL is a video file
    static func isVideoUrl(_ url: String) -> Bool {
        let videoExtensions = [".mp4", ".avi", ".mov", ".mkv", ".webm", ".flv", ".wmv", ".m4v"]
        let lowercasedUrl = url.lowercased()
        return videoExtensions.contains { lowercasedUrl.hasSuffix($0) }
    }

    /// Checks if URL is an audio file
    static func isAudioUrl(_ url: String) -> Bool {
        let audioExtensions = [".mp3", ".wav", ".aac", ".flac", ".ogg", ".m4a", ".wma"]
        let lowercasedUrl = url.lowercased()
        return audioExtensions.contains { lowercasedUrl.hasSuffix($0) }
    }

    /// Creates directory if it doesn't exist
    static func createDirectoryIfNotExists(at path: String) -> Bool {
        do {
            let url = URL(fileURLWithPath: path)

            if !FileManager.default.fileExists(atPath: path) {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
            return true
        } catch {
            print("Failed to create directory at \(path): \(error.localizedDescription)")
            return false
        }
    }

    /// Creates directory for file path (creates parent directory)
    static func createDirectoryForFile(at filePath: String) -> Bool {
        let fileURL = URL(fileURLWithPath: filePath)
        let directoryURL = fileURL.deletingLastPathComponent()
        return createDirectoryIfNotExists(at: directoryURL.path)
    }

    /// Formats bytes into human readable format
    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var size = Double(bytes)
        var unitIndex = 0

        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return String(format: "%.0f %@", size, units[unitIndex])
        } else {
            return String(format: "%.2f %@", size, units[unitIndex])
        }
    }

    /// Formats speed (bytes per second) into human readable format
    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        return "\(formatBytes(Int64(bytesPerSecond)))/s"
    }

    /// Calculates estimated time of arrival based on remaining bytes and speed
    static func calculateETA(remainingBytes: Int64, speedBytesPerSecond: Double) -> String {
        guard speedBytesPerSecond > 0 else { return "Unknown" }

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

    /// More detailed ETA calculation with different time units
    static func calculateDetailedETA(remainingBytes: Int64, speedBytesPerSecond: Double) -> String {
        guard speedBytesPerSecond > 0 else { return "Unknown" }

        let remainingSeconds = Double(remainingBytes) / speedBytesPerSecond

        switch remainingSeconds {
        case let x where x < 60:
            return "\(Int(x))s"
        case let x where x < 3600:
            let minutes = Int(x / 60)
            return "\(minutes)m"
        case let x where x < 86400:
            let hours = Int(x / 3600)
            let minutes = Int((x.truncatingRemainder(dividingBy: 3600)) / 60)
            return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        default:
            let days = Int(remainingSeconds / 86400)
            let hours = Int((remainingSeconds.truncatingRemainder(dividingBy: 86400)) / 3600)
            return "\(days)d \(hours)h"
        }
    }

    /// Validates if URL is properly formatted
    static func isValidUrl(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return url.scheme != nil && url.host != nil
    }

    /// Extracts file extension from URL
    static func extractFileExtension(from url: String) -> String? {
        let fileName = extractFileName(from: url)
        let components = fileName.components(separatedBy: ".")
        return components.count > 1 ? components.last : nil
    }

    /// Gets MIME type from file extension
    static func getMimeType(for fileExtension: String) -> String {
        let lowercasedExt = fileExtension.lowercased()

        switch lowercasedExt {
        // Video
        case "mp4": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "flv": return "video/x-flv"
        case "wmv": return "video/x-ms-wmv"
        case "m4v": return "video/x-m4v"

        // Audio
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "m4a": return "audio/mp4"
        case "wma": return "audio/x-ms-wma"

        // HLS
        case "m3u8": return "application/vnd.apple.mpegurl"

        // Images
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "webp": return "image/webp"

        // Documents
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

        // Archives
        case "zip": return "application/zip"
        case "rar": return "application/vnd.rar"
        case "7z": return "application/x-7z-compressed"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"

        default: return "application/octet-stream"
        }
    }

    /// Checks if file exists at path
    static func fileExists(at path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    /// Gets file size at path
    static func getFileSize(at path: String) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return attributes[.size] as? Int64
        } catch {
            return nil
        }
    }

    /// Deletes file at path
    static func deleteFile(at path: String) -> Bool {
        do {
            if fileExists(at: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            return true
        } catch {
            print("Failed to delete file at \(path): \(error.localizedDescription)")
            return false
        }
    }

    /// Gets available disk space
    static func getAvailableDiskSpace() -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            return attributes[.systemFreeSize] as? Int64
        } catch {
            return nil
        }
    }

    /// Checks if there's enough disk space for download
    static func hasEnoughDiskSpace(requiredBytes: Int64, bufferPercentage: Double = 0.1) -> Bool {
        guard let availableSpace = getAvailableDiskSpace() else { return false }
        let bufferSpace = Int64(Double(requiredBytes) * bufferPercentage)
        return availableSpace > (requiredBytes + bufferSpace)
    }

    /// Sanitizes filename by removing invalid characters
    static func sanitizeFileName(_ fileName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let sanitized = fileName.components(separatedBy: invalidCharacters).joined(separator: "_")

        // Trim whitespace and ensure it's not empty
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    /// Creates unique filename if file already exists
    static func createUniqueFileName(at directoryPath: String, baseName: String, extension: String) -> String {
        let fileManager = FileManager.default
        var counter = 0
        var fileName = "\(baseName).\(`extension`)"
        var fullPath = URL(fileURLWithPath: directoryPath).appendingPathComponent(fileName).path

        while fileManager.fileExists(atPath: fullPath) {
            counter += 1
            fileName = "\(baseName)_\(counter).\(`extension`)"
            fullPath = URL(fileURLWithPath: directoryPath).appendingPathComponent(fileName).path
        }

        return fileName
    }
}

// MARK: - Extensions for convenience
extension DownloadUtils {

    /// Format progress percentage
    static func formatProgress(_ progress: Double) -> String {
        return String(format: "%.1f%%", progress)
    }

    /// Format download ratio (downloaded/total)
    static func formatDownloadRatio(downloaded: Int64, total: Int64) -> String {
        if total > 0 {
            return "\(formatBytes(downloaded)) / \(formatBytes(total))"
        } else {
            return formatBytes(downloaded)
        }
    }

    /// Check if download is resumable (based on file extension and type)
    static func isResumableDownload(_ url: String) -> Bool {
        // HLS streams are generally not resumable in the traditional sense
        if isHlsUrl(url) {
            return false
        }

        // Most HTTP downloads can be resumed if server supports range requests
        return isValidUrl(url) && (url.hasPrefix("http://") || url.hasPrefix("https://"))
    }

    /// Generate download summary
    static func generateDownloadSummary(
        fileName: String,
        totalBytes: Int64,
        downloadedBytes: Int64,
        speed: Double,
        status: DownloadStatus
    ) -> String {
        let progress = totalBytes > 0 ? (Double(downloadedBytes) / Double(totalBytes)) * 100 : 0
        let progressString = formatProgress(progress)
        let ratioString = formatDownloadRatio(downloaded: downloadedBytes, total: totalBytes)
        let speedString = formatSpeed(speed)
        let etaString = calculateETA(remainingBytes: totalBytes - downloadedBytes, speedBytesPerSecond: speed)

        return """
        File: \(fileName)
        Progress: \(progressString)
        Downloaded: \(ratioString)
        Speed: \(speedString)
        ETA: \(etaString)
        Status: \(status.stringValue)
        """
    }
}