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

class MultithreadDownloadsPlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val downloadManager = ParallelDownloadManager()

  // Queue to store pending download requests
  private val downloadQueue = ArrayDeque<DownloadRequest>()
  private var isProcessingQueue = false

  data class DownloadRequest(
    val urls: List<String>,
    val filePath: String,
    val headers: Map<String, String>,
    val maxConcurrentTasks: Int,
    val retryCount: Int,
    val timeoutSeconds: Int
  )

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "multithread_downloads")
    eventChannel = EventChannel(binding.binaryMessenger, "multithread_downloads/progress")
    channel.setMethodCallHandler(this)
    eventChannel.setStreamHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "startDownload" -> {
        println("headers::: ${call.argument<Map<String, String>>("headers") ?: emptyMap()}")
        val urls = call.argument<List<String>>("urls") ?: emptyList()
        val filePath = call.argument<String>("filePath")!!
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val maxConcurrentTasks = call.argument<Int>("maxConcurrentTasks") ?: 50
        val retryCount = call.argument<Int>("retryCount") ?: 3
        val timeoutSeconds = call.argument<Int>("timeoutSeconds") ?: 30

        val downloadRequest = DownloadRequest(
          urls, filePath, headers, maxConcurrentTasks, retryCount, timeoutSeconds
        )

        // Add to queue and process
        downloadQueue.offer(downloadRequest)
        processDownloadQueue()

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
      "cancelAllDownloads" -> {
        val cancelled = downloadManager.cancelAllDownloads()
        // Clear the queue when all downloads are cancelled
        downloadQueue.clear()
        isProcessingQueue = false
        result.success(cancelled)
      }
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
      "getQueueSize" -> result.success(downloadQueue.size) // Optional: to check queue size
      else -> result.notImplemented()
    }
  }

  private fun processDownloadQueue() {
    if (isProcessingQueue || downloadQueue.isEmpty()) {
      return
    }

    isProcessingQueue = true
    val request = downloadQueue.poll()

    if (request != null) {
      downloadManager.startBatchDownload(
        request.urls,
        request.filePath,
        request.headers,
        request.maxConcurrentTasks,
        request.retryCount,
        request.timeoutSeconds,
        onProgress = { progress ->
          sendProgress(progress)
        },
        onBatchComplete = {
          // Batch completed, process next item in queue
          isProcessingQueue = false
          processDownloadQueue()
        }
      )
    } else {
      isProcessingQueue = false
    }
  }

  private fun isBatchComplete(batchProgress: Map<String, Any>): Boolean {
    // You'll need to implement this based on your ParallelDownloadManager's getBatchProgress() structure
    // This is just an example - adjust according to your actual implementation
    val totalFiles = batchProgress["totalFiles"] as? Int ?: 0
    val completedFiles = batchProgress["completedFiles"] as? Int ?: 0
    val failedFiles = batchProgress["failedFiles"] as? Int ?: 0
    val cancelledFiles = batchProgress["cancelledFiles"] as? Int ?: 0

    return (completedFiles + failedFiles + cancelledFiles) >= totalFiles
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
    downloadQueue.clear()
    isProcessingQueue = false
  }
}