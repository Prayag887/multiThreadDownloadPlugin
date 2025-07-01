package com.example.multithread_downloads

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max

class ParallelDownloadManager {
    private val downloads = ConcurrentHashMap<String, DownloadTask>()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var batchJob: Job? = null

    // Add batch completion callback
    private var onBatchComplete: (() -> Unit)? = null

    private val httpsDownloader = HttpsDownloader()
    private val hlsDownloader = HighPerformanceHlsDownloader()

    fun startBatchDownload(
        urls: List<String>,
        basePath: String,
        headers: Map<String, String>,
        maxConcurrentTasks: Int,
        retryCount: Int,
        timeoutSeconds: Int,
        onProgress: (Map<String, Any>) -> Unit,
        onBatchComplete: (() -> Unit)? = null
    ) {
        // Cancel any existing batch
        batchJob?.cancel()

        // Clear previous downloads if batch is complete or no active downloads
        if (isReadyForNewBatch()) {
            clearCompletedDownloads()
        }

        // Store the batch completion callback
        this.onBatchComplete = onBatchComplete

        urls.forEach { url ->
            val fileName = extractFileName(url)
            val fullPath = File(basePath, fileName).absolutePath
            val task = DownloadTask(url, fullPath, fileName, headers, retryCount, timeoutSeconds)
            downloads[url] = task
        }

        batchJob = scope.launch {
            val taskSemaphore = Semaphore(maxConcurrentTasks)

            val downloadJobs = urls.map { url ->
                async {
                    taskSemaphore.withPermit {
                        downloads[url]?.let { task ->
                            try {
                                if (task.url.endsWith(".m3u8", ignoreCase = true)) {
                                    hlsDownloader.downloadHlsStreamAdvanced(task, basePath, onProgress)
                                } else {
                                    httpsDownloader.downloadSingleFile(task, onProgress)
                                }
                            } catch (e: Exception) {
                                task.status = DownloadStatus.FAILED
                                task.error = e.message
                                sendProgress(task, onProgress)
                            }
                        }
                    }
                }
            }

            downloadJobs.awaitAll()
            sendBatchProgress(onProgress)

            // Notify batch completion
            this@ParallelDownloadManager.onBatchComplete?.invoke()
            this@ParallelDownloadManager.onBatchComplete = null
        }
    }

    // Check if batch is complete
    fun isBatchComplete(): Boolean {
        if (downloads.isEmpty()) return true

        val allTasks = downloads.values.toList()
        val totalTasks = allTasks.size
        val completedTasks = allTasks.count {
            it.status == DownloadStatus.COMPLETED ||
                    it.status == DownloadStatus.FAILED ||
                    it.status == DownloadStatus.CANCELLED
        }

        return completedTasks >= totalTasks
    }

    // This function is now being used properly
    fun isReadyForNewBatch(): Boolean {
        val jobNotActive = batchJob?.isActive != true
        val noActiveDownloads = downloads.values.none {
            it.status == DownloadStatus.DOWNLOADING || it.status == DownloadStatus.INITIALIZING
        }
        return jobNotActive && (downloads.isEmpty() || (isBatchComplete() && noActiveDownloads))
    }

    // Check if batch is actively downloading
    fun isBatchActive(): Boolean {
        val jobActive = batchJob?.isActive == true
        val hasActiveDownloads = downloads.values.any {
            it.status == DownloadStatus.DOWNLOADING || it.status == DownloadStatus.INITIALIZING
        }
        return jobActive && hasActiveDownloads
    }

