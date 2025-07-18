import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';

class MultithreadedDownloads {
  static const MethodChannel _channel = MethodChannel('multithread_downloads');
  static const EventChannel _progressChannel = EventChannel('multithread_downloads/progress');

  static Stream<DownloadProgress>? _progressStream;
  static Stream<BatchDownloadProgress>? _batchProgressStream;
  // ✅ NEW: HLS Queue progress stream for iOS
  static Stream<HlsQueueProgress>? _hlsQueueProgressStream;

  // Keep a reference to your server so you can close it if needed
  HttpServer? _localServer;

  Future<void> startLocalHttpServer(String directoryPath, int port) async {
    final dir = Directory(directoryPath);

    // Validate directory
    if (!await dir.exists()) {
      throw Exception('Directory does not exist: $directoryPath');
    }

    // List files for debugging
    print('Files in directory:');
    await for (var entity in dir.list()) {
      print('  ${entity.path}');
    }

    var handler = createStaticHandler(
      directoryPath,
      serveFilesOutsidePath: true,
      listDirectories: true,
    );

    // Add middleware for logging
    var loggedHandler = Pipeline()
        .addMiddleware(logRequests())
        .addHandler(handler);

    _localServer = await io.serve(loggedHandler, 'localhost', port);
    print('Server started at http://localhost:$port');
    print('Serving: ${dir.absolute.path}');
  }

  Future<void> stopLocalHttpServer() async {
    await _localServer?.close(force: true);
    _localServer = null;
  }

  static Stream<DownloadProgress> get progressStream {
    _progressStream ??= _progressChannel
        .receiveBroadcastStream()
        .map((event) => DownloadProgress.fromMap(Map<String, dynamic>.from(event)));
    return _progressStream!;
  }

  static Stream<BatchDownloadProgress> get batchProgressStream {
    _batchProgressStream ??= _progressChannel
        .receiveBroadcastStream()
        .map((event) => BatchDownloadProgress.fromMap(Map<String, dynamic>.from(event)));
    return _batchProgressStream!;
  }

  // ✅ NEW: HLS Queue progress stream (iOS only)
  static Stream<HlsQueueProgress> get hlsQueueProgressStream {
    _hlsQueueProgressStream ??= _progressChannel
        .receiveBroadcastStream()
        .where((event) => Platform.isIOS && event['downloadType'] == 'hls_queue')
        .map((event) => HlsQueueProgress.fromMap(Map<String, dynamic>.from(event)));
    return _hlsQueueProgressStream!;
  }

  // ✅ NEW: Combined progress stream for all download types
  static Stream<CombinedDownloadProgress> get combinedProgressStream {
    return _progressChannel
        .receiveBroadcastStream()
        .map((event) => CombinedDownloadProgress.fromMap(Map<String, dynamic>.from(event)));
  }

  // EXISTING METHOD - Keep exactly as is for Android compatibility
  static Future<bool> startDownload({
    required List<String> urls,
    required String filePath,
    String fileName = '',
    Map<String, String>? headers,
    int maxConcurrentTasks = 4,
    int retryCount = 3,
    int timeoutSeconds = 30,
    int priority = 0, // ✅ NEW: Add priority parameter for iOS
  }) async {
    try {
      final result = await _channel.invokeMethod('startDownload', {
        'urls': urls,
        'fileName': fileName,
        'filePath': filePath,
        'headers': headers ?? {},
        'maxConcurrentTasks': maxConcurrentTasks,
        'retryCount': retryCount,
        'timeoutSeconds': timeoutSeconds,
        'priority': priority, // ✅ NEW: Pass priority for iOS HLS detection
      });

      // ✅ NEW: Handle enhanced iOS response
      if (Platform.isIOS && result is Map) {
        print('📱 iOS Smart Download Result: $result');
        return result['success'] == true;
      }

      return result == true;
    } catch (e) {
      print('❌ Download error: $e');
      return false;
    }
  }

  // ✅ NEW: iOS HLS Queue Methods

