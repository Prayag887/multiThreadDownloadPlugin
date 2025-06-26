package com.example.multithread_downloads

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.*
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.math.max

class MultithreadDownloadsPlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val downloadManager = ParallelDownloadManager()

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "multithread_downloads")
    eventChannel = EventChannel(binding.binaryMessenger, "multithread_downloads/progress")
    channel.setMethodCallHandler(this)
    eventChannel.setStreamHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "startDownload" -> {
        val urls = call.argument<List<String>>("urls") ?: emptyList()
        downloadManager.startBatchDownload(
          urls,
          call.argument<String>("filePath")!!,
          call.argument<Map<String, String>>("headers") ?: emptyMap(),
          call.argument<Int>("maxConcurrentTasks") ?: 4,
          call.argument<Int>("retryCount") ?: 3,
          call.argument<Int>("timeoutSeconds") ?: 30
        ) { sendProgress(it) }
        result.success(true)
      }
      "pauseDownload" -> result.success(downloadManager.pauseDownload(call.argument<String>("url")!!))
      "resumeDownload" -> {
        val url = call.argument<String>("url")!!
        downloadManager.resumeDownload(url) { sendProgress(it) }
        result.success(true)
      }
      "cancelDownload" -> result.success(downloadManager.cancelDownload(call.argument<String>("url")!!))
      "pauseAllDownloads" -> result.success(downloadManager.pauseAllDownloads())
      "resumeAllDownloads" -> {
        downloadManager.resumeAllDownloads() { sendProgress(it) }
        result.success(true)
      }
      "cancelAllDownloads" -> result.success(downloadManager.cancelAllDownloads())
      "pauseDownloads" -> {
        val urls = call.argument<List<String>>("urls") ?: emptyList()
        result.success(downloadManager.pauseDownloads(urls))
      }
      "resumeDownloads" -> {
        val urls = call.argument<List<String>>("urls") ?: emptyList()
        downloadManager.resumeDownloads(urls) { sendProgress(it) }
        result.success(true)
      }
      "cancelDownloads" -> {
        val urls = call.argument<List<String>>("urls") ?: emptyList()
        result.success(downloadManager.cancelDownloads(urls))
      }
      "getDownloadStatus" -> result.success(downloadManager.getDownloadStatus(call.argument<String>("url")!!))
      "getDownloadStatuses" -> {
        val urls = call.argument<List<String>>("urls") ?: emptyList()
        result.success(downloadManager.getDownloadStatuses(urls))
      }
      "getAllDownloads" -> result.success(downloadManager.getAllDownloads())
      "getBatchProgress" -> result.success(downloadManager.getBatchProgress())
      "clearCompletedDownloads" -> result.success(downloadManager.clearCompletedDownloads())
      else -> result.notImplemented()
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
  override fun onCancel(arguments: Any?) { eventSink = null }

  private fun sendProgress(progress: Map<String, Any>) {
    mainHandler.post { eventSink?.success(progress) }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    downloadManager.cancelAllDownloads()
  }
}

data class DownloadTask(
  val url: String,
  val filePath: String,
  val fileName: String,
  val headers: Map<String, String>,
  val retryCount: Int,
  val timeoutSeconds: Int,
  var totalBytes: Long = 0,
  var downloadedBytes: Long = 0,
  var status: DownloadStatus = DownloadStatus.PENDING,
  var error: String? = null,
  var startTime: Long = 0,
  var lastSpeedUpdate: Long = 0,
  var job: Job? = null,
  var speedHistory: MutableList<Double> = mutableListOf()
)

enum class DownloadStatus(val value: Int) {
  PENDING(0), DOWNLOADING(1), PAUSED(2), COMPLETED(3), FAILED(4), CANCELLED(5)
}

class ParallelDownloadManager {
  private val downloads = ConcurrentHashMap<String, DownloadTask>()
  private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
  private var batchJob: Job? = null

