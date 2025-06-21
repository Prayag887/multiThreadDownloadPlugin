import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:multithread_downloads/multithread_downloads.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(
    MaterialApp(
      title: 'Multithreaded Downloads',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MyApp(),
    ),
  );
}


class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  List<DownloadProgress> downloads = [];
  final String _downloadUrl = 'https://nbg1-speed.hetzner.com//1GB.bin';
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _urlController.text = _downloadUrl;

    // Listen to download progress
    MultithreadedDownloads.progressStream.listen((progress) {
      setState(() {
        final index = downloads.indexWhere((d) => d.url == progress.url);
        if (index != -1) {
          downloads[index] = progress;
        } else {
          downloads.add(progress);
        }
      });
    });

    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await Permission.storage.request();
    }
  }

  Future<void> startDownload() async {
    try {
      // Get the downloads directory
      Directory? directory;

      if (Platform.isAndroid) {
        directory = await getExternalStorageDirectory();
        // Create Downloads folder if it doesn't exist
        directory = Directory('${directory!.path}/Downloads');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
      } else {
        directory = await getApplicationDocumentsDirectory();
      }

      final url = _urlController.text.trim();
      if (url.isEmpty) {
        _showSnackBar('Please enter a valid URL');
        return;
      }

      // Extract filename from URL or use default
      final uri = Uri.parse(url);
      String filename = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : 'downloaded_file_${DateTime.now().millisecondsSinceEpoch}';

      // If no extension, add .bin
      if (!filename.contains('.')) {
        filename += '.bin';
      }

      final filePath = '${directory.path}/$filename';

      final success = await MultithreadedDownloads.startDownload(
        url: url,
        filePath: filePath,
        maxConcurrentTasks: 4, // for multi-threads
        chunkSize: 1024 * 1024, // 1MB chunks
        retryCount: 3,
        timeoutSeconds: 30,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Android)',
        },
      );

      if (success) {
        _showSnackBar('Download started: $filename');
      } else {
        _showSnackBar('Failed to start download');
      }
    } catch (e) {
      _showSnackBar('Error: ${e.toString()}');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _clearCompletedDownloads() async {
    final success = await MultithreadedDownloads.clearCompletedDownloads();
    if (success) {
      setState(() {
        downloads.removeWhere((d) => d.status == DownloadStatus.completed);
      });
      _showSnackBar('Completed downloads cleared');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Multithreaded Downloads'),
        actions: [
          IconButton(
            icon: Icon(Icons.clear_all),
            onPressed: _clearCompletedDownloads,
            tooltip: 'Clear Completed',
          ),
        ],
      ),
      body: Column(
        children: [
            // URL Input Section
            Container(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      labelText: 'Download URL',
                      hintText: 'Enter the URL to download',
                      border: OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(Icons.clear),
                        onPressed: () => _urlController.clear(),
                      ),
                    ),
                    maxLines: 2,
                    minLines: 1,
                  ),
                  SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: startDownload,
                      icon: Icon(Icons.download),
                      label: Text('Start Download'),
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(),

            // Downloads List
            Expanded(
              child: downloads.isEmpty
                  ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.download, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text(
                      'No downloads yet',
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Enter a URL above and tap "Start Download"',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              )
                  : ListView.builder(
                itemCount: downloads.length,
                itemBuilder: (context, index) {
                  final download = downloads[index];
                  return _buildDownloadCard(download);
                },
              ),
            ),
          ],
        ),
    );
  }

  Widget _buildDownloadCard(DownloadProgress download) {
    if(download.error != null) {
      log("Error: ${download.error}");
    }
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // URL and filename
            Text(
              'File: ${_getFilenameFromPath(download.filePath)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            SizedBox(height: 4),
            Text(
              download.url,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 12,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: 12),

            // Progress bar
            LinearProgressIndicator(
              value: download.progress / 100.0,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(
                _getStatusColor(download.status),
              ),
            ),
            SizedBox(height: 8),

            // Progress details
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${download.progress}%'),
                Text(_getStatusText(download.status)),
              ],
            ),
            SizedBox(height: 8),

            // Download info
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_formatBytes(download.bytesDownloaded)} / ${_formatBytes(download.totalBytes)}',
                  style: TextStyle(fontSize: 12),
                ),
                if (download.speed > 0)
                  Text(
                    '${_formatBytes(download.speed.toInt())}/s',
                    style: TextStyle(fontSize: 12, color: Colors.blue),
                  ),
              ],
            ),

            // Error message
            if (download.error != null) ...[
              SizedBox(height: 8),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.red[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error, color: Colors.red, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        download.error!,
                        style: TextStyle(color: Colors.red[800], fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            SizedBox(height: 12),

            // Action buttons
            Row(
              children: [
                if (download.status == DownloadStatus.downloading) ...[
                  ElevatedButton.icon(
                    onPressed: () => MultithreadedDownloads.pauseDownload(download.url),
                    icon: Icon(Icons.pause, size: 16),
                    label: Text('Pause'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ] else if (download.status == DownloadStatus.paused) ...[
                  ElevatedButton.icon(
                    onPressed: () => MultithreadedDownloads.resumeDownload(download.url),
                    icon: Icon(Icons.play_arrow, size: 16),
                    label: Text('Resume'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ] else if (download.status == DownloadStatus.failed) ...[
                  ElevatedButton.icon(
                    onPressed: () => MultithreadedDownloads.resumeDownload(download.url),
                    icon: Icon(Icons.refresh, size: 16),
                    label: Text('Retry'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],

                SizedBox(width: 8),

                if (download.status != DownloadStatus.completed) ...[
                  OutlinedButton.icon(
                    onPressed: () => MultithreadedDownloads.cancelDownload(download.url),
                    icon: Icon(Icons.cancel, size: 16),
                    label: Text('Cancel'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: BorderSide(color: Colors.red),
                    ),
                  ),
                ],

                if (download.status == DownloadStatus.completed) ...[
                  ElevatedButton.icon(
                    onPressed: () => _openFile(download.filePath),
                    icon: Icon(Icons.open_in_new, size: 16),
                    label: Text('Open'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _getFilenameFromPath(String path) {
    return path.split('/').last;
  }

  String _getStatusText(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.pending:
        return 'Pending';
      case DownloadStatus.downloading:
        return 'Downloading';
      case DownloadStatus.paused:
        return 'Paused';
      case DownloadStatus.completed:
        return 'Completed';
      case DownloadStatus.failed:
        return 'Failed';
      case DownloadStatus.cancelled:
        return 'Cancelled';
    }
  }

  Color _getStatusColor(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.pending:
        return Colors.grey;
      case DownloadStatus.downloading:
        return Colors.blue;
      case DownloadStatus.paused:
        return Colors.orange;
      case DownloadStatus.completed:
        return Colors.green;
      case DownloadStatus.failed:
        return Colors.red;
      case DownloadStatus.cancelled:
        return Colors.grey;
    }
  }

  void _openFile(String filePath) {
    _showSnackBar('File saved at: $filePath');
    // You can implement file opening logic here
    // For example, using the open_file package
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}