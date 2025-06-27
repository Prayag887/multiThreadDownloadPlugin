package com.example.multithread_downloads

import java.io.File
import java.net.URI

object DownloadUtils {

    fun extractFileName(url: String): String {
        return try {
            val uri = URI(url)
            val path = uri.path
            val fileName = path.substringAfterLast('/')
            if (fileName.isNotEmpty() && fileName.contains('.')) {
                fileName
            } else {
                "download_${System.currentTimeMillis()}.tmp"
            }
        } catch (e: Exception) {
            "download_${System.currentTimeMillis()}.tmp"
        }
    }

    fun isHlsUrl(url: String): Boolean {
        return url.endsWith(".m3u8", ignoreCase = true)
    }

    fun createDirectoryIfNotExists(path: String): Boolean {
        return try {
            val directory = File(path)
            if (!directory.exists()) {
                directory.mkdirs()
            } else {
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    fun formatBytes(bytes: Long): String {
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var size = bytes.toDouble()
        var unitIndex = 0

        while (size >= 1024 && unitIndex < units.size - 1) {
            size /= 1024
            unitIndex++
        }

        return String.format("%.2f %s", size, units[unitIndex])
    }

    fun formatSpeed(bytesPerSecond: Double): String {
        return "${formatBytes(bytesPerSecond.toLong())}/s"
    }

    fun calculateETA(remainingBytes: Long, speedBytesPerSecond: Double): String {
        if (speedBytesPerSecond <= 0) return "Unknown"

        val remainingSeconds = (remainingBytes / speedBytesPerSecond).toLong()
        val hours = remainingSeconds / 3600
        val minutes = (remainingSeconds % 3600) / 60
        val seconds = remainingSeconds % 60

        return when {
            hours > 0 -> String.format("%02d:%02d:%02d", hours, minutes, seconds)
            minutes > 0 -> String.format("%02d:%02d", minutes, seconds)
            else -> String.format("00:%02d", seconds)
        }
    }
}