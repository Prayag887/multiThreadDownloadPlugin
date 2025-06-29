package com.example.multithread_downloads

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import java.util.concurrent.PriorityBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.*

/**
 * High-performance HLS downloader with ExoPlayer-inspired optimizations
 * Combines coroutines with thread pool management for maximum efficiency
 */
class HighPerformanceHlsDownloader {

    // Performance tracking and configuration
    private data class PerformanceMetrics(
        var avgDownloadSpeed: Double = 0.0,
        var connectionSuccessRate: Double = 1.0,
        var lastSpeedUpdate: Long = 0L,
        val speedHistory: MutableList<Double> = mutableListOf()
    )

    private data class AdaptiveConfig(
        var concurrentDownloaders: Int,
        var maxConnections: Int,
        var useChunking: Boolean,
        var chunkSize: Int,
        var bufferSize: Int
    ) {
        fun adapt(metrics: PerformanceMetrics, segmentSize: Long) {
            when {
                segmentSize <= 100_000 -> { // Small segments (≤100KB)
                    concurrentDownloaders = 20
                    maxConnections = 30
                    useChunking = false
                    bufferSize = 8192
                }
                segmentSize <= 1_000_000 -> { // Medium segments (≤1MB)
                    concurrentDownloaders = 15
                    maxConnections = 25
                    useChunking = false
                    bufferSize = 16384
                }
                else -> { // Large segments (>1MB)
                    concurrentDownloaders = 10
                    maxConnections = 15
                    useChunking = true
                    chunkSize = 512_000
                    bufferSize = 32768
                }
            }

            // Adapt based on performance
            if (metrics.avgDownloadSpeed > 0) {
                val networkCapacity = metrics.avgDownloadSpeed * 1.2
                if (metrics.avgDownloadSpeed < networkCapacity * 0.7 && concurrentDownloaders < 25) {
                    concurrentDownloaders = min(concurrentDownloaders + 2, 25)
                } else if (metrics.avgDownloadSpeed > networkCapacity * 0.95 && concurrentDownloaders > 5) {
                    concurrentDownloaders = max(concurrentDownloaders - 1, 5)
                }
            }
        }
    }

    // Priority-based segment task
    private data class PrioritySegmentTask(
        val segment: SegmentTask,
        val priority: Int,
        val segmentIndex: Int,
        var retryCount: Int = 0,
        var failed: Boolean = false
    ) : Comparable<PrioritySegmentTask> {
        override fun compareTo(other: PrioritySegmentTask): Int = when {
            priority != other.priority -> other.priority - priority
            else -> segmentIndex - other.segmentIndex
        }
    }

    // High-performance HTTP client with adaptive configuration
    private val httpClient = OkHttpClient.Builder()
        .connectionPool(ConnectionPool(50, 5, java.util.concurrent.TimeUnit.MINUTES))
        .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .dispatcher(Dispatcher().apply {
            maxRequests = 100
            maxRequestsPerHost = 20
        })
        .build()

