import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

class MultithreadedDownloads {
  static const MethodChannel _channel = MethodChannel('multithread_downloads');
  static const EventChannel _progressChannel = EventChannel(
      'multithread_downloads/progress');

  static Stream<DownloadProgress>? _progressStream;

  static Stream<DownloadProgress> get progressStream {
    _progressStream ??= _progressChannel
        .receiveBroadcastStream()
        .map((event) =>
        DownloadProgress.fromMap(Map<String, dynamic>.from(event)));
    return _progressStream!;
  }

  // ==================== Regular HTTP Downloads ====================

  static Future<bool> startDownload({
    required List<String> urls,
    required String filePath,
    Map<String, String>? headers,
    int maxConcurrentTasks = 4,
    int retryCount = 3,
    int timeoutSeconds = 30,
  }) async {
    try {
      final result = await _channel.invokeMethod('startDownload', {
        'urls': urls,
        'filePath': filePath,
        'headers': headers ?? {},
        'maxConcurrentTasks': maxConcurrentTasks,
        'retryCount': retryCount,
        'timeoutSeconds': timeoutSeconds,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> pauseDownload(String url) async {
    try {
      final result = await _channel.invokeMethod('pauseDownload', {'url': url});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> resumeDownload(String url) async {
    try {
      final result = await _channel.invokeMethod(
          'resumeDownload', {'url': url});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> cancelDownload(String url) async {
    try {
      final result = await _channel.invokeMethod(
          'cancelDownload', {'url': url});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  // Batch operations for multiple URLs
  static Future<bool> pauseAllDownloads() async {
    try {
      final result = await _channel.invokeMethod('pauseAllDownloads');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> resumeAllDownloads() async {
    try {
      final result = await _channel.invokeMethod('resumeAllDownloads');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> cancelAllDownloads() async {
    try {
      final result = await _channel.invokeMethod('cancelAllDownloads');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> pauseDownloads(List<String> urls) async {
    try {
      final result = await _channel.invokeMethod(
          'pauseDownloads', {'urls': urls});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> resumeDownloads(List<String> urls) async {
    try {
      final result = await _channel.invokeMethod(
          'resumeDownloads', {'urls': urls});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> cancelDownloads(List<String> urls) async {
    try {
      final result = await _channel.invokeMethod(
          'cancelDownloads', {'urls': urls});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> getDownloadStatus(String url) async {
    try {
      final result = await _channel.invokeMethod(
          'getDownloadStatus', {'url': url});
      return Map<String, dynamic>.from(result);
    } catch (e) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getDownloadStatuses(
      List<String> urls) async {
    try {
      final result = await _channel.invokeMethod(
          'getDownloadStatuses', {'urls': urls});
      return List<Map<String, dynamic>>.from(result);
    } catch (e) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getAllDownloads() async {
    try {
      final result = await _channel.invokeMethod('getAllDownloads');
      return List<Map<String, dynamic>>.from(result);
    } catch (e) {
      return [];
    }
  }

  static Future<bool> clearCompletedDownloads() async {
    try {
      final result = await _channel.invokeMethod('clearCompletedDownloads');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  // Get overall progress for batch downloads
  static Future<BatchDownloadProgress?> getBatchProgress() async {
    try {
      final result = await _channel.invokeMethod('getBatchProgress');
      return BatchDownloadProgress.fromMap(Map<String, dynamic>.from(result));
    } catch (e) {
      return null;
    }
  }

  // ==================== M3U8/HLS Downloads ====================

  /// Start downloading an M3U8/HLS stream
  ///
  /// [url] - The M3U8 playlist URL
  /// [filePath] - Local file path where the video will be saved
  /// [headers] - Optional HTTP headers for authentication or other purposes
  static Future<bool> startM3u8Download({
    required String url,
    required String filePath,
    Map<String, String>? headers,
  }) async {
    try {
      final result = await _channel.invokeMethod('startM3u8Download', {
        'url': url,
        'filePath': filePath,
        'headers': headers ?? {},
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Pause an M3U8 download
  static Future<bool> pauseM3u8Download(String url) async {
    try {
      final result = await _channel.invokeMethod(
          'pauseM3u8Download', {'url': url});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Resume a paused M3U8 download
  static Future<bool> resumeM3u8Download(String url) async {
    try {
      final result = await _channel.invokeMethod(
          'resumeM3u8Download', {'url': url});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Cancel an M3U8 download
  static Future<bool> cancelM3u8Download(String url) async {
    try {
      final result = await _channel.invokeMethod(
          'cancelM3u8Download', {'url': url});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Get the status of a specific M3U8 download
  static Future<Map<String, dynamic>?> getM3u8DownloadStatus(String url) async {
    try {
      final result = await _channel.invokeMethod(
          'getM3u8DownloadStatus', {'url': url});
      return result != null ? Map<String, dynamic>.from(result) : null;
    } catch (e) {
      return null;
    }
  }

  /// Get all M3U8 downloads
  static Future<List<Map<String, dynamic>>> getAllM3u8Downloads() async {
    try {
      final result = await _channel.invokeMethod('getAllM3u8Downloads');
      return List<Map<String, dynamic>>.from(result);
    } catch (e) {
      return [];
    }
  }

  /// Clear all completed M3U8 downloads from the manager
  static Future<bool> clearCompletedM3u8Downloads() async {
    try {
      final result = await _channel.invokeMethod('clearCompletedM3u8Downloads');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  // ==================== Convenience Methods ====================

  /// Check if a URL is an M3U8 playlist
  static bool isM3u8Url(String url) {
    return url.toLowerCase().contains('.m3u8') ||
        url.toLowerCase().contains('m3u8');
  }
}

class DownloadProgress {
  final String url;
  final String filePath;
  final int progress;
  final int bytesDownloaded;
  final int totalBytes;
  late final DownloadStatus status;
  final String? error;
  final double speed;
  final DownloadType type;

  DownloadProgress({
    required this.url,
    required this.filePath,
    required this.progress,
    required this.bytesDownloaded,
    required this.totalBytes,
    required this.status,
    this.error,
    required this.speed,
    this.type = DownloadType.http_batch,
  });

  factory DownloadProgress.fromMap(Map<String, dynamic> map) {
    return DownloadProgress(
      url: map['url'] ?? '',
      filePath: map['filePath'] ?? '',
      progress: map['progress'] ?? 0,
      bytesDownloaded: map['bytesDownloaded'] ?? 0,
      totalBytes: map['totalBytes'] ?? 0,

      // Safe enum parsing for `DownloadStatus`
      status: map['status'] is String
          ? DownloadStatus.values.byName(map['status'])
          : DownloadStatus.values[(map['status'] ?? 0).clamp(0, DownloadStatus.values.length - 1)],

      error: map['error'],
      speed: (map['speed'] ?? 0.0).toDouble(),

      // Safe enum parsing for `DownloadType`
      type: map['type'] is String
          ? DownloadType.values.byName(map['type'])
          : map['type'] != null
          ? DownloadType.values[(map['type']).clamp(0, DownloadType.values.length - 1)]
          : (MultithreadedDownloads.isM3u8Url(map['url'] ?? '')
          ? DownloadType.m3u8
          : DownloadType.http_batch),
    );
  }


  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'filePath': filePath,
      'progress': progress,
      'bytesDownloaded': bytesDownloaded,
      'totalBytes': totalBytes,
      'status': status.index,
      'error': error,
      'speed': speed,
      'type': type.index,
    };
  }

  /// Format speed in human readable format
  String get formattedSpeed {
    if (speed < 1024) {
      return '${speed.toStringAsFixed(1)} B/s';
    } else if (speed < 1024 * 1024) {
      return '${(speed / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(speed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
  }

  /// Format bytes in human readable format
  String get formattedSize {
    return _formatBytes(bytesDownloaded) + ' / ' + _formatBytes(totalBytes);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  /// Check if download is in progress
  bool get isInProgress => status == DownloadStatus.downloading;

  /// Check if download is completed
  bool get isCompleted => status == DownloadStatus.completed;

  /// Check if download is paused
  bool get isPaused => status == DownloadStatus.paused;

  /// Check if download has failed
  bool get hasFailed => status == DownloadStatus.failed;

  /// Check if download is cancelled
  bool get isCancelled => status == DownloadStatus.cancelled;

  /// Check if download is M3U8/HLS type
  bool get isM3u8 => type == DownloadType.m3u8;
}

class BatchDownloadProgress {
  final List<String> urls;
  final int overallProgress;
  final int totalBytesDownloaded;
  final int totalBytes;
  final int completedDownloads;
  final int totalDownloads;
  final double averageSpeed;
  final List<DownloadProgress> individualProgress;

  BatchDownloadProgress({
    required this.urls,
    required this.overallProgress,
    required this.totalBytesDownloaded,
    required this.totalBytes,
    required this.completedDownloads,
    required this.totalDownloads,
    required this.averageSpeed,
    required this.individualProgress,
  });

  factory BatchDownloadProgress.fromMap(Map<String, dynamic> map) {
    return BatchDownloadProgress(
      urls: List<String>.from(map['urls'] ?? []),
      overallProgress: map['overallProgress'] ?? 0,
      totalBytesDownloaded: map['totalBytesDownloaded'] ?? 0,
      totalBytes: map['totalBytes'] ?? 0,
      completedDownloads: map['completedDownloads'] ?? 0,
      totalDownloads: map['totalDownloads'] ?? 0,
      averageSpeed: (map['averageSpeed'] ?? 0.0).toDouble(),
      individualProgress: (map['individualProgress'] as List<dynamic>? ?? [])
          .map((item) => DownloadProgress.fromMap(Map<String, dynamic>.from(item)))
          .toList(),
    );
  }

  /// Format average speed in human readable format
  String get formattedAverageSpeed {
    if (averageSpeed < 1024) {
      return '${averageSpeed.toStringAsFixed(1)} B/s';
    } else if (averageSpeed < 1024 * 1024) {
      return '${(averageSpeed / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(averageSpeed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
  }

  /// Get progress percentage as double (0.0 to 1.0)
  double get progressPercentage => overallProgress / 100.0;

  /// Check if all downloads are completed
  bool get isAllCompleted => completedDownloads == totalDownloads;

  /// Get remaining downloads count
  int get remainingDownloads => totalDownloads - completedDownloads;
}

enum DownloadStatus {
  pending,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

enum DownloadType {
  http_batch, //regular HTTP download
  m3u8,
}