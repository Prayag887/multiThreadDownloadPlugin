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
import java.util.concurrent.ConcurrentLinkedQueue

class MultithreadDownloadsPlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val downloadManager = ParallelDownloadManager()

  // Use ConcurrentLinkedQueue for thread safety
  private val downloadQueue = ConcurrentLinkedQueue<DownloadRequest>()
  private var isProcessingQueue = false

  data class DownloadRequest(
    val urls: List<String>,
    val filePath: String,
    val headers: Map<String, String>,
    val maxConcurrentTasks: Int,
    val retryCount: Int,
    val timeoutSeconds: Int,
    val requestId: String = System.currentTimeMillis().toString()
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

        // Add to queue
        downloadQueue.offer(downloadRequest)
        println("Added download request to queue. Queue size: ${downloadQueue.size}")

        // Send queue status update
        sendQueueStatus()

        // Process queue
        processDownloadQueue()

        result.success(mapOf(
          "success" to true,
          "queueSize" to downloadQueue.size,
          "isProcessing" to isProcessingQueue
        ))
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
        sendQueueStatus()
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
      "getQueueSize" -> result.success(downloadQueue.size)
      "getQueueStatus" -> result.success(getQueueStatus())
      "clearQueue" -> {
        downloadQueue.clear()
        result.success(true)
      }
      else -> result.notImplemented()
    }
  }

  private fun processDownloadQueue() {
    // Use synchronized to prevent race conditions
    synchronized(this) {
      if (isProcessingQueue || downloadQueue.isEmpty()) {
        return
      }

      // Use the isReadyForNewBatch function here
      if (!downloadManager.isReadyForNewBatch()) {
        println("Download manager not ready for new batch, waiting...")
        return
      }

      isProcessingQueue = true
    }

    val request = downloadQueue.poll()
    if (request != null) {
      println("Processing download request with ${request.urls.size} URLs")

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
          println("Batch completed, processing next item in queue")
          synchronized(this) {
            isProcessingQueue = false
          }
          sendQueueStatus()

          // Use a small delay to ensure cleanup is complete before processing next batch
          mainHandler.postDelayed({
            processDownloadQueue()
          }, 100) // 100ms delay
        }
      )

      sendQueueStatus()
    } else {
      synchronized(this) {
        isProcessingQueue = false
      }
    }
  }

  private fun getQueueStatus(): Map<String, Any> {
    return mapOf(
      "queueSize" to downloadQueue.size,
      "isProcessing" to isProcessingQueue,
      "isBatchActive" to downloadManager.isBatchActive(),
      "currentBatchComplete" to downloadManager.isBatchComplete(),
      "isReadyForNewBatch" to downloadManager.isReadyForNewBatch()
    )
  }

  private fun sendQueueStatus() {
    val queueStatus = getQueueStatus()
    sendProgress(queueStatus + ("isQueueStatus" to true))
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
    // Send initial queue status
    sendQueueStatus()
  }

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