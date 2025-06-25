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

  // Track button states to prevent multiple taps
  Map<String, bool> _buttonStates = {};

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

        // Reset button state when status changes to expected states
        if (progress.status == DownloadStatus.paused ||
            progress.status == DownloadStatus.downloading ||
            progress.status == DownloadStatus.cancelled ||
            progress.status == DownloadStatus.completed ||
            progress.status == DownloadStatus.failed) {
          _buttonStates[progress.url] = false;
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
        maxConcurrentTasks: 4,
        chunkSize: 1024 * 1024,
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

  Future<void> _pauseDownload(DownloadProgress download, String url) async {
    if (_buttonStates[url] == true) return; // Prevent multiple taps
    download.status = DownloadStatus.paused;
    setState(() {
      _buttonStates[url] = true;
    });

    try {
      final success = await MultithreadedDownloads.pauseDownload(url);
      if (success) {
        _showSnackBar('Download paused');
        // Reset button state immediately for pause since it should be instant
        setState(() {
          _buttonStates[url] = false;
        });
      } else {
        _showSnackBar('Failed to pause download');
        setState(() {
          _buttonStates[url] = false;
        });
      }
    } catch (e) {
      _showSnackBar('Error pausing download: ${e.toString()}');
      setState(() {
        _buttonStates[url] = false;
      });
    }
  }

  Future<void> _resumeDownload(String url) async {
    if (_buttonStates[url] == true) return; // Prevent multiple taps

    setState(() {
      _buttonStates[url] = true;
    });

    try {
      final success = await MultithreadedDownloads.resumeDownload(url);
      if (success) {
        _showSnackBar('Download resumed');
        // Reset button state immediately for resume since it should be instant
        setState(() {
          _buttonStates[url] = false;
        });
      } else {
        _showSnackBar('Failed to resume download');
        setState(() {
          _buttonStates[url] = false;
        });
      }
    } catch (e) {
      _showSnackBar('Error resuming download: ${e.toString()}');
      setState(() {
        _buttonStates[url] = false;
      });
    }
  }

  Future<void> _cancelDownload(String url) async {
    if (_buttonStates[url] == true) return; // Prevent multiple taps

    setState(() {
      _buttonStates[url] = true;
    });

    try {
      final success = await MultithreadedDownloads.cancelDownload(url);
      if (success) {
        _showSnackBar('Download cancelled');
        // Reset button state immediately for cancel since it should be instant
        setState(() {
          _buttonStates[url] = false;
        });
      } else {
        _showSnackBar('Failed to cancel download');
        setState(() {
          _buttonStates[url] = false;
        });
      }
    } catch (e) {
      _showSnackBar('Error cancelling download: ${e.toString()}');
      setState(() {
        _buttonStates[url] = false;
      });
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
    log("Status: ${download.status}, Progress: ${download.progress}, Error: ${download.error}");

    final bool isButtonLoading = _buttonStates[download.url] ?? false;

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

            // Status indicator with better visibility
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _getStatusColor(download.status).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _getStatusColor(download.status).withOpacity(0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _getStatusIcon(download.status),
                    size: 16,
                    color: _getStatusColor(download.status),
                  ),
                  SizedBox(width: 4),
                  Text(
                    _getStatusText(download.status),
                    style: TextStyle(
                      color: _getStatusColor(download.status),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
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
                Text(
                  '${download.progress.toStringAsFixed(1)}%',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                if (download.status == DownloadStatus.downloading && download.speed > 0)
                  Text(
                    '${_formatBytes(download.speed.toInt())}/s',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
            SizedBox(height: 8),

            // Download info
            Text(
              '${_formatBytes(download.bytesDownloaded)} / ${_formatBytes(download.totalBytes)}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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

            // Action buttons with improved UI
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (download.status == DownloadStatus.downloading) ...[
                  ElevatedButton.icon(
                    onPressed: isButtonLoading ? null : () => _pauseDownload(download, download.url),
                    icon: isButtonLoading
                        ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : Icon(Icons.pause, size: 16),
                    label: Text(isButtonLoading ? 'Pausing...' : 'Pause'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
                ] else if (download.status == DownloadStatus.paused) ...[
                  ElevatedButton.icon(
                    onPressed: isButtonLoading ? null : () => _resumeDownload(download.url),
                    icon: isButtonLoading
                        ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : Icon(Icons.play_arrow, size: 16),
                    label: Text(isButtonLoading ? 'Resuming...' : 'Resume'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
                ] else if (download.status == DownloadStatus.failed) ...[
                  ElevatedButton.icon(
                    onPressed: isButtonLoading ? null : () => _resumeDownload(download.url),
                    icon: isButtonLoading
                        ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : Icon(Icons.refresh, size: 16),
                    label: Text(isButtonLoading ? 'Retrying...' : 'Retry'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
                ],

                if (download.status != DownloadStatus.completed) ...[
                  OutlinedButton.icon(
                    onPressed: isButtonLoading ? null : () => _cancelDownload(download.url),
                    icon: isButtonLoading
                        ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
                      ),
                    )
                        : Icon(Icons.cancel, size: 16),
                    label: Text(isButtonLoading ? 'Cancelling...' : 'Cancel'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: BorderSide(color: Colors.red),
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

  IconData _getStatusIcon(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.pending:
        return Icons.schedule;
      case DownloadStatus.downloading:
        return Icons.download;
      case DownloadStatus.paused:
        return Icons.pause_circle_filled;
      case DownloadStatus.completed:
        return Icons.check_circle;
      case DownloadStatus.failed:
        return Icons.error;
      case DownloadStatus.cancelled:
        return Icons.cancel;
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