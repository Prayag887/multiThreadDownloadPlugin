package com.example.multithread_downloads

import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream
import kotlin.math.max

class HttpsDownloader {

    suspend fun downloadSingleFile(
        task: DownloadTask,
        onProgress: (Map<String, Any>) -> Unit
    ) {
        val file = File(task.filePath).apply { parentFile?.mkdirs() }
        task.downloadedBytes = if (file.exists()) file.length() else 0L

        task.status = DownloadStatus.DOWNLOADING
        task.startTime = System.currentTimeMillis()
        task.lastSpeedUpdate = task.startTime

        val totalBytes = getFileSize(task)
        task.totalBytes = totalBytes
        sendProgress(task, onProgress)

        repeat(task.retryCount + 1) { attempt ->
            if (task.status != DownloadStatus.DOWNLOADING) return

            try {
                val request = HttpClientConfig.buildRequest(task.url, task.headers, task.downloadedBytes)
                HttpClientConfig.client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful && response.code != 206) {
                        throw Exception("HTTP ${response.code}: ${response.message}")
                    }

                    val body = response.body!!
                    if (task.totalBytes <= 0) {
                        response.header("Content-Length")?.toLongOrNull()?.let {
                            task.totalBytes = it + task.downloadedBytes
                        }
                    }

                    val outputStream = if (task.downloadedBytes > 0) {
                        FileOutputStream(task.filePath, true)
                    } else {
                        FileOutputStream(task.filePath, false)
                    }

                    outputStream.use { output ->
                        val buffer = ByteArray(32768) // Larger buffer for better performance
                        var lastUpdate = 0L
                        var bytesInInterval = 0L

                        body.byteStream().use { input ->
                            var bytesRead: Int
                            while (input.read(buffer).also { bytesRead = it } != -1 &&
                                task.status == DownloadStatus.DOWNLOADING) {

                                output.write(buffer, 0, bytesRead)
                                task.downloadedBytes += bytesRead
                                bytesInInterval += bytesRead

                                val now = System.currentTimeMillis()
                                if (now - lastUpdate > 1000) {
                                    updateSpeedHistory(task, bytesInInterval, now - lastUpdate)
                                    sendProgress(task, onProgress)
                                    lastUpdate = now
                                    bytesInInterval = 0L
                                }
                            }
                        }
                    }

                    if (task.status == DownloadStatus.DOWNLOADING) {
                        task.status = DownloadStatus.COMPLETED
                        sendProgress(task, onProgress)
                    }
                    return
                }
            } catch (e: Exception) {
                if (attempt == task.retryCount) {
                    task.status = DownloadStatus.FAILED
                    task.error = e.message
                    throw e
                }
                delay((500L * (1 shl attempt)) + (0..500).random())
            }
        }
    }

    private suspend fun getFileSize(task: DownloadTask): Long {
        return try {
            val request = HttpClientConfig.buildRequest(task.url, task.headers)
            HttpClientConfig.client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return -1L
                response.header("Content-Length")?.toLongOrNull() ?: -1L
            }
        } catch (e: Exception) {
            -1L
        }
    }

    private fun updateSpeedHistory(task: DownloadTask, bytes: Long, timeMs: Long) {
        val speed = if (timeMs > 0) (bytes * 1000.0 / timeMs) else 0.0
        task.speedHistory.add(speed)
        if (task.speedHistory.size > 10) {
            task.speedHistory.removeAt(0)
        }
    }

    private fun sendProgress(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
        val currentTime = System.currentTimeMillis()
        val timeElapsed = max(1L, currentTime - task.startTime)

        val avgSpeed = if (task.speedHistory.isNotEmpty()) {
            task.speedHistory.average()
        } else {
            (task.downloadedBytes * 1000.0 / timeElapsed)
        }

        val progress = if (task.totalBytes > 0) {
            (task.downloadedBytes * 100.0 / task.totalBytes).toInt()
        } else -1

        onProgress(mapOf(
            "url" to task.url,
            "filePath" to task.filePath,
            "progress" to progress,
            "bytesDownloaded" to task.downloadedBytes,
            "totalBytes" to task.totalBytes,
            "status" to task.status.value,
            "error" to (task.error ?: ""),
            "speed" to avgSpeed
        ))
    }
}