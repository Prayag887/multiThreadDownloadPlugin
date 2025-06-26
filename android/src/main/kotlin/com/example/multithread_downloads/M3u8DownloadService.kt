package com.example.multithread_downloads

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.Requirements
import java.io.File
import java.util.concurrent.Executors

@UnstableApi
class M3u8DownloadService : DownloadService(FOREGROUND_NOTIFICATION_ID) {

    companion object {
        private const val FOREGROUND_NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "m3u8_download_channel"

        @Volatile
        private var downloadManager: DownloadManager? = null

        @Synchronized
        fun getDownloadManager(context: Context): DownloadManager {
            if (downloadManager == null) {
                downloadManager = createDownloadManager(context.applicationContext)
            }
            return downloadManager!!
        }

        private fun createDownloadManager(context: Context): DownloadManager {
            val cacheDir = File(context.cacheDir, "m3u8_downloads")
            val databaseProvider = StandaloneDatabaseProvider(context)

            val cache = SimpleCache(
                cacheDir,
                LeastRecentlyUsedCacheEvictor(100 * 1024 * 1024L),
                databaseProvider
            )

            val httpDataSourceFactory = DefaultHttpDataSource.Factory()
                .setUserAgent(Util.getUserAgent(context, "M3U8Downloader"))
                .setConnectTimeoutMs(30000)
                .setReadTimeoutMs(30000)

            val cacheDataSourceFactory = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(httpDataSourceFactory)

            return DownloadManager(
                context,
                databaseProvider,
                cache,
                cacheDataSourceFactory,
                Executors.newFixedThreadPool(6)
            ).apply {
                maxParallelDownloads = 6
                minRetryCount = 3
                downloadManager?.requirements = Requirements(Requirements.NETWORK_UNMETERED)
                return downloadManager!!
            }
        }
    }

    override fun getDownloadManager(): DownloadManager =
        Companion.getDownloadManager(this)

    override fun getScheduler() = null

    override fun getForegroundNotification(
        downloads: MutableList<Download>,
        notMetRequirements: Int
    ): Notification {
        createNotificationChannel()

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("M3U8 Downloads")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        when {
            downloads.isEmpty() -> {
                builder.setContentText("Ready for downloads")
            }
            notMetRequirements != 0 -> {
                builder.setContentText("Waiting for connection...")
                    .setSmallIcon(android.R.drawable.stat_sys_warning)
            }
            else -> {
                val activeDownloads = downloads.filter {
                    it.state == Download.STATE_DOWNLOADING || it.state == Download.STATE_QUEUED
                }

                if (activeDownloads.isNotEmpty()) {
                    builder.setContentText("Downloading ${activeDownloads.size} file(s)")

                    // Show progress for first active download
                    val firstActive = activeDownloads.firstOrNull { it.state == Download.STATE_DOWNLOADING }
                    firstActive?.let { download ->
                        if (download.contentLength > 0) {
                            val progress = ((download.bytesDownloaded * 100) / download.contentLength).toInt()
                            builder.setProgress(100, progress, false)
                        } else {
                            builder.setProgress(0, 0, true)
                        }
                    }
                } else {
                    builder.setContentText("Downloads completed")
                }
            }
        }

        return builder.build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            if (notificationManager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "M3U8 Downloads",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "M3U8/HLS download progress"
                    setShowBadge(false)
                    enableVibration(false)
                    setSound(null, null)
                }
                notificationManager.createNotificationChannel(channel)
            }
        }
    }
}