  // HTTP client optimized for parallel downloads
  private val client = OkHttpClient.Builder()
    .connectionPool(ConnectionPool(20, 5, TimeUnit.MINUTES))
    .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1))
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(60, TimeUnit.SECONDS)
    .writeTimeout(60, TimeUnit.SECONDS)
    .retryOnConnectionFailure(true)
    .followRedirects(true)
    .followSslRedirects(true)
    .build()

  fun startBatchDownload(
    urls: List<String>,
    basePath: String,
    headers: Map<String, String>,
    maxConcurrentTasks: Int,
    retryCount: Int,
    timeoutSeconds: Int,
    onProgress: (Map<String, Any>) -> Unit
  ) {
    // Cancel any existing batch download
    batchJob?.cancel()

    // Create download tasks for each URL
    urls.forEach { url ->
      val fileName = extractFileName(url)
      val fullPath = File(basePath, fileName).absolutePath
      val task = DownloadTask(url, fullPath, fileName, headers, retryCount, timeoutSeconds)
      downloads[url] = task
    }

    // Start batch download with controlled concurrency
    batchJob = scope.launch {
      // Use semaphore to limit concurrent downloads
      val semaphore = Semaphore(maxConcurrentTasks)

      val downloadJobs = urls.map { url ->
        async {
          semaphore.withPermit {
            downloads[url]?.let { task ->
              try {
                downloadSingleFile(task, onProgress)
              } catch (e: Exception) {
                task.status = DownloadStatus.FAILED
                task.error = e.message
                sendProgress(task, onProgress)
              }
            }
          }
        }
      }

      // Wait for all downloads to complete
      downloadJobs.awaitAll()

      // Send final batch progress
      sendBatchProgress(onProgress)
    }
  }

  private suspend fun downloadSingleFile(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
    val file = File(task.filePath).apply { parentFile?.mkdirs() }
    task.downloadedBytes = if (file.exists()) file.length() else 0L

    task.status = DownloadStatus.DOWNLOADING
    task.startTime = System.currentTimeMillis()
    task.lastSpeedUpdate = task.startTime

    // Get file info
    val totalBytes = getFileSize(task)
    task.totalBytes = totalBytes

    sendProgress(task, onProgress)

    // Download with retry logic
    repeat(task.retryCount + 1) { attempt ->
      if (task.status != DownloadStatus.DOWNLOADING) return

      try {
        val request = buildRequest(task.url, task.headers, task.downloadedBytes)
        client.newCall(request).execute().use { response ->
          if (!response.isSuccessful && response.code != 206) {
            throw Exception("HTTP ${response.code}: ${response.message}")
          }

          val body = response.body!!
          if (task.totalBytes <= 0) {
            response.header("Content-Length")?.toLongOrNull()?.let {
              task.totalBytes = it + task.downloadedBytes
            }
          }

          // Download the file
          val outputStream = if (task.downloadedBytes > 0) {
            FileOutputStream(task.filePath, true) // Append mode for resume
          } else {
            FileOutputStream(task.filePath, false) // Overwrite mode for new download
          }

          outputStream.use { output ->
            val buffer = ByteArray(16384) // 16KB buffer
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
                if (now - lastUpdate > 1000) { // Update every second
                  updateSpeedHistory(task, bytesInInterval, now - lastUpdate)
                  sendProgress(task, onProgress)
                  sendBatchProgress(onProgress)
                  lastUpdate = now
                  bytesInInterval = 0L
                }
              }
            }
          }

          if (task.status == DownloadStatus.DOWNLOADING) {
            task.status = DownloadStatus.COMPLETED
            sendProgress(task, onProgress)
            sendBatchProgress(onProgress)
          }
          return
        }
      } catch (e: Exception) {
        if (attempt == task.retryCount) {
          task.status = DownloadStatus.FAILED
          task.error = e.message
          throw e
        }

        // Exponential backoff with jitter
        val backoffDelay = (1000L * (1 shl attempt)) + (0..1000).random()
        delay(backoffDelay)
      }
    }
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

  private suspend fun getFileSize(task: DownloadTask): Long {
    return try {
      val request = buildRequest(task.url, task.headers)
      client.newCall(request).execute().use { response ->
        if (!response.isSuccessful) return -1L
        val size = response.header("Content-Length")?.toLongOrNull() ?: -1L
        response.close()
        size
      }
    } catch (e: Exception) {
      -1L
    }
  }

  private fun buildRequest(
    url: String,
    headers: Map<String, String>,
    startByte: Long = 0
  ): Request {
    return Request.Builder()
      .url(url)
      .addHeader("User-Agent", "Mozilla/5.0 (Android) AppleWebKit/537.36")
      .addHeader("Accept", "*/*")
      .addHeader("Accept-Encoding", "gzip, deflate")
      .addHeader("Connection", "keep-alive")
      .apply {
        if (startByte > 0) {
          addHeader("Range", "bytes=$startByte-")
        }
        headers.forEach { (key, value) -> addHeader(key, value) }
      }
      .build()
  }

  private fun updateSpeedHistory(task: DownloadTask, bytes: Long, timeMs: Long) {
    val speed = if (timeMs > 0) (bytes * 1000.0 / timeMs) else 0.0
    task.speedHistory.add(speed)

    // Keep only last 10 speed measurements
    if (task.speedHistory.size > 10) {
      task.speedHistory.removeAt(0)
    }
  }

  private fun sendProgress(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
    val currentTime = System.currentTimeMillis()
    val timeElapsed = max(1L, currentTime - task.startTime)

    // Calculate average speed from history
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
        task.speedHistory.clear() // Reset speed history

        task.job = scope.launch {
          try {
            downloadSingleFile(task, onProgress)
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
            downloadSingleFile(task, onProgress)
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
              downloadSingleFile(task, onProgress)
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
      "activeDownloads" to activeCount,
      "pausedDownloads" to pausedCount,
      "totalDownloads" to allTasks.size,
      "averageSpeed" to averageSpeed,
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