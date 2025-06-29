package com.example.multithread_downloads

import kotlinx.coroutines.Job

data class DownloadTask(
    val url: String,
    var filePath: String,
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

data class SegmentTask(
    val url: String,
    val fileName: String,
    val size: Long = 0,
    var downloaded: Boolean = false,
    var bytes: Long = 0,
    val duration: Double = 10.0
)

data class VariantPlaylist(
    val url: String,
    val fileName: String,
    val bandwidth: Long = 0,
//    val segments: MutableList<SegmentTask> = mutableListOf(),
    val resolution: String = ""
)