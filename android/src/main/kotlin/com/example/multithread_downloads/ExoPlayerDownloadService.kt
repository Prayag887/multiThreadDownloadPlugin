package com.example.multithread_downloads

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.offline.DefaultDownloadIndex
import androidx.media3.exoplayer.offline.DefaultDownloaderFactory
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.Requirements
import java.io.File
import java.util.concurrent.Executor

@UnstableApi
class M3u8DownloadService : DownloadService(
    FOREGROUND_NOTIFICATION_ID,
    DEFAULT_FOREGROUND_NOTIFICATION_UPDATE_INTERVAL,
    CHANNEL_ID,
    1,
    1
) {

    companion object {
        private const val FOREGROUND_NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "download_channel"
        private const val JOB_ID = 1000

        private var downloadManager: DownloadManager? = null

        fun getDownloadManager(context: Context): DownloadManager {
            if (downloadManager == null) {
                downloadManager = createDownloadManager(context)
            }
            return downloadManager!!
        }

        private fun createDownloadManager(context: Context): DownloadManager {
            // Create cache directory
            val cacheDir = File(context.cacheDir, "exoplayer_downloads")
            if (!cacheDir.exists()) {
                cacheDir.mkdirs()
            }

            // Create database provider
            val databaseProvider = StandaloneDatabaseProvider(context)

            // Create cache
            val cache = SimpleCache(
                cacheDir,
                NoOpCacheEvictor(),
                databaseProvider
            )

            // Create data source factory
            val httpDataSourceFactory = DefaultHttpDataSource.Factory()
                .setUserAgent("ExoPlayer-M3U8-Downloader")
                .setConnectTimeoutMs(30000)
                .setReadTimeoutMs(30000)

            val cacheDataSourceFactory = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(httpDataSourceFactory)

            // Create download index
            val downloadIndex = DefaultDownloadIndex(databaseProvider)

            // Create and configure download manager
            return DownloadManager(
                context,
                downloadIndex,
                DefaultDownloaderFactory(cacheDataSourceFactory, Executor { it.run() })
            ).apply {
                requirements = Requirements(Requirements.NETWORK)
                maxParallelDownloads = 3
                minRetryCount = 3
            }
        }
    }

    override fun getDownloadManager(): DownloadManager {
        return Companion.getDownloadManager(this)
    }

    override fun getScheduler(): androidx.media3.exoplayer.scheduler.Scheduler? {
        return null // We don't need scheduling for this use case
    }

    override fun getForegroundNotification(
        downloads: MutableList<Download>,
        notMetRequirements: Int
    ): Notification {
        return createNotification(this, downloads, notMetRequirements)
    }

    private fun createNotification(
        context: Context,
        downloads: MutableList<Download>,
        notMetRequirements: Int
    ): Notification {
        createNotificationChannel(context)

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("M3U8 Downloads")
            .setOngoing(true)
            .setShowWhen(false)

        when {
            downloads.isEmpty() -> {
                builder.setContentText("No active downloads")
            }
            notMetRequirements != 0 -> {
                builder.setContentText("Waiting for network connection")
            }
            else -> {
                val downloadingCount = downloads.count { it.state == Download.STATE_DOWNLOADING }
                val queuedCount = downloads.count { it.state == Download.STATE_QUEUED }
                val completedCount = downloads.count { it.state == Download.STATE_COMPLETED }

                val text = when {
                    downloadingCount > 0 -> "Downloading $downloadingCount file(s)"
                    queuedCount > 0 -> "$queuedCount file(s) queued"
                    completedCount > 0 -> "All downloads completed"
                    else -> "Processing downloads"
                }
                builder.setContentText(text)

                // Show progress for active downloads
                val activeDownload = downloads.firstOrNull { it.state == Download.STATE_DOWNLOADING }
                activeDownload?.let { download ->
                    if (download.contentLength > 0) {
                        val progress = (download.bytesDownloaded * 100 / download.contentLength).toInt()
                        builder.setProgress(100, progress, false)
                    } else {
                        builder.setProgress(0, 0, true)
                    }
                }
            }
        }

        return builder.build()
    }

    private fun createNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (notificationManager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "M3U8 Downloads",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shows progress of M3U8/HLS downloads"
                    setShowBadge(false)
                }
                notificationManager.createNotificationChannel(channel)
            }
        }
    }
}