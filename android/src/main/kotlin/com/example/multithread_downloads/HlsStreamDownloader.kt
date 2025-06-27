package com.example.multithread_downloads

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.channels.Channel
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

class HlsDownloader {

    suspend fun downloadHlsStreamOptimized(
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
        val totalSegmentsCount = AtomicInteger(0)

        // Step 1: Fetch master playlist
        val masterContent = fetchPlaylistContent(task.url, task.headers)
        val variants = parseMasterPlaylist(masterContent, baseUri)

        // Step 2: Adaptive quality selection - choose best quality that can be handled
        val selectedVariant = selectOptimalVariant(variants)

        // Step 3: Pipeline approach - fetch variant playlists and start downloading segments immediately
        val segmentChannel = Channel<SegmentTask>(capacity = Channel.UNLIMITED)
        val progressChannel = Channel<Long>(capacity = Channel.UNLIMITED)

        // Producer: Fetch variant playlists and feed segments to channel
        val playlistJob = launch {
            variants.take(2).forEach { variant -> // Download top 2 qualities for redundancy
                launch {
                    try {
                        val variantContent = fetchPlaylistContent(variant.url, task.headers)
                        val segments = parseVariantPlaylist(variantContent, baseUri, variant.fileName)

                        totalSegmentsCount.addAndGet(segments.size)

                        segments.forEach { segment ->
                            segmentChannel.send(segment)
                        }

                        // Create local playlist file
                        createLocalPlaylist(variant, segments, playlistDir)
                    } catch (e: Exception) {
                        println("Error processing variant ${variant.url}: ${e.message}")
                    }
                }
            }
        }

        // Consumer: Download segments with extreme parallelism
        val segmentSemaphore = Semaphore(100) // Much higher concurrency for segments
        val downloadJobs = mutableListOf<Job>()

        repeat(50) { // 50 concurrent segment downloaders
            val job = launch {
                for (segment in segmentChannel) {
                    segmentSemaphore.withPermit {
                        try {
                            val bytesDownloaded = downloadSegmentOptimized(segment, playlistDir, task.headers)
                            totalDownloadedBytes.addAndGet(bytesDownloaded)
                            progressChannel.send(bytesDownloaded)
                        } catch (e: Exception) {
                            println("Failed to download segment ${segment.fileName}: ${e.message}")
                        }
                    }
                }
            }
            downloadJobs.add(job)
        }

        // Progress updater
        val progressJob = launch {
            var lastUpdate = 0L
            var segmentCount = 0

            for (bytes in progressChannel) {
                segmentCount++
                task.downloadedBytes = totalDownloadedBytes.get()

                val now = System.currentTimeMillis()
                if (now - lastUpdate > 500 || segmentCount % 10 == 0) { // Update every 500ms or 10 segments
                    task.status = DownloadStatus.DOWNLOADING
                    sendProgress(task, onProgress)
                    lastUpdate = now
                }

                // Break if all segments are downloaded
                if (segmentCount >= totalSegmentsCount.get() && totalSegmentsCount.get() > 0) {
                    break
                }
            }
        }

        // Wait for playlist parsing to complete
        playlistJob.join()
        segmentChannel.close()

        // Wait for all downloads to complete
        downloadJobs.joinAll()
        progressChannel.close()
        progressJob.join()

        // Create master playlist
        createMasterPlaylist(variants.take(2), playlistDir)

        task.status = DownloadStatus.COMPLETED
        task.downloadedBytes = totalDownloadedBytes.get()
        task.filePath = File(playlistDir, "master.m3u8").absolutePath
        sendProgress(task, onProgress)
    }

    private suspend fun fetchPlaylistContent(url: String, headers: Map<String, String>): String {
        val request = Request.Builder()
            .url(url)
            .apply { headers.forEach { (key, value) -> addHeader(key, value) } }
            .build()

        return HttpClientConfig.client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Failed to fetch playlist: $url")
            response.body?.string() ?: throw IOException("Empty playlist content")
        }
    }

    private fun parseMasterPlaylist(content: String, baseUri: HttpUrl): List<VariantPlaylist> {
        val variants = mutableListOf<VariantPlaylist>()
        val lines = content.lines()
        var currentBandwidth = 0L

        for (i in lines.indices) {
            val line = lines[i].trim()

            if (line.startsWith("#EXT-X-STREAM-INF:")) {
                // Extract bandwidth
                val bandwidthMatch = Regex("BANDWIDTH=(\\d+)").find(line)
                currentBandwidth = bandwidthMatch?.groupValues?.get(1)?.toLongOrNull() ?: 0L
            } else if (line.isNotEmpty() && !line.startsWith("#")) {
                val variantUrl = baseUri.resolve(line)!!.toString()
                val variantFileName = line.substringAfterLast("/")
                variants.add(VariantPlaylist(variantUrl, variantFileName, currentBandwidth))
            }
        }

        // Sort by bandwidth (highest first)
        return variants.sortedByDescending { it.bandwidth }
    }

    private fun selectOptimalVariant(variants: List<VariantPlaylist>): VariantPlaylist {
        // For maximum speed, select the highest quality
        // In production, you might want to implement adaptive logic based on network speed
        return variants.firstOrNull() ?: variants.first()
    }

    private fun parseVariantPlaylist(content: String, baseUri: HttpUrl, variantName: String): List<SegmentTask> {
        val segments = mutableListOf<SegmentTask>()
        val lines = content.lines()

        for (line in lines) {
            val trimmedLine = line.trim()
            if (trimmedLine.isNotEmpty() && !trimmedLine.startsWith("#")) {
                val segmentUrl = baseUri.resolve(trimmedLine)!!.toString()
                val segmentFileName = "${variantName}_${trimmedLine.substringAfterLast("/")}"
                segments.add(SegmentTask(segmentUrl, segmentFileName))
            }
        }

        return segments
    }

    private suspend fun downloadSegmentOptimized(
        segment: SegmentTask,
        playlistDir: File,
        headers: Map<String, String>
    ): Long {
        val segmentFile = File(playlistDir, segment.fileName)

        // Skip if already exists and has content
        if (segmentFile.exists() && segmentFile.length() > 0) {
            return segmentFile.length()
        }

        val request = Request.Builder()
            .url(segment.url)
            .apply { headers.forEach { (key, value) -> addHeader(key, value) } }
            .build()

        return HttpClientConfig.client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IOException("Failed to download segment: ${segment.url}")
            }

            val bytes = response.body!!.bytes()
            segmentFile.writeBytes(bytes)
            bytes.size.toLong()
        }
    }

    private fun createLocalPlaylist(variant: VariantPlaylist, segments: List<SegmentTask>, playlistDir: File) {
        val playlistContent = buildString {
            appendLine("#EXTM3U")
            appendLine("#EXT-X-VERSION:3")
            appendLine("#EXT-X-TARGETDURATION:10")
            appendLine("#EXT-X-MEDIA-SEQUENCE:0")

            segments.forEach { segment ->
                appendLine("#EXTINF:10.0,")
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
                appendLine("#EXT-X-STREAM-INF:BANDWIDTH=${variant.bandwidth}")
                appendLine(variant.fileName)
            }
        }

        File(playlistDir, "master.m3u8").writeText(masterContent)
    }

    private fun sendProgress(task: DownloadTask, onProgress: (Map<String, Any>) -> Unit) {
        val currentTime = System.currentTimeMillis()
        val timeElapsed = max(1L, currentTime - task.startTime)

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
}