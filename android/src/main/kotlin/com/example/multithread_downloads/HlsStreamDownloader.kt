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
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.*

/**
 * Mobile-optimized HLS downloader - Maximum speed with mobile efficiency
 */
class HighPerformanceHlsDownloader {

    private data class SegmentTask(
        val url: String,
        val fileName: String,
        val duration: Double = 10.0,
        var retryCount: Int = 0,
        var size: Long = 0L
    )

    private data class MobileConfig(
        val concurrentDownloaders: Int,
        val maxConnections: Int,
        val bufferSize: Int,
        val chunkSize: Int,
        val useChunking: Boolean
    )

    // Mobile-optimized HTTP client - aggressive settings for speed
    private val httpClient = OkHttpClient.Builder()
        .connectionPool(ConnectionPool(40, 5, java.util.concurrent.TimeUnit.MINUTES))
        .connectTimeout(5, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .dispatcher(Dispatcher().apply {
            maxRequests = 200
            maxRequestsPerHost = 40
        })
        .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1)) // HTTP/2 for mobile
        .build()

    // Optimized thread pool for mobile
    private val ioExecutor = Executors.newCachedThreadPool { r ->
        Thread(r, "HLS-Mobile").apply {
            isDaemon = false
            priority = Thread.MAX_PRIORITY
        }
    }

    // Mobile-adaptive configuration
    private val mobileConfig = getMobileOptimizedConfig()

    private fun getMobileOptimizedConfig(): MobileConfig {
        val cores = Runtime.getRuntime().availableProcessors()
        val maxMemory = Runtime.getRuntime().maxMemory()
        val isHighEndDevice = cores >= 6 && maxMemory > 1024 * 1024 * 1024 // 1GB+

        return when {
            isHighEndDevice -> MobileConfig(
                concurrentDownloaders = 16,
                maxConnections = 32,
                bufferSize = 65536, // 64KB buffer for speed
                chunkSize = 1024_000, // 1MB chunks
                useChunking = true
            )
            cores >= 4 -> MobileConfig(
                concurrentDownloaders = 12,
                maxConnections = 24,
                bufferSize = 32768,
                chunkSize = 512_000,
                useChunking = true
            )
            else -> MobileConfig(
                concurrentDownloaders = 8,
                maxConnections = 16,
                bufferSize = 16384,
                chunkSize = 256_000,
                useChunking = false
            )
        }
    }

    /**
     * Ultra-fast mobile download with aggressive optimization
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
        val isCompleted = AtomicReference(false)

        try {
            // Phase 1: Fast playlist processing
            val masterContent = fetchPlaylistContentFast(task.url, task.headers)
            val variants = parseMasterPlaylist(masterContent, baseUri)

            // Select BEST quality for maximum speed utilization
            val selectedVariant = variants.maxByOrNull { it.bandwidth }
                ?: throw IOException("No variants found")

            // Phase 2: Parallel playlist and segment preparation
            val (segments, avgSegmentSize) = async {
                val variantContent = fetchPlaylistContentFast(selectedVariant.url, task.headers)
                val segments = parseVariantPlaylist(variantContent, selectedVariant.url.toHttpUrlOrNull()!!, selectedVariant.fileName)

                // Pre-analyze segment sizes for optimal chunking
                val avgSize = estimateSegmentSizes(segments, task.headers)
                Pair(segments, avgSize)
            }.await()

            totalSegments.set(segments.size)

            // Create playlists in parallel
            launch { createLocalPlaylist(selectedVariant, segments, playlistDir) }
            launch { createMasterPlaylist(listOf(selectedVariant), playlistDir) }

            task.filePath = File(playlistDir, "master.m3u8").absolutePath
            task.totalBytes = avgSegmentSize * segments.size

            // Phase 3: Ultra-fast segment downloading
            val segmentQueue = ConcurrentLinkedQueue<SegmentTask>()
            segments.forEach { segmentQueue.offer(it) }

            val semaphore = Semaphore(mobileConfig.maxConnections)
            val progressChannel = Channel<Long>(Channel.UNLIMITED)

            // Launch maximum workers for speed
            val downloadJobs = (0 until mobileConfig.concurrentDownloaders).map { workerId ->
                launch {
                    ultraFastDownloadWorker(
                        workerId, segmentQueue, playlistDir, task.headers,
                        totalDownloadedBytes, downloadedSegments,
                        progressChannel, semaphore, isCompleted, avgSegmentSize
                    )
                }
            }

            // Minimal overhead progress tracking
            val progressJob = launch {
                fastProgressTracking(
                    progressChannel, task, totalDownloadedBytes,
                    downloadedSegments, totalSegments, onProgress
                )
            }

            // Wait for completion
            downloadJobs.joinAll()
            isCompleted.set(true)
            progressChannel.close()
            progressJob.join()

            task.status = DownloadStatus.COMPLETED
            task.downloadedBytes = totalDownloadedBytes.get()
            sendProgress(task, onProgress)

        } catch (e: Exception) {
            isCompleted.set(true)
            task.status = DownloadStatus.FAILED
            task.error = e.message
            sendProgress(task, onProgress)
            throw e
        }
    }

    /**
     * Ultra-fast download worker with intelligent chunking
     */
    private suspend fun ultraFastDownloadWorker(
        workerId: Int,
        segmentQueue: ConcurrentLinkedQueue<SegmentTask>,
        playlistDir: File,
        headers: Map<String, String>,
        totalDownloadedBytes: AtomicLong,
        downloadedSegments: AtomicInteger,
        progressChannel: Channel<Long>,
        semaphore: Semaphore,
        isCompleted: AtomicReference<Boolean>,
        avgSegmentSize: Long
    ) {
        // Pre-allocate buffer for maximum speed
        val buffer = ByteArray(mobileConfig.bufferSize)

        while (!isCompleted.get()) {
            val segment = segmentQueue.poll() ?: break

            semaphore.withPermit {
                try {
                    val bytesDownloaded = if (mobileConfig.useChunking && avgSegmentSize > mobileConfig.chunkSize) {
                        downloadSegmentChunked(segment, playlistDir, headers, buffer)
                    } else {
                        downloadSegmentStreaming(segment, playlistDir, headers, buffer)
                    }

                    totalDownloadedBytes.addAndGet(bytesDownloaded)
                    downloadedSegments.incrementAndGet()
                    progressChannel.trySend(bytesDownloaded)

                } catch (e: Exception) {
                    if (segment.retryCount < 2) {
                        segment.retryCount++
                        // Immediate retry for speed
                        segmentQueue.offer(segment)
                    }
                }
            }
        }
    }

    /**
     * Streaming download optimized for mobile
     */
    private suspend fun downloadSegmentStreaming(
        segment: SegmentTask,
        playlistDir: File,
        headers: Map<String, String>,
        buffer: ByteArray
    ): Long = withContext(Dispatchers.IO) {

        val segmentFile = File(playlistDir, segment.fileName)
        if (segmentFile.exists() && segmentFile.length() > 0) {
            return@withContext segmentFile.length()
        }

        val request = Request.Builder()
            .url(segment.url)
            .apply { headers.forEach { (key, value) -> addHeader(key, value) } }
            .build()

        httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IOException("Download failed: ${response.code}")
            }

            val inputStream = response.body!!.byteStream()
            val outputStream = segmentFile.outputStream().buffered(mobileConfig.bufferSize)

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
     * Parallel chunked download for large segments
     */
    private suspend fun downloadSegmentChunked(
        segment: SegmentTask,
        playlistDir: File,
        headers: Map<String, String>,
        buffer: ByteArray
    ): Long = coroutineScope {

        val segmentFile = File(playlistDir, segment.fileName)
        if (segmentFile.exists() && segmentFile.length() > 0) {
            return@coroutineScope segmentFile.length()
        }

        val contentLength = getContentLength(segment.url, headers)
            ?: return@coroutineScope downloadSegmentStreaming(segment, playlistDir, headers, buffer)

        if (contentLength <= mobileConfig.chunkSize) {
            return@coroutineScope downloadSegmentStreaming(segment, playlistDir, headers, buffer)
        }

        val chunks = ((contentLength + mobileConfig.chunkSize - 1) / mobileConfig.chunkSize).toInt()
        val randomAccessFile = RandomAccessFile(segmentFile, "rw")
        randomAccessFile.setLength(contentLength)

        try {
            val chunkJobs = (0 until chunks).map { chunkIndex ->
                async(Dispatchers.IO) {
                    val start = chunkIndex * mobileConfig.chunkSize.toLong()
                    val end = min(start + mobileConfig.chunkSize - 1, contentLength - 1)

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
     * Fast progress tracking with minimal overhead
     */
    private suspend fun fastProgressTracking(
        progressChannel: Channel<Long>,
        task: DownloadTask,
        totalDownloadedBytes: AtomicLong,
        downloadedSegments: AtomicInteger,
        totalSegments: AtomicInteger,
        onProgress: (Map<String, Any>) -> Unit
    ) {
        var lastUpdate = 0L
        val updateInterval = 500L // Balanced frequency

        for (bytesDownloaded in progressChannel) {
            val now = System.currentTimeMillis()

            if (now - lastUpdate >= updateInterval) {
                task.downloadedBytes = totalDownloadedBytes.get()
                sendProgress(task, onProgress)
                lastUpdate = now
            }
        }
    }

    // Optimized helper functions
    private suspend fun fetchPlaylistContentFast(url: String, headers: Map<String, String>): String {
        val request = Request.Builder()
            .url(url)
            .apply { headers.forEach { (key, value) -> addHeader(key, value) } }
            .build()

        return httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Failed to fetch: ${response.code}")
            response.body?.string() ?: throw IOException("Empty content")
        }
    }

    private suspend fun estimateSegmentSizes(
        segments: List<SegmentTask>,
        headers: Map<String, String>
    ): Long = coroutineScope {
        if (segments.isEmpty()) return@coroutineScope 500_000L

        val sampleSize = min(1, segments.size)
        val sampleSizes = segments.take(sampleSize).map { segment ->
            async(Dispatchers.IO) {
                getContentLength(segment.url, headers) ?: 200_000L
            }
        }.awaitAll()

        sampleSizes.average().toLong()
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

        return variants.sortedByDescending { it.bandwidth } // Highest quality first
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
                segments.add(SegmentTask(segmentUrl, segmentFileName, segmentDuration))
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
            "speed" to currentSpeed,
            "estimatedTimeRemaining" to if (currentSpeed > 0)
                ((task.totalBytes - task.downloadedBytes) / currentSpeed * 1000).toLong() else -1L
        ))
    }

    fun cleanup() {
        ioExecutor.shutdown()
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
    }
}