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
        downloadManager.startBatchDownload(
          urls,
          call.argument<String>("filePath")!!,
          call.argument<Map<String, String>>("headers") ?: emptyMap(),
          call.argument<Int>("maxConcurrentTasks") ?: 50,
          call.argument<Int>("retryCount") ?: 3,
          call.argument<Int>("timeoutSeconds") ?: 30
        ) {
          sendProgress(it)
        }
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