  /// Queue multiple HLS downloads (iOS only)
  static Future<HlsQueueResult?> queueHlsDownloads({
    required List<String> urls,
    required String basePath,
    Map<String, String>? headers,
    int priority = 0,
  }) async {
    if (!Platform.isIOS) {
      print('⚠️ HLS queue is only available on iOS');
      return null;
    }

    try {
      final result = await _channel.invokeMethod('queueHlsDownloads', {
        'urls': urls,
        'basePath': basePath,
        'headers': headers ?? {},
        'priority': priority,
      });

      return HlsQueueResult.fromMap(Map<String, dynamic>.from(result));
    } catch (e) {
      print('❌ HLS queue error: $e');
      return null;
    }
  }

  /// Queue single HLS download (iOS only)
  static Future<HlsSingleQueueResult?> queueSingleHlsDownload({
    required String url,
    required String basePath,
    Map<String, String>? headers,
    int priority = 0,
  }) async {
    if (!Platform.isIOS) {
      print('⚠️ HLS queue is only available on iOS');
      return null;
    }

    try {
      final result = await _channel.invokeMethod('queueSingleHlsDownload', {
        'url': url,
        'basePath': basePath,
        'headers': headers ?? {},
        'priority': priority,
      });

      return HlsSingleQueueResult.fromMap(Map<String, dynamic>.from(result));
    } catch (e) {
      print('❌ HLS single queue error: $e');
      return null;
    }
  }

  /// Get HLS queue status (iOS only)
  static Future<HlsQueueStatus?> getHlsQueueStatus() async {
    if (!Platform.isIOS) {
      print('⚠️ HLS queue is only available on iOS');
      return null;
    }

    try {
      final result = await _channel.invokeMethod('getHlsQueueStatus');
      return HlsQueueStatus.fromMap(Map<String, dynamic>.from(result));
    } catch (e) {
      print('❌ HLS queue status error: $e');
      return null;
    }
  }

  /// Pause HLS queue (iOS only)
  static Future<bool> pauseHlsQueue() async {
    if (!Platform.isIOS) {
      print('⚠️ HLS queue is only available on iOS');
      return false;
    }

    try {
      final result = await _channel.invokeMethod('pauseHlsQueue');
      return result == true;
    } catch (e) {
      print('❌ HLS queue pause error: $e');
      return false;
    }
  }

  /// Resume HLS queue (iOS only)
  static Future<bool> resumeHlsQueue() async {
    if (!Platform.isIOS) {
      print('⚠️ HLS queue is only available on iOS');
      return false;
    }

    try {
      final result = await _channel.invokeMethod('resumeHlsQueue');
      return result == true;
    } catch (e) {
      print('❌ HLS queue resume error: $e');
      return false;
    }
  }

  /// Cancel HLS queue (iOS only)
  static Future<bool> cancelHlsQueue() async {
    if (!Platform.isIOS) {
      print('⚠️ HLS queue is only available on iOS');
      return false;
    }

    try {
      final result = await _channel.invokeMethod('cancelHlsQueue');
      return result == true;
    } catch (e) {
      print('❌ HLS queue cancel error: $e');
      return false;
    }
  }

