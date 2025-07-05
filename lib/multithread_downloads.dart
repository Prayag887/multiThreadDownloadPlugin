import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';

class MultithreadedDownloads {
  static const MethodChannel _channel = MethodChannel('multithread_downloads');
  static const EventChannel _progressChannel = EventChannel('multithread_downloads/progress');
  static Stream<DownloadProgress>? _progressStream;
  HttpServer? _localServer;

  Future<void> startLocalHttpServer(String directoryPath, int port) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) throw Exception('Directory does not exist: $directoryPath');

    print('Files in directory:');
    await for (var entity in dir.list()) {
      print('  ${entity.path}');
    }

    final handler = createStaticHandler(directoryPath, serveFilesOutsidePath: true, listDirectories: true);
    final pipeline = Pipeline().addMiddleware(logRequests()).addHandler(handler);
    _localServer = await io.serve(pipeline, 'localhost', port);
    print('Server started at http://localhost:$port\nServing: ${dir.absolute.path}');
  }

  Future<void> stopLocalHttpServer() async {
    await _localServer?.close(force: true);
    _localServer = null;
  }

  static Stream<DownloadProgress> get progressStream {
    _progressStream ??= _progressChannel.receiveBroadcastStream().map(
          (event) => DownloadProgress.fromMap(Map<String, dynamic>.from(event)),
    );
    return _progressStream!;
  }

  static Future<bool> startDownload({
    required List<String> urls,
    required String filePath,
    String fileName = '',
    Map<String, String>? headers,
    int maxConcurrentTasks = 4,
    int retryCount = 3,
    int timeoutSeconds = 30,
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
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Unified control: pause / resume / cancel (url, urls, or all)
  static Future<bool> pauseDownload(String url) => _invokeBoolMethod('pause', {'url': url});
  static Future<bool> resumeDownload(String url) => _invokeBoolMethod('resume', {'url': url});
  static Future<bool> cancelDownload(String url) => _invokeBoolMethod('cancel', {'url': url});

  static Future<bool> pauseDownloads(List<String> urls) => _invokeBoolMethod('pause', {'urls': urls});
  static Future<bool> resumeDownloads(List<String> urls) => _invokeBoolMethod('resume', {'urls': urls});
  static Future<bool> cancelDownloads(List<String> urls) => _invokeBoolMethod('cancel', {'urls': urls});

  static Future<bool> pauseAllDownloads() => _invokeBoolMethod('pause');
  static Future<bool> resumeAllDownloads() => _invokeBoolMethod('resume');
  static Future<bool> cancelAllDownloads() => _invokeBoolMethod('cancel');

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

  static Future<BatchDownloadProgress?> getBatchProgress() async {
    try {
      final result = await _channel.invokeMethod('getBatchProgress');
      return BatchDownloadProgress.fromMap(Map<String, dynamic>.from(result));
    } catch (e) {
      return null;
    }
  }

  static Future<bool> _invokeBoolMethod(String method, [Map<String, dynamic>? args]) async {
    try {
      final result = await _channel.invokeMethod(method, args);
      return result == true;
    } catch (e) {
      return false;
    }
  }
}

class DownloadProgress {
  final String url;
  final String filePath;
  final int progress;
  final int bytesDownloaded;
  final int totalBytes;
  final DownloadStatus status;
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
    return DownloadProgress(
      url: map['url'] ?? '',
      filePath: map['filePath'] ?? '',
      progress: map['progress'] ?? 0,
      bytesDownloaded: map['bytesDownloaded'] ?? 0,
      totalBytes: map['totalBytes'] ?? 0,
      status: DownloadStatus.values[map['status'] ?? 0],
      error: map['error'],
      speed: (map['speed'] ?? 0.0).toDouble(),
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