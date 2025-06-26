@file:OptIn(UnstableApi::class)

package com.example.multithread_downloads

import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import android.content.Context

@UnstableApi
object CacheManager {

    private const val CACHE_SIZE = 100 * 1024 * 1024L // 100MB
    private const val CONNECT_TIMEOUT_MS = 15000
    private const val READ_TIMEOUT_MS = 15000

    // Default headers for audio/video content
    private val DEFAULT_HEADERS = mapOf(
        "User-Agent" to "ExoPlayer-M3U8-Downloader/1.0",
        "Accept" to "*/*",
        "Accept-Encoding" to "gzip, deflate",
        "Connection" to "keep-alive"
    )

    @Volatile
    private var downloadCache: SimpleCache? = null

    @Volatile
    private var databaseProvider: StandaloneDatabaseProvider? = null

    /**
     * Initialize cache with custom directory
     * Call this once during app startup
     */
    @Synchronized
    fun initializeCache(cacheDirectory: File) {
        if (downloadCache == null) {
            // Ensure cache directory exists
            if (!cacheDirectory.exists()) {
                cacheDirectory.mkdirs()
            }

            // Create database provider for cache metadata
            databaseProvider = StandaloneDatabaseProvider(cacheDirectory)

            // Create cache with LRU eviction policy
            downloadCache = SimpleCache(
                cacheDirectory,
                LeastRecentlyUsedCacheEvictor(CACHE_SIZE),
                databaseProvider!!
            )
        }
    }

    /**
     * Get cache data source factory for downloads
     * @param customHeaders Additional headers to include
     * @param allowCacheWrites Whether to allow writing to cache (true for downloads, false for playback)
     */
    @Synchronized
    fun getCacheDataFactory(
        customHeaders: Map<String, String> = emptyMap(),
        allowCacheWrites: Boolean = true
    ): CacheDataSource.Factory {
        val cache = downloadCache ?: throw IllegalStateException("Cache not initialized. Call initializeCache() first.")

        // Merge default headers with custom headers
        val allHeaders = DEFAULT_HEADERS.toMutableMap().apply {
            putAll(customHeaders)
        }

        // Create HTTP data source factory with headers
        val upstreamFactory = DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(allHeaders)
            .setConnectTimeoutMs(CONNECT_TIMEOUT_MS)
            .setReadTimeoutMs(READ_TIMEOUT_MS)
            .setAllowCrossProtocolRedirects(true)

        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstreamFactory)
            .apply {
                if (!allowCacheWrites) {
                    // Read-only for playback
                    setCacheWriteDataSinkFactory(null)
                }
                // Ignore cache errors and fallback to upstream
                setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            }
    }

    /**
     * Get cache data source factory specifically for M3U8 downloads
     */
    fun getM3u8CacheDataFactory(customHeaders: Map<String, String> = emptyMap()): CacheDataSource.Factory {
        val m3u8Headers = mapOf(
            "Accept" to "application/vnd.apple.mpegurl, application/x-mpegurl, */*",
            "Accept-Language" to "en-US,en;q=0.9"
        )

        return getCacheDataFactory(
            customHeaders = customHeaders + m3u8Headers,
            allowCacheWrites = true
        )
    }

    /**
     * Get cache data source factory for playback (read-only)
     */
    fun getPlaybackCacheDataFactory(customHeaders: Map<String, String> = emptyMap()): CacheDataSource.Factory {
        return getCacheDataFactory(
            customHeaders = customHeaders,
            allowCacheWrites = false
        )
    }

    /**
     * Get the underlying cache instance
     */
    fun getCache(): SimpleCache? = downloadCache

    /**
     * Clear all cached data
     */
    fun clearCache() {
        downloadCache?.let { cache ->
            try {
                val keys = cache.keys
                for (key in keys) {
                    cache.removeResource(key)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun getCacheStats(): CacheStats {
        val cache = downloadCache
        return if (cache != null) {
            CacheStats(
                totalBytes = cache.cacheSpace,
                usedBytes = cache.cacheSpace - cache.cacheSpace, // This is approximate
                keyCount = cache.keys.size,
                isInitialized = true
            )
        } else {
            CacheStats(0, 0, 0, false)
        }
    }

    fun release() {
        downloadCache?.release()
        downloadCache = null
        databaseProvider = null
    }

    fun isInitialized(): Boolean = downloadCache != null
}

data class CacheStats(
    val totalBytes: Long,
    val usedBytes: Long,
    val keyCount: Int,
    val isInitialized: Boolean
) {
    val freeBytes: Long get() = totalBytes - usedBytes
    val usagePercentage: Float get() = if (totalBytes > 0) (usedBytes.toFloat() / totalBytes) * 100f else 0f
}

object CacheHelper {

    fun initializeWithAppCache(applicationCacheDir: File) {
        val cacheDir = File(applicationCacheDir, "exoplayer_cache")
        CacheManager.initializeCache(cacheDir)
    }

    fun initializeWithCustomPath(customPath: String) {
        val cacheDir = File(customPath)
        CacheManager.initializeCache(cacheDir)
    }

    fun getAudioCacheFactory(): CacheDataSource.Factory {
        val audioHeaders = mapOf(
            "Accept" to "audio/*, application/octet-stream",
            "Range" to "bytes=0-"
        )
        return CacheManager.getCacheDataFactory(audioHeaders)
    }

    fun getVideoCacheFactory(): CacheDataSource.Factory {
        val videoHeaders = mapOf(
            "Accept" to "video/*, application/octet-stream",
            "Accept-Encoding" to "identity" // Disable compression for video
        )
        return CacheManager.getCacheDataFactory(videoHeaders)
    }
}