    private fun extractFileName(url: String): String {
        return try {
            val uri = java.net.URI(url)
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

    private fun sendBatchProgress(onProgress: (Map<String, Any>) -> Unit) {
        val batchProgress = getBatchProgress()
        batchProgress?.let { progress ->
            onProgress(progress + ("isBatchProgress" to true))
        }
    }

    // Rest of the methods remain the same...
    fun pauseDownload(url: String): Boolean {
        return downloads[url]?.let { task ->
            if (task.status == DownloadStatus.DOWNLOADING) {
                task.status = DownloadStatus.PAUSED
                task.job?.cancel()
                true
            } else false
        } ?: false
    }

    fun resumeDownload(url: String, onProgress: (Map<String, Any>) -> Unit) {
        downloads[url]?.let { task ->
            if (task.status == DownloadStatus.PAUSED) {
                task.speedHistory.clear()
                task.job = scope.launch {
                    try {
                        if (task.url.endsWith(".m3u8", ignoreCase = true)) {
                            val basePath = File(task.filePath).parent ?: ""
                            hlsDownloader.downloadHlsStreamAdvanced(task, basePath, onProgress)
                        } else {
                            httpsDownloader.downloadSingleFile(task, onProgress)
                        }
                    } catch (e: Exception) {
                        task.status = DownloadStatus.FAILED
                        task.error = e.message
                        sendProgress(task, onProgress)
                    }
                }
            }
        }
    }

    fun cancelDownload(url: String): Boolean {
        return downloads[url]?.let { task ->
            task.status = DownloadStatus.CANCELLED
            task.job?.cancel()
            File(task.filePath).delete()
            downloads.remove(url)
            true
        } ?: false
    }

    fun pauseAllDownloads(): Boolean {
        var hasActive = false
        downloads.values.forEach { task ->
            if (task.status == DownloadStatus.DOWNLOADING) {
                task.status = DownloadStatus.PAUSED
                task.job?.cancel()
                hasActive = true
            }
        }
        batchJob?.cancel()
        return hasActive
    }

    fun resumeAllDownloads(onProgress: (Map<String, Any>) -> Unit) {
        val pausedTasks = downloads.values.filter { it.status == DownloadStatus.PAUSED }
        if (pausedTasks.isNotEmpty()) {
            pausedTasks.forEach { task ->
                task.speedHistory.clear()
                task.job = scope.launch {
                    try {
                        if (task.url.endsWith(".m3u8", ignoreCase = true)) {
                            val basePath = File(task.filePath).parent ?: ""
                            hlsDownloader.downloadHlsStreamAdvanced(task, basePath, onProgress)
                        } else {
                            httpsDownloader.downloadSingleFile(task, onProgress)
                        }
                    } catch (e: Exception) {
                        task.status = DownloadStatus.FAILED
                        task.error = e.message
                        sendProgress(task, onProgress)
                    }
                }
            }
        }
    }

    fun cancelAllDownloads(): Boolean {
        batchJob?.cancel()
        onBatchComplete = null
        downloads.values.forEach { task ->
            task.status = DownloadStatus.CANCELLED
            task.job?.cancel()
            File(task.filePath).delete()
        }
        downloads.clear()
        return true
    }

    fun pauseDownloads(urls: List<String>): Boolean {
        var hasActive = false
        urls.forEach { url ->
            downloads[url]?.let { task ->
                if (task.status == DownloadStatus.DOWNLOADING) {
                    task.status = DownloadStatus.PAUSED
                    task.job?.cancel()
                    hasActive = true
                }
            }
        }
        return hasActive
    }

    fun resumeDownloads(urls: List<String>, onProgress: (Map<String, Any>) -> Unit) {
        urls.forEach { url ->
            downloads[url]?.let { task ->
                if (task.status == DownloadStatus.PAUSED) {
                    task.speedHistory.clear()
                    task.job = scope.launch {
                        try {
                            if (task.url.endsWith(".m3u8", ignoreCase = true)) {
                                val basePath = File(task.filePath).parent ?: ""
                                hlsDownloader.downloadHlsStreamAdvanced(task, basePath, onProgress)
                            } else {
                                httpsDownloader.downloadSingleFile(task, onProgress)
                            }
                        } catch (e: Exception) {
                            task.status = DownloadStatus.FAILED
                            task.error = e.message
                            sendProgress(task, onProgress)
                        }
                    }
                }
            }
        }
    }

    fun cancelDownloads(urls: List<String>): Boolean {
        var hasActive = false
        urls.forEach { url ->
            downloads[url]?.let { task ->
                task.status = DownloadStatus.CANCELLED
                task.job?.cancel()
                File(task.filePath).delete()
                downloads.remove(url)
                hasActive = true
            }
        }
        return hasActive
    }

    fun getDownloadStatus(url: String): Map<String, Any>? {
        return downloads[url]?.let { task ->
            val currentTime = System.currentTimeMillis()
            val timeElapsed = max(1L, currentTime - task.startTime)
            val avgSpeed = if (task.speedHistory.isNotEmpty()) {
                task.speedHistory.average()
            } else {
                (task.downloadedBytes * 1000.0 / timeElapsed)
            }
            val progress = if (task.totalBytes > 0) {
                (task.downloadedBytes * 100.0 / task.totalBytes).toInt()
            } else 0

            mapOf(
                "url" to task.url,
                "filePath" to task.filePath,
                "progress" to progress,
                "bytesDownloaded" to task.downloadedBytes,
                "totalBytes" to task.totalBytes,
                "status" to task.status.value,
                "error" to (task.error ?: ""),
                "speed" to avgSpeed
            )
        }
    }

    fun getDownloadStatuses(urls: List<String>): List<Map<String, Any>> {
        return urls.mapNotNull { getDownloadStatus(it) }
    }

    fun getBatchProgress(): Map<String, Any>? {
        if (downloads.isEmpty()) return null

        val allTasks = downloads.values.toList()
        val totalBytes = allTasks.sumOf { it.totalBytes }
        val downloadedBytes = allTasks.sumOf { it.downloadedBytes }
        val completedCount = allTasks.count { it.status == DownloadStatus.COMPLETED }
        val failedCount = allTasks.count { it.status == DownloadStatus.FAILED }
        val cancelledCount = allTasks.count { it.status == DownloadStatus.CANCELLED }
        val activeCount = allTasks.count { it.status == DownloadStatus.DOWNLOADING }
        val pausedCount = allTasks.count { it.status == DownloadStatus.PAUSED }

        val overallProgress = if (totalBytes > 0) {
            (downloadedBytes * 100.0 / totalBytes).toInt()
        } else 0

        val averageSpeed = allTasks
            .filter { it.speedHistory.isNotEmpty() }
            .map { it.speedHistory.average() }
            .takeIf { it.isNotEmpty() }
            ?.average() ?: 0.0

        return mapOf(
            "urls" to allTasks.map { it.url },
            "overallProgress" to overallProgress,
            "totalBytesDownloaded" to downloadedBytes,
            "totalBytes" to totalBytes,
            "completedDownloads" to completedCount,
            "failedDownloads" to failedCount,
            "cancelledDownloads" to cancelledCount,
            "activeDownloads" to activeCount,
            "pausedDownloads" to pausedCount,
            "totalDownloads" to allTasks.size,
            "averageSpeed" to averageSpeed,
            "isComplete" to isBatchComplete(),
            "isReadyForNewBatch" to isReadyForNewBatch(),
            "individualProgress" to allTasks.map { task ->
                mapOf(
                    "url" to task.url,
                    "progress" to if (task.totalBytes > 0) (task.downloadedBytes * 100.0 / task.totalBytes).toInt() else 0,
                    "status" to task.status.value,
                    "speed" to if (task.speedHistory.isNotEmpty()) task.speedHistory.average() else 0.0
                )
            }
        )
    }

    fun getAllDownloads(): List<Map<String, Any>> = downloads.values.mapNotNull { getDownloadStatus(it.url) }

    fun clearCompletedDownloads(): Boolean {
        downloads.entries.removeAll { it.value.status == DownloadStatus.COMPLETED }
        return true
    }
}