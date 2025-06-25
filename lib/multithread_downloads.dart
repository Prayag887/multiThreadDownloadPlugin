import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

class MultithreadedDownloads {
  static const MethodChannel _channel = MethodChannel('multithread_downloads');
  static const EventChannel _progressChannel = EventChannel('multithread_downloads/progress');

  static Stream<DownloadProgress>? _progressStream;

  static Stream<DownloadProgress> get progressStream {
    _progressStream ??= _progressChannel
        .receiveBroadcastStream()
        .map((event) => DownloadProgress.fromMap(Map<String, dynamic>.from(event)));
    return _progressStream!;
  }

  static Future<bool> startDownload({
    required String url,
    required String filePath,
    Map<String, String>? headers,
    int maxConcurrentTasks = 4,
    int chunkSize = 1024 * 1024, // 1MB chunks
    int retryCount = 3,
    int timeoutSeconds = 30,
  }) async {
    try {
      final result = await _channel.invokeMethod('startDownload', {
        'url': url,
        'filePath': filePath,
        'headers': headers ?? {},
        'maxConcurrentTasks': maxConcurrentTasks,
        'chunkSize': chunkSize,
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

  static Future<Map<String, dynamic>?> getDownloadStatus(String url) async {
    try {
      final result = await _channel.invokeMethod('getDownloadStatus', {'url': url});
      return Map<String, dynamic>.from(result);
    } catch (e) {
      return null;
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
}

class DownloadProgress {
   String url;
   String filePath;
   int progress;
   int bytesDownloaded;
   int totalBytes;
  DownloadStatus status;
   String? error;
   double speed;

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
}

enum DownloadStatus {
  pending,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}