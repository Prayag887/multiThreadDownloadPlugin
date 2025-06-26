package com.example.multithread_downloads

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.offline.DefaultDownloadIndex
import androidx.media3.exoplayer.offline.DefaultDownloaderFactory
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadRequest
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.Requirements
import kotlinx.coroutines.*
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import kotlin.math.max

data class M3u8DownloadTask(
    val url: String,
    val filePath: String,
    val fileName: String,
    val headers: Map<String, String>,
    var totalBytes: Long = 0,
    var downloadedBytes: Long = 0,
    var status: M3u8DownloadStatus = M3u8DownloadStatus.PENDING,
    var error: String? = null,
    var startTime: Long = 0,
    var downloadRequest: DownloadRequest? = null,
    var segmentCount: Int = 0,
    var downloadedSegments: Int = 0,
    var speedHistory: MutableList<Double> = mutableListOf()
)

enum class M3u8DownloadStatus(val value: Int) {
    PENDING(0), DOWNLOADING(1), PAUSED(2), COMPLETED(3), FAILED(4), CANCELLED(5)
}

@UnstableApi
class ExoPlayerDownloadManager {
    private val downloads = ConcurrentHashMap<String, M3u8DownloadTask>()
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val progressCallbacks = ConcurrentHashMap<String, (Map<String, Any>) -> Unit>()

    private var downloadManager: DownloadManager? = null
    private var simpleCache: SimpleCache? = null
    private var context: Context? = null

    fun initialize(context: Context) {
        this.context = context
        setupDownloadManager(context)
    }

