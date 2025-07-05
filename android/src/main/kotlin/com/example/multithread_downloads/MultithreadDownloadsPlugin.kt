package com.example.multithread_downloads

import android.app.Activity
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class MultithreadDownloadsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val downloadManager = ParallelDownloadManager()

  private val downloadQueue = ConcurrentLinkedQueue<DownloadRequest>()
  private val isProcessingQueue = AtomicBoolean(false)
  private val lastProgressUpdate = AtomicLong(0)
  private val progressThrottleMs = 100L // Throttle progress updates

  // Pre-allocated objects to reduce GC pressure
  private val queueStatusMap = mutableMapOf<String, Any>()
  private val progressMap = mutableMapOf<String, Any>()

  // Reusable Runnable to avoid object allocation
  private val progressUpdateRunnable = Runnable {
    eventSink?.success(progressMap.toMap()) // Create defensive copy only when needed
  }

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

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "startDownload" -> {
        val downloadRequest = DownloadRequest(
          urls = call.argument("urls") ?: emptyList(),
          filePath = call.argument("filePath")!!,
          headers = call.argument("headers") ?: emptyMap(),
          maxConcurrentTasks = call.argument("maxConcurrentTasks") ?: 50,
          retryCount = call.argument("retryCount") ?: 3,
          timeoutSeconds = call.argument("timeoutSeconds") ?: 30
        )
        downloadQueue.offer(downloadRequest)
        sendQueueStatusImmediate()
        processDownloadQueue()
        result.success(mapOf(
          "success" to true,
          "queueSize" to downloadQueue.size,
          "isProcessing" to isProcessingQueue.get()
        ))
      }

      "pause", "resume", "cancel" -> {
        val urls: List<String>? = call.argument<List<String>>("urls")
        val url: String? = call.argument<String>("url")

        val action: Boolean = when (call.method) {
          "pause" -> when {
            urls != null -> downloadManager.pauseDownloads(urls)
            url != null -> downloadManager.pauseDownload(url)
            else -> downloadManager.pauseAllDownloads()
          }
          "resume" -> {
            when {
              urls != null -> {
                downloadManager.resumeDownloads(urls, ::sendProgressThrottled)
                true
              }
              url != null -> {
                downloadManager.resumeDownload(url, ::sendProgressThrottled)
                true
              }
              else -> {
                downloadManager.resumeAllDownloads(::sendProgressThrottled)
                true
              }
            }
          }
          "cancel" -> when {
            urls != null -> downloadManager.cancelDownloads(urls)
            url != null -> downloadManager.cancelDownload(url)
            else -> {
              downloadQueue.clear()
              isProcessingQueue.set(false)
              sendQueueStatusImmediate()
              downloadManager.cancelAllDownloads()
              true
            }
          }
          else -> false
        }
        result.success(action)
      }

      "getDownloadStatus" -> result.success(downloadManager.getDownloadStatus(call.argument<String>("url")!!))
      "getDownloadStatuses" -> result.success(downloadManager.getDownloadStatuses(call.argument("urls") ?: emptyList()))
      "getAllDownloads" -> result.success(downloadManager.getAllDownloads())
      "getBatchProgress" -> result.success(downloadManager.getBatchProgress())
      "clearCompletedDownloads" -> result.success(downloadManager.clearCompletedDownloads())
      "getQueueSize" -> result.success(downloadQueue.size)
      "getQueueStatus" -> result.success(getQueueStatusMap())
      "clearQueue" -> {
        downloadQueue.clear()
        result.success(true)
      }

      else -> result.notImplemented()
    }
  }

  private fun processDownloadQueue(): Unit {
    if (!isProcessingQueue.compareAndSet(false, true)) return

    if (downloadQueue.isEmpty() || !downloadManager.isReadyForNewBatch()) {
      isProcessingQueue.set(false)
      return
    }

    val request = downloadQueue.poll()
    if (request == null) {
      isProcessingQueue.set(false)
      return
    }

    downloadManager.startBatchDownload(
      request.urls, request.filePath, request.headers,
      request.maxConcurrentTasks, request.retryCount, request.timeoutSeconds,
      onProgress = ::sendProgressThrottled,
      onBatchComplete = {
        isProcessingQueue.set(false)
        sendQueueStatusImmediate()
        // Process next item immediately if available, otherwise schedule
        if (downloadQueue.isNotEmpty()) {
          processDownloadQueue()
        } else {
          onDestroy()
          mainHandler.postDelayed({ processDownloadQueue() }, 100) // Reduced delay
        }
      }
    )
    sendQueueStatusImmediate()
  }

  private fun getQueueStatusMap(): Map<String, Any> {
    // Reuse the same map to reduce allocations
    queueStatusMap.clear()
    queueStatusMap["queueSize"] = downloadQueue.size
    queueStatusMap["isProcessing"] = isProcessingQueue.get()
    queueStatusMap["isBatchActive"] = downloadManager.isBatchActive()
    queueStatusMap["currentBatchComplete"] = downloadManager.isBatchComplete()
    queueStatusMap["isReadyForNewBatch"] = downloadManager.isReadyForNewBatch()
    return queueStatusMap.toMap() // Return defensive copy
  }

  private fun sendQueueStatusImmediate(): Unit {
    val statusMap = getQueueStatusMap().toMutableMap()
    statusMap["isQueueStatus"] = true
    sendProgressImmediate(statusMap)
  }

  private fun sendProgressThrottled(progress: Map<String, Any>): Unit {
    val currentTime = System.currentTimeMillis()
    val lastUpdate = lastProgressUpdate.get()

    if (currentTime - lastUpdate >= progressThrottleMs) {
      if (lastProgressUpdate.compareAndSet(lastUpdate, currentTime)) {
        sendProgressImmediate(progress)
      }
    }
  }

  private fun sendProgressImmediate(progress: Map<String, Any>): Unit {
    progressMap.clear()
    progressMap.putAll(progress)

    // Remove handler callbacks to prevent queue buildup
    mainHandler.removeCallbacks(progressUpdateRunnable)
    mainHandler.post(progressUpdateRunnable)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
    sendQueueStatusImmediate()
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
    // Clean up any pending progress updates
    mainHandler.removeCallbacks(progressUpdateRunnable)
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    mainHandler.removeCallbacks(progressUpdateRunnable)
  }

   fun onDestroy() {
    isProcessingQueue.set(false)
    downloadManager.cleanup()
  }
}