  // EXISTING METHODS - Keep exactly as is for Android compatibility

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
      final result = await _channel.invokeMethod('resumeDownload', {'url': url});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> cancelDownload(String url) async {
    try {
      final result = await _channel.invokeMethod('cancelDownload', {'url': url});
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
      final result = await _channel.invokeMethod('pauseDownloads', {'urls': urls});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> resumeDownloads(List<String> urls) async {
    try {
      final result = await _channel.invokeMethod('resumeDownloads', {'urls': urls});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> cancelDownloads(List<String> urls) async {
    try {
      final result = await _channel.invokeMethod('cancelDownloads', {'urls': urls});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> getDownloadStatus(String url) async {
    try {
      final result = await _channel.invokeMethod('getDownloadStatus', {'url': url});
      return Map<String, dynamic>.from(result);
    } catch (e) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getDownloadStatuses(List<String> urls) async {
    try {
      final result = await _channel.invokeMethod('getDownloadStatuses', {'urls': urls});
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
}

// EXISTING CLASSES - Keep exactly as is for Android compatibility

class DownloadProgress {
  final String url;
  final String filePath;
  final int progress;
  final int bytesDownloaded;
  final int totalBytes;
  late final DownloadStatus status;
  final String? error;
  final double speed;

  DownloadProgress({
    required this.url,
    required this.filePath,
    required this.progress,
    required this.bytesDownloaded,
    required this.totalBytes,
    required this.status,
    this.error,
    required this.speed,
  });

  factory DownloadProgress.fromMap(Map<String, dynamic> map) {
    print('=== DEBUG fromMap ===');
    print('Full map: $map');

    // Check each field that could cause the error
    ['progress', 'bytesDownloaded', 'totalBytes', 'status', 'filePath'].forEach((key) {
      final value = map[key];
      print('$key: "$value" (type: ${value.runtimeType})');
    });
    print('====================');

    return DownloadProgress(
      url: map['url']?.toString() ?? '',
      filePath: map['filePath']?.toString() ?? '',
      progress: (map['progress'] as num?)?.toInt() ?? 0,      // Line 241
      bytesDownloaded: (map['bytesDownloaded'] as num?)?.toInt() ?? 0,  // Line 242
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,           // Line 243
      status: DownloadStatus.values[(map['status'] as num?)?.toInt() ?? 0],
      error: map['error']?.toString(),
      speed: (map['speed'] as num?)?.toDouble() ?? 0.0,
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
    };
  }
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
}

enum DownloadStatus {
  pending,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

// ✅ NEW: HLS Queue Classes for iOS

class HlsQueueResult {
  final bool success;
  final List<String> queueIds;
  final int count;
  final String? error;

  HlsQueueResult({
    required this.success,
    required this.queueIds,
    required this.count,
    this.error,
  });

  factory HlsQueueResult.fromMap(Map<String, dynamic> map) {
    return HlsQueueResult(
      success: map['success'] ?? false,
      queueIds: List<String>.from(map['queueIds'] ?? []),
      count: map['count'] ?? 0,
      error: map['error']?.toString(),
    );
  }
}

class HlsSingleQueueResult {
  final bool success;
  final String? queueId;
  final String? error;

  HlsSingleQueueResult({
    required this.success,
    this.queueId,
    this.error,
  });

  factory HlsSingleQueueResult.fromMap(Map<String, dynamic> map) {
    return HlsSingleQueueResult(
      success: map['success'] ?? false,
      queueId: map['queueId']?.toString(),
      error: map['error']?.toString(),
    );
  }
}

class HlsQueueStatus {
  final String status; // idle, processing, paused, cancelled
  final bool isProcessing;
  final int queueLength;
  final int totalQueued;
  final int totalCompleted;
  final int totalFailed;
  final String currentDownload;

  HlsQueueStatus({
    required this.status,
    required this.isProcessing,
    required this.queueLength,
    required this.totalQueued,
    required this.totalCompleted,
    required this.totalFailed,
    required this.currentDownload,
  });

  factory HlsQueueStatus.fromMap(Map<String, dynamic> map) {
    return HlsQueueStatus(
      status: map['status']?.toString() ?? 'idle',
      isProcessing: map['isProcessing'] ?? false,
      queueLength: map['queueLength'] ?? 0,
      totalQueued: map['totalQueued'] ?? 0,
      totalCompleted: map['totalCompleted'] ?? 0,
      totalFailed: map['totalFailed'] ?? 0,
      currentDownload: map['currentDownload']?.toString() ?? '',
    );
  }
}

class HlsQueueProgress {
  final String url;
  final String filePath;
  final int progress;
  final int bytesDownloaded;
  final int totalBytes;
  final DownloadStatus status;
  final String? error;
  final double speed;
  final String queueId;
  final int queuePosition;
  final int queueLength;
  final double timestamp;

  HlsQueueProgress({
    required this.url,
    required this.filePath,
    required this.progress,
    required this.bytesDownloaded,
    required this.totalBytes,
    required this.status,
    this.error,
    required this.speed,
    required this.queueId,
    required this.queuePosition,
    required this.queueLength,
    required this.timestamp,
  });

  factory HlsQueueProgress.fromMap(Map<String, dynamic> map) {
    return HlsQueueProgress(
      url: map['url']?.toString() ?? '',
      filePath: map['filePath']?.toString() ?? '',
      progress: (map['progress'] as num?)?.toInt() ?? 0,
      bytesDownloaded: (map['bytesDownloaded'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      status: DownloadStatus.values[(map['status'] as num?)?.toInt() ?? 0],
      error: map['error']?.toString(),
      speed: (map['speed'] as num?)?.toDouble() ?? 0.0,
      queueId: map['queueId']?.toString() ?? '',
      queuePosition: (map['queuePosition'] as num?)?.toInt() ?? 0,
      queueLength: (map['queueLength'] as num?)?.toInt() ?? 0,
      timestamp: (map['timestamp'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

enum DownloadType {
  regular,
  batch,
  hlsQueue,
}

class CombinedDownloadProgress {
  final DownloadType downloadType;
  final DownloadProgress? regularProgress;
  final BatchDownloadProgress? batchProgress;
  final HlsQueueProgress? hlsQueueProgress;
  final double timestamp;

  CombinedDownloadProgress({
    required this.downloadType,
    this.regularProgress,
    this.batchProgress,
    this.hlsQueueProgress,
    required this.timestamp,
  });

  factory CombinedDownloadProgress.fromMap(Map<String, dynamic> map) {
    final downloadTypeString = map['downloadType']?.toString() ?? 'regular';
    final DownloadType downloadType;

    switch (downloadTypeString) {
      case 'batch':
        downloadType = DownloadType.batch;
        break;
      case 'hls_queue':
        downloadType = DownloadType.hlsQueue;
        break;
      default:
        downloadType = DownloadType.regular;
    }

    return CombinedDownloadProgress(
      downloadType: downloadType,
      regularProgress: downloadType == DownloadType.regular
          ? DownloadProgress.fromMap(map)
          : null,
      batchProgress: downloadType == DownloadType.batch
          ? BatchDownloadProgress.fromMap(map)
          : null,
      hlsQueueProgress: downloadType == DownloadType.hlsQueue
          ? HlsQueueProgress.fromMap(map)
          : null,
      timestamp: (map['timestamp'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

// ✅ USAGE EXAMPLES

/*
// Example 1: Cross-platform download (works on both Android and iOS)
await MultithreadedDownloads.startDownload(
  urls: [
    'https://example.com/video.m3u8',  // iOS: → HLS queue, Android: → regular
    'https://example.com/file.zip',    // Both: → regular/batch
  ],
  filePath: '/downloads',
  priority: 100, // Only used on iOS
);

// Example 2: iOS-specific HLS queue operations
if (Platform.isIOS) {
  // Queue multiple HLS downloads
  final result = await MultithreadedDownloads.queueHlsDownloads(
    urls: [
      'https://example.com/stream1.m3u8',
      'https://example.com/stream2.m3u8',
    ],
    basePath: '/downloads',
    priority: 100,
  );

  if (result?.success == true) {
    print('Queued ${result!.count} HLS downloads: ${result.queueIds}');
  }

  // Monitor HLS queue status
  final queueStatus = await MultithreadedDownloads.getHlsQueueStatus();
  print('Queue status: ${queueStatus?.status}');
  print('In queue: ${queueStatus?.queueLength}');
  print('Completed: ${queueStatus?.totalCompleted}');

  // Control HLS queue
  await MultithreadedDownloads.pauseHlsQueue();
  await MultithreadedDownloads.resumeHlsQueue();
  await MultithreadedDownloads.cancelHlsQueue();
}

// Example 3: Listen to combined progress stream
MultithreadedDownloads.combinedProgressStream.listen((progress) {
  switch (progress.downloadType) {
    case DownloadType.regular:
      print('Regular download: ${progress.regularProgress?.progress}%');
      break;
    case DownloadType.batch:
      print('Batch download: ${progress.batchProgress?.overallProgress}%');
      break;
    case DownloadType.hlsQueue:
      print('HLS queue: ${progress.hlsQueueProgress?.progress}% (Queue: ${progress.hlsQueueProgress?.queuePosition}/${progress.hlsQueueProgress?.queueLength})');
      break;
  }
});

// Example 4: iOS-specific HLS queue progress
if (Platform.isIOS) {
  MultithreadedDownloads.hlsQueueProgressStream.listen((hlsProgress) {
    print('HLS Download: ${hlsProgress.url}');
    print('Progress: ${hlsProgress.progress}%');
    print('Queue Position: ${hlsProgress.queuePosition}/${hlsProgress.queueLength}');
    print('Speed: ${hlsProgress.speed} bytes/sec');
  });
}
*/