    private fun setupDownloadManager(context: Context) {
        try {
            // Create cache directory
            val cacheDir = File(context.cacheDir, "exoplayer_cache")
            if (!cacheDir.exists()) {
                cacheDir.mkdirs()
            }

            // Create database provider
            val databaseProvider = StandaloneDatabaseProvider(context)

            // Create cache
            simpleCache = SimpleCache(
                cacheDir,
                NoOpCacheEvictor(),
                databaseProvider
            )

            // Create data source factory with custom headers support
            val httpDataSourceFactory = DefaultHttpDataSource.Factory()
                .setUserAgent("ExoPlayer-M3U8-Downloader")
                .setConnectTimeoutMs(30000)
                .setReadTimeoutMs(30000)

            val cacheDataSourceFactory = CacheDataSource.Factory()
                .setCache(simpleCache!!)
                .setUpstreamDataSourceFactory(httpDataSourceFactory)

            // Create download index
            val downloadIndex = DefaultDownloadIndex(databaseProvider)

            // Create download manager
            downloadManager = DownloadManager(
                context,
                downloadIndex,
                DefaultDownloaderFactory(cacheDataSourceFactory, Executor { it.run() })
            ).apply {
                requirements = Requirements(Requirements.NETWORK)
                maxParallelDownloads = 3
                minRetryCount = 3

                // Add download listener
                addListener(object : DownloadManager.Listener {
                    override fun onDownloadChanged(
                        downloadManager: DownloadManager,
                        download: Download,
                        finalException: Exception?
                    ) {
                        handleDownloadChanged(download, finalException)
                    }
                })
            }

        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun handleDownloadChanged(download: Download, finalException: Exception?) {
        val url = download.request.uri.toString()
        val task = downloads[url] ?: return

        when (download.state) {
            Download.STATE_QUEUED -> {
                task.status = M3u8DownloadStatus.PENDING
            }
            Download.STATE_DOWNLOADING -> {
                task.status = M3u8DownloadStatus.DOWNLOADING
                task.downloadedBytes = download.bytesDownloaded
                updateProgress(task)
            }
            Download.STATE_COMPLETED -> {
                task.status = M3u8DownloadStatus.COMPLETED
                task.downloadedBytes = download.bytesDownloaded
                updateProgress(task)
            }
            Download.STATE_FAILED -> {
                task.status = M3u8DownloadStatus.FAILED
                task.error = finalException?.message ?: "Download failed"
                updateProgress(task)
            }
            Download.STATE_STOPPED -> {
                task.status = M3u8DownloadStatus.PAUSED
                updateProgress(task)
            }
        }
    }

    fun startDownload(
        url: String,
        filePath: String,
        headers: Map<String, String>,
        onProgress: (Map<String, Any>) -> Unit
    ) {
        if (downloadManager == null) {
            throw IllegalStateException("ExoPlayerDownloadManager not initialized")
        }

        val fileName = extractFileName(url)
        val task = M3u8DownloadTask(
            url = url,
            filePath = filePath,
            fileName = fileName,
            headers = headers,
            startTime = System.currentTimeMillis()
        )

        downloads[url] = task
        progressCallbacks[url] = onProgress

        // Create download request
        val downloadRequest = DownloadRequest.Builder(url, android.net.Uri.parse(url))
            .setStreamKeys(emptyList())
            .setCustomCacheKey("asd")
            .setData(filePath.toByteArray())
            .build()

        task.downloadRequest = downloadRequest

        // Start download
        downloadManager?.addDownload(downloadRequest)

        // Update initial progress
        updateProgress(task)
    }

    private fun updateProgress(task: M3u8DownloadTask) {
        val currentTime = System.currentTimeMillis()
        val timeElapsed = max(1L, currentTime - task.startTime)

        // Calculate speed
        val speed = if (timeElapsed > 0 && task.downloadedBytes > 0) {
            (task.downloadedBytes * 1000.0 / timeElapsed)
        } else 0.0

        // Update speed history
        task.speedHistory.add(speed)
        if (task.speedHistory.size > 10) {
            task.speedHistory.removeAt(0)
        }

        val avgSpeed = if (task.speedHistory.isNotEmpty()) {
            task.speedHistory.average()
        } else speed

        val progress = if (task.totalBytes > 0) {
            (task.downloadedBytes * 100.0 / task.totalBytes).toInt()
        } else -1

        val progressData = mapOf(
            "type" to "m3u8",
            "url" to task.url,
            "filePath" to task.filePath,
            "progress" to progress,
            "bytesDownloaded" to task.downloadedBytes,
            "totalBytes" to task.totalBytes,
            "status" to task.status.value,
            "error" to (task.error ?: ""),
            "speed" to avgSpeed,
            "segmentCount" to task.segmentCount,
            "downloadedSegments" to task.downloadedSegments
        )

        progressCallbacks[task.url]?.invoke(progressData)
    }

    fun pauseDownload(url: String): Boolean {
        return try {
            downloads[url]?.let { task ->
                if (task.status == M3u8DownloadStatus.DOWNLOADING) {
                    task.downloadRequest?.let { request ->
                        downloadManager?.removeDownload(request.id)
                        task.status = M3u8DownloadStatus.PAUSED
                        updateProgress(task)
                        true
                    } ?: false
                } else false
            } ?: false
        } catch (e: Exception) {
            false
        }
    }

    fun resumeDownload(url: String, onProgress: (Map<String, Any>) -> Unit): Boolean {
        return try {
            downloads[url]?.let { task ->
                if (task.status == M3u8DownloadStatus.PAUSED) {
                    task.downloadRequest?.let { request ->
                        progressCallbacks[url] = onProgress
                        downloadManager?.addDownload(request)
                        task.status = M3u8DownloadStatus.DOWNLOADING
                        updateProgress(task)
                        true
                    } ?: false
                } else false
            } ?: false
        } catch (e: Exception) {
            false
        }
    }

    fun cancelDownload(url: String): Boolean {
        return try {
            downloads[url]?.let { task ->
                task.downloadRequest?.let { request ->
                    downloadManager?.removeDownload(request.id)
                    task.status = M3u8DownloadStatus.CANCELLED

                    // Clean up cache for this download
                    scope.launch {
                        try {
                            simpleCache?.removeResource(request.uri.toString())
                        } catch (e: Exception) {
                            e.printStackTrace()
                        }
                    }

                    downloads.remove(url)
                    progressCallbacks.remove(url)
                    updateProgress(task)
                    true
                } ?: false
            } ?: false
        } catch (e: Exception) {
            false
        }
    }

    fun cancelAllDownloads(): Boolean {
        return try {
            downloads.keys.toList().forEach { url ->
                cancelDownload(url)
            }
            true
        } catch (e: Exception) {
            false
        }
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
                "type" to "m3u8",
                "url" to task.url,
                "filePath" to task.filePath,
                "progress" to progress,
                "bytesDownloaded" to task.downloadedBytes,
                "totalBytes" to task.totalBytes,
                "status" to task.status.value,
                "error" to (task.error ?: ""),
                "speed" to avgSpeed,
                "segmentCount" to task.segmentCount,
                "downloadedSegments" to task.downloadedSegments
            )
        }
    }

    fun getAllDownloads(): List<Map<String, Any>> {
        return downloads.values.mapNotNull { task ->
            getDownloadStatus(task.url)
        }
    }

    fun clearCompletedDownloads(): Boolean {
        return try {
            val completedUrls = downloads.filter { it.value.status == M3u8DownloadStatus.COMPLETED }.keys
            completedUrls.forEach { url ->
                downloads.remove(url)
                progressCallbacks.remove(url)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun extractFileName(url: String): String {
        return try {
            val uri = java.net.URI(url)
            val path = uri.path
            val fileName = path.substringAfterLast('/')
            if (fileName.isNotEmpty()) {
                // Remove .m3u8 extension and add .mp4
                val baseName = fileName.substringBeforeLast('.')
                "$baseName.mp4"
            } else {
                "m3u8_download_${System.currentTimeMillis()}.mp4"
            }
        } catch (e: Exception) {
            "m3u8_download_${System.currentTimeMillis()}.mp4"
        }
    }

    fun cleanup() {
        try {
            downloadManager?.release()
            simpleCache?.release()
            scope.cancel()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}