    // Thread pool for I/O operations
    private val ioExecutor = Executors.newCachedThreadPool { r ->
        Thread(r, "HLS-IO-${System.currentTimeMillis()}").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY + 1
        }
    }

    // Performance metrics
    private val performanceMetrics = AtomicReference(PerformanceMetrics())
    private val config = AtomicReference(AdaptiveConfig(12, 20, false, 256_000, 16384))

    /**
     * Main download function with advanced optimizations
     */
    /**
     * Fixed download worker with proper queue handling
     */
    private suspend fun downloadWorker(
        workerId: Int,
        segmentQueue: PriorityBlockingQueue<PrioritySegmentTask>,
        playlistDir: File,
        headers: Map<String, String>,
        config: AdaptiveConfig,
        totalDownloadedBytes: AtomicLong,
        downloadedSegments: AtomicInteger,
        progressChannel: Channel<ProgressUpdate>,
        semaphore: Semaphore,
        isCompleted: AtomicReference<Boolean> // Add completion flag
    ) {
        while (!isCompleted.get()) {
            val priorityTask = try {
                // Use blocking take with timeout instead of poll
                segmentQueue.poll(1, java.util.concurrent.TimeUnit.SECONDS)
            } catch (e: InterruptedException) {
                break
            }

            if (priorityTask == null) {
                // Check if we should continue waiting
                if (!isCompleted.get()) {
                    delay(100) // Small delay before checking again
                    continue
                } else {
                    break
                }
            }

            // Check for termination signal
            if (priorityTask.priority == -1) break

            semaphore.withPermit {
                try {
                    val startTime = System.currentTimeMillis()
                    val bytesDownloaded = downloadSegmentAdvanced(
                        priorityTask.segment, playlistDir, headers, config
                    )
                    val downloadTime = System.currentTimeMillis() - startTime

                    totalDownloadedBytes.addAndGet(bytesDownloaded)
                    downloadedSegments.incrementAndGet()

                    progressChannel.trySend(ProgressUpdate(
                        bytesDownloaded, downloadTime, true
                    ))

                } catch (e: Exception) {
                    if (priorityTask.retryCount < 3) {
                        priorityTask.retryCount++
                        delay(2.0.pow(priorityTask.retryCount).toLong() * 200)
                        segmentQueue.offer(priorityTask)
                    } else {
                        priorityTask.failed = true
                        progressChannel.trySend(ProgressUpdate(0, 0, false))
                        println("Worker $workerId: Failed to download ${priorityTask.segment.fileName} after retries: ${e.message}")
                    }
                }
            }
        }
        println("Worker $workerId: Exiting")
    }

    /**
     * Fixed main download function with proper coordination
     */
    suspend fun downloadHlsStreamAdvanced(
        task: DownloadTask,
        basePath: String,
        onProgress: (Map<String, Any>) -> Unit
    ) = withContext(Dispatchers.IO) {

        task.status = DownloadStatus.DOWNLOADING
        task.startTime = System.currentTimeMillis()

        val playlistDir = File(basePath, task.fileName.removeSuffix(".m3u8"))
        if (!playlistDir.exists()) playlistDir.mkdirs()

        val baseUri = task.url.toHttpUrlOrNull()!!
        val totalDownloadedBytes = AtomicLong(0L)
        val downloadedSegments = AtomicInteger(0)
        val totalSegments = AtomicInteger(0)
        val isCompleted = AtomicReference(false) // Add completion flag

        try {
            // Phase 1: Analyze stream
            val (variants, avgSegmentSize) = analyzeHlsStream(task.url, task.headers, baseUri)

            // Phase 2: Configure
            val currentConfig = config.get().apply { adapt(performanceMetrics.get(), avgSegmentSize) }
            config.set(currentConfig)

            // Phase 3: Create queues and channels
            val segmentQueue = PriorityBlockingQueue<PrioritySegmentTask>()
            val progressChannel = Channel<ProgressUpdate>(Channel.UNLIMITED)

            // Phase 4: Process playlists FIRST
            println("Processing playlists...")
            val playlistJobs = variants.take(1).mapIndexed { variantIndex, variant ->
                async {
                    processVariantPlaylist(
                        variant, baseUri, task.headers, segmentQueue,
                        totalSegments, variantIndex, playlistDir
                    )
                }
            }

            // Wait for playlist processing to complete
            playlistJobs.awaitAll()
            println("Found ${totalSegments.get()} segments to download")

            if (totalSegments.get() == 0) {
                throw IOException("No segments found in playlist")
            }

            // Phase 5: Launch download workers AFTER segments are queued
            val downloadScope = CoroutineScope(
                Dispatchers.IO + SupervisorJob() +
                        CoroutineName("HLS-Download-${System.currentTimeMillis()}")
            )

            val semaphore = Semaphore(currentConfig.maxConnections)
            val downloadJobs = mutableListOf<Job>()

            println("Starting ${currentConfig.concurrentDownloaders} download workers...")
            repeat(currentConfig.concurrentDownloaders) { workerId ->
                val job = downloadScope.launch {
                    downloadWorker(
                        workerId, segmentQueue, playlistDir, task.headers,
                        currentConfig, totalDownloadedBytes, downloadedSegments,
                        progressChannel, semaphore, isCompleted
                    )
                }
                downloadJobs.add(job)
            }

            // Phase 6: Progress tracking
            val progressJob = launch {
                handleProgressUpdates(
                    progressChannel, task, totalDownloadedBytes,
                    downloadedSegments, totalSegments, onProgress
                )
            }

            // Phase 7: Performance monitoring
            val monitoringJob = launch {
                monitorPerformance(totalDownloadedBytes, task.startTime)
            }

            // Phase 8: Wait for downloads to complete
            while (downloadedSegments.get() < totalSegments.get()) {
                delay(500) // Check every 500ms
                println("Progress: ${downloadedSegments.get()}/${totalSegments.get()} segments downloaded")
            }

            // Signal completion
            isCompleted.set(true)

            // Send termination signals to workers
            repeat(currentConfig.concurrentDownloaders) {
                segmentQueue.offer(PrioritySegmentTask(
                    SegmentTask("", ""), -1, -1
                ))
            }

            downloadJobs.joinAll()
            progressChannel.close()
            progressJob.join()
            monitoringJob.cancel()

            // Phase 9: Create final playlists
            createMasterPlaylist(variants.take(1), playlistDir)

            task.status = DownloadStatus.COMPLETED
            task.downloadedBytes = totalDownloadedBytes.get()
            task.filePath = File(playlistDir, "master.m3u8").absolutePath
            sendProgress(task, onProgress)

        } catch (e: Exception) {
            isCompleted.set(true) // Ensure workers stop
            task.status = DownloadStatus.FAILED
            task.error = e.message
            sendProgress(task, onProgress)
            throw e
        }
    }

    /**
     * Analyzes HLS stream to determine optimal download strategy
     */
    private suspend fun analyzeHlsStream(
        masterUrl: String,
        headers: Map<String, String>,
        baseUri: HttpUrl
    ): Pair<List<VariantPlaylist>, Long> {

        val masterContent = fetchPlaylistContent(masterUrl, headers)
        val variants = parseMasterPlaylist(masterContent, baseUri)

        // Sample segments from the highest quality variant for size estimation
        val primaryVariant = variants.firstOrNull() ?: throw IOException("No variants found")
        val sampleSegments = getSampleSegments(primaryVariant, baseUri, headers, 5)
        val avgSegmentSize = estimateSegmentSizeAdvanced(sampleSegments, headers)

        return Pair(variants, avgSegmentSize)
    }

    /**
     * Processes variant playlist and creates prioritized segment tasks
     */
    private suspend fun processVariantPlaylist(
        variant: VariantPlaylist,
        baseUri: HttpUrl,
        headers: Map<String, String>,
        segmentQueue: PriorityBlockingQueue<PrioritySegmentTask>,
        totalSegments: AtomicInteger,
        variantIndex: Int,
        playlistDir: File
    ) {
        try {
            println("Processing variant: ${variant.url}")
            val variantContent = fetchPlaylistContent(variant.url, headers)
            println("Variant content length: ${variantContent.length}")
            val segments = parseVariantPlaylist(variantContent, baseUri, variant.fileName)
            println("Found ${segments.size} segments in variant")
            totalSegments.addAndGet(segments.size)

            // Create prioritized tasks
            segments.forEachIndexed { index, segment ->
                val priority = calculateSegmentPriority(index, segments.size, variantIndex)
                segmentQueue.offer(PrioritySegmentTask(segment, priority, index))
            }

            // Create local playlist asynchronously
            withContext(Dispatchers.IO) {
                createLocalPlaylist(variant, segments, playlistDir)
            }

        } catch (e: Exception) {
            println("Error processing variant ${variant.url}: ${e.message}")
        }
    }

    /**
     * Advanced segment download with streaming and chunking support
     */
    private suspend fun downloadSegmentAdvanced(
        segment: SegmentTask,
        playlistDir: File,
        headers: Map<String, String>,
        config: AdaptiveConfig
    ): Long = withContext(Dispatchers.IO) {

        val segmentFile = File(playlistDir, segment.fileName)

        if (segmentFile.exists() && segmentFile.length() > 0) {
            return@withContext segmentFile.length()
        }

        if (config.useChunking) {
            downloadSegmentChunked(segment, segmentFile, headers, config)
        } else {
            downloadSegmentStreaming(segment, segmentFile, headers, config)
        }
    }

    /**
     * Streaming download for better memory efficiency
     */
    private suspend fun downloadSegmentStreaming(
        segment: SegmentTask,
        segmentFile: File,
        headers: Map<String, String>,
        config: AdaptiveConfig
    ): Long {
        val request = Request.Builder()
            .url(segment.url)
            .apply { headers.forEach { (key, value) -> addHeader(key, value) } }
            .build()

        return httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IOException("Download failed: ${segment.url} (${response.code})")
            }

            val inputStream = response.body!!.byteStream()
            val outputStream = segmentFile.outputStream().buffered(config.bufferSize)

            val buffer = ByteArray(config.bufferSize)
            var totalBytes = 0L
            var bytesRead: Int

            outputStream.use { output ->
                while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                    output.write(buffer, 0, bytesRead)
                    totalBytes += bytesRead
                }
            }

            totalBytes
        }
    }

    /**
     * Chunked download for large segments
     */
    private suspend fun downloadSegmentChunked(
        segment: SegmentTask,
        segmentFile: File,
        headers: Map<String, String>,
        config: AdaptiveConfig
    ): Long = coroutineScope {

        // Get content length
        val contentLength = getContentLength(segment.url, headers)
            ?: return@coroutineScope downloadSegmentStreaming(segment, segmentFile, headers, config)

        if (contentLength <= config.chunkSize) {
            return@coroutineScope downloadSegmentStreaming(segment, segmentFile, headers, config)
        }

        val chunks = (contentLength + config.chunkSize - 1) / config.chunkSize
        val randomAccessFile = RandomAccessFile(segmentFile, "rw")
        randomAccessFile.setLength(contentLength)

        try {
            val chunkJobs = (0 until chunks.toInt()).map { chunkIndex ->
                async(Dispatchers.IO) {
                    val start = chunkIndex * config.chunkSize.toLong()
                    val end = min(start + config.chunkSize - 1, contentLength - 1)

                    val request = Request.Builder()
                        .url(segment.url)
                        .addHeader("Range", "bytes=$start-$end")
                        .apply { headers.forEach { (key, value) -> addHeader(key, value) } }
                        .build()

                    httpClient.newCall(request).execute().use { response ->
                        if (!response.isSuccessful) {
                            throw IOException("Chunk download failed: ${response.code}")
                        }

                        val chunkData = response.body!!.bytes()
                        synchronized(randomAccessFile) {
                            randomAccessFile.seek(start)
                            randomAccessFile.write(chunkData)
                        }
                        chunkData.size.toLong()
                    }
                }
            }

            chunkJobs.awaitAll().sum()

        } finally {
            randomAccessFile.close()
        }
    }

    /**
     * Enhanced progress handling with performance metrics
     */
    private data class ProgressUpdate(
        val bytesDownloaded: Long,
        val downloadTime: Long,
        val success: Boolean
    )

    private suspend fun handleProgressUpdates(
        progressChannel: Channel<ProgressUpdate>,
        task: DownloadTask,
        totalDownloadedBytes: AtomicLong,
        downloadedSegments: AtomicInteger,
        totalSegments: AtomicInteger,
        onProgress: (Map<String, Any>) -> Unit
    ) {
        var lastUpdate = 0L
        val updateInterval = 300L // 300ms for smooth updates

        for (update in progressChannel) {
            val now = System.currentTimeMillis()

            if (now - lastUpdate >= updateInterval ||
                downloadedSegments.get() >= totalSegments.get()) {

                task.downloadedBytes = totalDownloadedBytes.get()

                // Estimate total size if not known
                if (task.totalBytes <= 0 && downloadedSegments.get() > 0) {
                    val avgBytesPerSegment = totalDownloadedBytes.get() / downloadedSegments.get()
                    task.totalBytes = avgBytesPerSegment * totalSegments.get()
                }

                sendProgress(task, onProgress)
                lastUpdate = now
            }

            // Break if all segments downloaded
            if (downloadedSegments.get() >= totalSegments.get() && totalSegments.get() > 0) {
                break
            }
        }
    }

    /**
     * Performance monitoring for adaptive optimization
     */
    private suspend fun monitorPerformance(
        totalDownloadedBytes: AtomicLong,
        startTime: Long
    ) {
        while (true) {
            delay(2000) // Monitor every 2 seconds

            val currentTime = System.currentTimeMillis()
            val timeElapsed = currentTime - startTime
            val currentSpeed = totalDownloadedBytes.get() * 1000.0 / timeElapsed

            val metrics = performanceMetrics.get()
            metrics.speedHistory.add(currentSpeed)
            if (metrics.speedHistory.size > 20) {
                metrics.speedHistory.removeAt(0)
            }

            metrics.avgDownloadSpeed = metrics.speedHistory.average()
            metrics.lastSpeedUpdate = currentTime

            performanceMetrics.set(metrics)
        }
    }

    // Helper functions

    private fun calculateSegmentPriority(index: Int, totalSegments: Int, variantIndex: Int): Int {
        return when {
            index < 5 -> 100 - index // Highest priority for first segments
            index < totalSegments * 0.1 -> 80 - index // High priority for early segments
            index < totalSegments * 0.3 -> 60 // Medium priority
            else -> 40 // Normal priority
        } - (variantIndex * 10) // Prefer higher quality variants
    }

    private suspend fun getContentLength(url: String, headers: Map<String, String>): Long? {
        return try {
            val request = Request.Builder()
                .url(url)
                .head()
                .apply { headers.forEach { (key, value) -> addHeader(key, value) } }
                .build()

            httpClient.newCall(request).execute().use { response ->
                response.header("Content-Length")?.toLongOrNull()
            }
        } catch (e: Exception) {
            null
        }
    }

    private suspend fun estimateSegmentSizeAdvanced(
        sampleSegments: List<SegmentTask>,
        headers: Map<String, String>
    ): Long {
        if (sampleSegments.isEmpty()) return 200_000L

        val sizes = sampleSegments.mapNotNull { segment ->
            getContentLength(segment.url, headers)
        }

        return if (sizes.isNotEmpty()) {
            sizes.average().toLong()
        } else 200_000L
    }

    // Reuse existing helper functions from original code
    private suspend fun fetchPlaylistContent(url: String, headers: Map<String, String>): String {
        val request = Request.Builder()
            .url(url)
            .apply { headers.forEach { (key, value) -> addHeader(key, value) } }
            .build()

        return httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Failed to fetch playlist: $url (${response.code})")
            response.body?.string() ?: throw IOException("Empty playlist content")
        }
    }

    private fun parseMasterPlaylist(content: String, baseUri: HttpUrl): List<VariantPlaylist> {
        val variants = mutableListOf<VariantPlaylist>()
        val lines = content.lines()
        var currentBandwidth = 0L
        var currentResolution = ""

        for (i in lines.indices) {
            val line = lines[i].trim()

            if (line.startsWith("#EXT-X-STREAM-INF:")) {
                val bandwidthMatch = Regex("BANDWIDTH=(\\d+)").find(line)
                currentBandwidth = bandwidthMatch?.groupValues?.get(1)?.toLongOrNull() ?: 0L

                val resolutionMatch = Regex("RESOLUTION=(\\d+x\\d+)").find(line)
                currentResolution = resolutionMatch?.groupValues?.get(1) ?: ""

            } else if (line.isNotEmpty() && !line.startsWith("#")) {
                val variantUrl = baseUri.resolve(line)!!.toString()
                val variantFileName = line.substringAfterLast("/")
                variants.add(VariantPlaylist(variantUrl, variantFileName, currentBandwidth, currentResolution))
            }
        }

        return variants.sortedByDescending { it.bandwidth }
    }

    private suspend fun getSampleSegments(
        variant: VariantPlaylist,
        baseUri: HttpUrl,
        headers: Map<String, String>,
        sampleCount: Int = 3
    ): List<SegmentTask> {
        return try {
            val variantContent = fetchPlaylistContent(variant.url, headers)
            parseVariantPlaylist(variantContent, baseUri, variant.fileName).take(sampleCount)
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun parseVariantPlaylist(content: String, baseUri: HttpUrl, variantName: String): List<SegmentTask> {
        val segments = mutableListOf<SegmentTask>()
        val lines = content.lines()
        var segmentDuration = 10.0

        for (i in lines.indices) {
            val line = lines[i].trim()

            if (line.startsWith("#EXTINF:")) {
                val durationMatch = Regex("#EXTINF:([\\d.]+)").find(line)
                segmentDuration = durationMatch?.groupValues?.get(1)?.toDoubleOrNull() ?: 10.0
            } else if (line.isNotEmpty() && !line.startsWith("#")) {
                val segmentUrl = baseUri.resolve(line)!!.toString()
                val segmentFileName = "${variantName}_${line.substringAfterLast("/")}"
                segments.add(SegmentTask(segmentUrl, segmentFileName, duration = segmentDuration))
            }
        }

        return segments
    }

    private fun createLocalPlaylist(variant: VariantPlaylist, segments: List<SegmentTask>, playlistDir: File) {
        val playlistContent = buildString {
            appendLine("#EXTM3U")
            appendLine("#EXT-X-VERSION:3")
            appendLine("#EXT-X-TARGETDURATION:${segments.maxOfOrNull { it.duration.toInt() } ?: 10}")
            appendLine("#EXT-X-MEDIA-SEQUENCE:0")

            segments.forEach { segment ->
                appendLine("#EXTINF:${segment.duration},")
                appendLine(segment.fileName)
            }

            appendLine("#EXT-X-ENDLIST")
        }

        File(playlistDir, variant.fileName).writeText(playlistContent)
    }

    private fun createMasterPlaylist(variants: List<VariantPlaylist>, playlistDir: File) {
        val masterContent = buildString {
            appendLine("#EXTM3U")
            appendLine("#EXT-X-VERSION:3")

            variants.forEach { variant ->
                val streamInf = buildString {
                    append("BANDWIDTH=${variant.bandwidth}")
                    if (variant.resolution.isNotEmpty()) {
                        append(",RESOLUTION=${variant.resolution}")
                    }
                }
                appendLine("#EXT-X-STREAM-INF:$streamInf")
                appendLine(variant.fileName)
            }
        }

        File(playlistDir, "master.m3u8").writeText(masterContent)
    }

    private fun sendProgress(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
        val currentTime = System.currentTimeMillis()
        val timeElapsed = max(1L, currentTime - task.startTime)
        val currentSpeed = task.downloadedBytes * 1000.0 / timeElapsed

        task.speedHistory.add(currentSpeed)
        if (task.speedHistory.size > 10) {
            task.speedHistory.removeAt(0)
        }

        val avgSpeed = if (task.speedHistory.isNotEmpty()) {
            task.speedHistory.average()
        } else currentSpeed

        val progress = if (task.totalBytes > 0) {
            (task.downloadedBytes * 100.0 / task.totalBytes).toInt()
        } else -1

        val remainingBytes = task.totalBytes - task.downloadedBytes
        val estimatedTimeRemaining = if (avgSpeed > 0 && remainingBytes > 0) {
            (remainingBytes / avgSpeed * 1000).toLong()
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
            "estimatedTimeRemaining" to estimatedTimeRemaining
        ))
    }

    // Cleanup method
    fun cleanup() {
        ioExecutor.shutdown()
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
    }
}