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
import okhttp3.*
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min

class MultithreadDownloadsPlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val downloadManager = AdvancedDownloadManager()

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "multithread_downloads")
    eventChannel = EventChannel(binding.binaryMessenger, "multithread_downloads/progress")
    channel.setMethodCallHandler(this)
    eventChannel.setStreamHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "startDownload" -> {
        downloadManager.startDownload(
          call.argument<String>("url")!!,
          call.argument<String>("filePath")!!,
          call.argument<Map<String, String>>("headers") ?: emptyMap(),
          call.argument<Int>("maxConcurrentTasks") ?: 0, // 0 = auto-detect
          call.argument<Int>("chunkSize") ?: 0, // 0 = auto-detect
          call.argument<Int>("retryCount") ?: 5,
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
      "getDownloadStatus" -> result.success(downloadManager.getDownloadStatus(call.argument<String>("url")!!))
      "getAllDownloads" -> result.success(downloadManager.getAllDownloads())
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
  val headers: Map<String, String>,
  var maxConcurrentTasks: Int,
  var chunkSize: Int,
  val retryCount: Int,
  val timeoutSeconds: Int,
  var totalBytes: Long = 0,
  var downloadedBytes: Long = 0,
  var status: DownloadStatus = DownloadStatus.PENDING,
  var error: String? = null,
  var startTime: Long = 0,
  var lastSpeedUpdate: Long = 0,
  var job: Job? = null,
  var speedHistory: MutableList<Double> = mutableListOf(),
  var connectionHealth: MutableMap<Int, Double> = mutableMapOf()
)

enum class DownloadStatus(val value: Int) {
  PENDING(0), DOWNLOADING(1), PAUSED(2), COMPLETED(3), FAILED(4), CANCELLED(5)
}

class AdvancedDownloadManager {
  private val downloads = ConcurrentHashMap<String, DownloadTask>()
  private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

  // Advanced HTTP client with connection pooling and optimization
  private val client = OkHttpClient.Builder()
    .connectionPool(ConnectionPool(50, 5, TimeUnit.MINUTES))
    .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1))
    .connectTimeout(10, TimeUnit.SECONDS)
    .readTimeout(60, TimeUnit.SECONDS)
    .writeTimeout(60, TimeUnit.SECONDS)
    .retryOnConnectionFailure(true)
    .followRedirects(true)
    .followSslRedirects(true)
    .build()

  fun startDownload(
    url: String, filePath: String, headers: Map<String, String>,
    maxConcurrentTasks: Int, chunkSize: Int, retryCount: Int, timeoutSeconds: Int,
    onProgress: (Map<String, Any>) -> Unit
  ) {
    val task = DownloadTask(url, filePath, headers, maxConcurrentTasks, chunkSize, retryCount, timeoutSeconds)
    downloads[url] = task

    task.job = scope.launch {
      try {
        downloadFile(task, onProgress)
      } catch (e: Exception) {
        task.status = DownloadStatus.FAILED
        task.error = e.message
        sendProgress(task, onProgress)
      }
    }
  }

  private suspend fun downloadFile(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
    val file = File(task.filePath).apply { parentFile?.mkdirs() }
    task.downloadedBytes = if (file.exists()) file.length() else 0L

    task.status = DownloadStatus.DOWNLOADING
    task.startTime = System.currentTimeMillis()
    task.lastSpeedUpdate = task.startTime

    // Get file info and optimize parameters
    val (totalBytes, supportsRanges) = getFileInfo(task)
    task.totalBytes = totalBytes

    // Auto-optimize download parameters
    optimizeDownloadParameters(task)

    sendProgress(task, onProgress)

    if (totalBytes <= 0 || !supportsRanges || totalBytes <= task.chunkSize || task.maxConcurrentTasks <= 1) {
      downloadSingleThreaded(task, onProgress)
    } else {
      downloadMultiThreadedAdvanced(task, onProgress)
    }
  }

  private fun optimizeDownloadParameters(task: DownloadTask) {
    // Auto-detect optimal thread count based on file size
    if (task.maxConcurrentTasks == 0) {
      task.maxConcurrentTasks = getOptimalThreadCount(task.totalBytes)
    }

    // Auto-detect optimal chunk size
    if (task.chunkSize == 0) {
      task.chunkSize = getOptimalChunkSize(task.totalBytes)
    }
  }

  private fun getOptimalThreadCount(fileSize: Long): Int {
    return when {
      fileSize > 500 * 1024 * 1024 -> 16  // 500MB+ -> 16 threads
      fileSize > 100 * 1024 * 1024 -> 12  // 100MB+ -> 12 threads
      fileSize > 50 * 1024 * 1024 -> 8    // 50MB+ -> 8 threads
      fileSize > 10 * 1024 * 1024 -> 6    // 10MB+ -> 6 threads
      fileSize > 1024 * 1024 -> 4         // 1MB+ -> 4 threads
      else -> 1
    }
  }

  private fun getOptimalChunkSize(fileSize: Long): Int {
    return when {
      fileSize > 1024 * 1024 * 1024 -> 4 * 1024 * 1024  // 1GB+ -> 4MB chunks
      fileSize > 100 * 1024 * 1024 -> 2 * 1024 * 1024   // 100MB+ -> 2MB chunks
      fileSize > 10 * 1024 * 1024 -> 1024 * 1024         // 10MB+ -> 1MB chunks
      fileSize > 1024 * 1024 -> 512 * 1024               // 1MB+ -> 512KB chunks
      else -> 256 * 1024                                 // < 1MB -> 256KB chunks
    }
  }

  private suspend fun downloadSingleThreaded(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
    repeat(task.retryCount + 1) { attempt ->
      if (task.status != DownloadStatus.DOWNLOADING) return

      try {
        val request = buildAdvancedRequest(task.url, task.headers, task.downloadedBytes)
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

          // Fixed: Create FileOutputStream properly for append mode
          val outputStream = if (task.downloadedBytes > 0) {
            FileOutputStream(task.filePath, true) // true for append mode
          } else {
            FileOutputStream(task.filePath, false) // false for overwrite mode
          }

          outputStream.use { output ->
            val buffer = ByteArray(16384) // Larger buffer for single thread
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

        // Exponential backoff with jitter
        val backoffDelay = (1000L * (1 shl attempt)) + (0..1000).random()
        delay(backoffDelay)
      }
    }
  }

  private suspend fun downloadMultiThreadedAdvanced(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
    val remainingBytes = task.totalBytes - task.downloadedBytes
    val numThreads = min(task.maxConcurrentTasks, (remainingBytes / task.chunkSize + 1).toInt())

    // Fixed: Use max function with proper Long types
    val dynamicChunkSize = max(task.chunkSize.toLong(), remainingBytes / numThreads)

    RandomAccessFile(task.filePath, "rw").use { raf ->
      val jobs = (0 until numThreads).map { i ->
        val startByte = task.downloadedBytes + i * dynamicChunkSize
        val endByte = if (i == numThreads - 1) task.totalBytes - 1
        else task.downloadedBytes + (i + 1) * dynamicChunkSize - 1

        scope.launch {
          downloadChunkAdvanced(task, startByte, endByte, raf, i, onProgress)
        }
      }

      // Monitor download progress and adjust if needed
      val monitorJob = scope.launch {
        monitorAndAdjustDownload(task, onProgress)
      }

      jobs.joinAll()
      monitorJob.cancel()
    }

    if (task.status == DownloadStatus.DOWNLOADING) {
      task.status = DownloadStatus.COMPLETED
      sendProgress(task, onProgress)
    }
  }

  private suspend fun downloadChunkAdvanced(
    task: DownloadTask, startByte: Long, endByte: Long,
    raf: RandomAccessFile, threadId: Int, onProgress: (Map<String, Any>) -> Unit
  ) {
    var currentStart = startByte
    var consecutiveFailures = 0

    repeat(task.retryCount + 1) { attempt ->
      if (task.status != DownloadStatus.DOWNLOADING) return

      try {
        val request = buildAdvancedRequest(task.url, task.headers, currentStart, endByte)
        val startTime = System.currentTimeMillis()

        client.newCall(request).execute().use { response ->
          if (!response.isSuccessful && response.code != 206) {
            throw Exception("HTTP ${response.code}: ${response.message}")
          }

          val buffer = ByteArray(8192)
          var bytesRead: Int
          var bytesInThisAttempt = 0L

          response.body!!.byteStream().use { input ->
            while (input.read(buffer).also { bytesRead = it } != -1 &&
              task.status == DownloadStatus.DOWNLOADING) {

              synchronized(raf) {
                raf.seek(currentStart)
                raf.write(buffer, 0, bytesRead)
              }

              currentStart += bytesRead
              bytesInThisAttempt += bytesRead

              synchronized(task) {
                task.downloadedBytes += bytesRead
              }
            }
          }

          // Track connection health
          val connectionTime = System.currentTimeMillis() - startTime
          val speed = if (connectionTime > 0) (bytesInThisAttempt * 1000.0 / connectionTime) else 0.0
          task.connectionHealth[threadId] = speed

          consecutiveFailures = 0
        }
        return

      } catch (e: Exception) {
        consecutiveFailures++

        if (attempt == task.retryCount) {
          task.status = DownloadStatus.FAILED
          task.error = "Thread $threadId failed: ${e.message}"
          throw e
        }

        // Adaptive backoff based on failure type and thread performance
        val baseDelay = if (e is java.net.SocketTimeoutException) 2000L else 1000L
        val backoffDelay = baseDelay * (1 shl min(consecutiveFailures, 4)) + (0..1000).random()
        delay(backoffDelay)
      }
    }
  }

  private suspend fun monitorAndAdjustDownload(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
    while (task.status == DownloadStatus.DOWNLOADING) {
      delay(2000) // Check every 2 seconds

      val currentTime = System.currentTimeMillis()
      val timeElapsed = currentTime - task.lastSpeedUpdate

      if (timeElapsed > 0) {
        val currentSpeed = (task.downloadedBytes * 1000.0 / (currentTime - task.startTime))
        updateSpeedHistory(task, task.downloadedBytes, timeElapsed)

        // Adjust chunk size based on current performance
        adjustChunkSizeBasedOnSpeed(task, currentSpeed)

        sendProgress(task, onProgress)
        task.lastSpeedUpdate = currentTime
      }
    }
  }

  private fun updateSpeedHistory(task: DownloadTask, bytes: Long, timeMs: Long) {
    val speed = if (timeMs > 0) (bytes * 1000.0 / timeMs) else 0.0
    task.speedHistory.add(speed)

    // Keep only last 10 speed measurements
    if (task.speedHistory.size > 10) {
      task.speedHistory.removeAt(0)
    }
  }

  private fun adjustChunkSizeBasedOnSpeed(task: DownloadTask, currentSpeed: Double) {
    val newChunkSize = when {
      currentSpeed > 10_000_000 -> 4 * 1024 * 1024  // 10MB/s+ -> 4MB chunks
      currentSpeed > 5_000_000 -> 2 * 1024 * 1024   // 5MB/s+ -> 2MB chunks
      currentSpeed > 1_000_000 -> 1024 * 1024        // 1MB/s+ -> 1MB chunks
      currentSpeed > 500_000 -> 512 * 1024           // 500KB/s+ -> 512KB chunks
      else -> 256 * 1024                             // < 500KB/s -> 256KB chunks
    }

    // Only adjust if significantly different
    if (kotlin.math.abs(newChunkSize - task.chunkSize) > task.chunkSize * 0.5) {
      task.chunkSize = newChunkSize
    }
  }

  private fun buildAdvancedRequest(
    url: String,
    headers: Map<String, String>,
    startByte: Long = 0,
    endByte: Long = -1
  ): Request {
    return Request.Builder()
      .url(url)
      .addHeader("User-Agent", "Mozilla/5.0 (Android) AppleWebKit/537.36")
      .addHeader("Accept", "*/*")
      .addHeader("Accept-Encoding", "gzip, deflate")
      .addHeader("Connection", "keep-alive")
      .apply {
        if (startByte > 0) {
          addHeader("Range", if (endByte > 0) "bytes=$startByte-$endByte" else "bytes=$startByte-")
        }
        headers.forEach { (key, value) -> addHeader(key, value) }
      }
      .build()
  }

  private suspend fun getFileInfo(task: DownloadTask): Pair<Long, Boolean> {
    return try {
      val request = buildAdvancedRequest(task.url, task.headers)
      client.newCall(request).execute().use { response ->
        if (!response.isSuccessful) {
          return -1L to false
        }

        val size = response.header("Content-Length")?.toLongOrNull() ?: -1L
        val acceptsRanges = response.header("Accept-Ranges")?.equals("bytes", true) == true

        response.close()

        if (size <= 0) return -1L to false

        // Test range request capability
        val rangeRequest = buildAdvancedRequest(task.url, task.headers, 0, 1)
        client.newCall(rangeRequest).execute().use { rangeResponse ->
          val supportsRanges = rangeResponse.code == 206 && acceptsRanges
          rangeResponse.close()
          size to supportsRanges
        }
      }
    } catch (e: Exception) {
      -1L to false
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

    val eta = if (avgSpeed > 0 && task.totalBytes > 0) {
      ((task.totalBytes - task.downloadedBytes) / avgSpeed).toLong()
    } else -1L

    onProgress(mapOf(
      "url" to task.url,
      "filePath" to task.filePath,
      "progress" to progress,
      "bytesDownloaded" to task.downloadedBytes,
      "totalBytes" to task.totalBytes,
      "status" to task.status.value,
      "error" to (task.error ?: ""),
      "speed" to avgSpeed,
      "eta" to eta,
      "activeConnections" to task.connectionHealth.size
    ))
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
        task.connectionHealth.clear() // Reset connection health
        task.speedHistory.clear() // Reset speed history

        task.job = scope.launch {
          try {
            downloadFile(task, onProgress)
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
      val eta = if (avgSpeed > 0 && task.totalBytes > 0) {
        ((task.totalBytes - task.downloadedBytes) / avgSpeed).toLong()
      } else -1L

      mapOf(
        "url" to task.url,
        "filePath" to task.filePath,
        "progress" to progress,
        "bytesDownloaded" to task.downloadedBytes,
        "totalBytes" to task.totalBytes,
        "status" to task.status.value,
        "error" to (task.error ?: ""),
        "speed" to avgSpeed,
        "eta" to eta,
        "activeConnections" to task.connectionHealth.size
      )
    }
  }

  fun getAllDownloads(): List<Map<String, Any>> = downloads.values.mapNotNull { getDownloadStatus(it.url) }

  fun clearCompletedDownloads(): Boolean {
    downloads.entries.removeAll { it.value.status == DownloadStatus.COMPLETED }
    return true
  }

  fun cancelAllDownloads() {
    downloads.values.forEach { it.job?.cancel() }
    downloads.clear()
  }
}