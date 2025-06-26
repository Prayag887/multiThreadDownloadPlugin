import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:multithread_downloads/multithread_downloads.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(
    MaterialApp(
      title: 'Multi-URL Downloads',
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
  BatchDownloadProgress? batchProgress;

  final List<String> _defaultUrls = [
    'https://nbg1-speed.hetzner.com/1GB.bin',
    'https://nbg1-speed.hetzner.com/100MB.bin',
    'https://nbg1-speed.hetzner.com/10MB.bin',
  ];

  final TextEditingController _urlsController = TextEditingController();
  final TextEditingController _maxTasksController = TextEditingController();

  // Track button states to prevent multiple taps
  final Map<String, bool> _buttonStates = {};
  bool _isBatchOperationInProgress = false;

  @override
  void initState() {
    super.initState();
    _urlsController.text = _defaultUrls.join('\n');
    _maxTasksController.text = '4';

    // Listen to download progress
    MultithreadedDownloads.progressStream.listen((progress) {
      setState(() {
        // Check if this is batch progress
        if (progress.url == '' && progress.filePath == '') {
          // This is likely batch progress - handle accordingly
          return;
        }

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

      // Update batch progress periodically
      _updateBatchProgress();
    });

    _requestPermissions();
  }

  Future<void> _updateBatchProgress() async {
    try {
      final progress = await MultithreadedDownloads.getBatchProgress();
      if (progress != null) {
        setState(() {
          batchProgress = progress;
        });
      }
    } catch (e) {
      // Handle error silently
    }
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await Permission.storage.request();
    }
  }

  List<String> _parseUrls(String input) {
    return input
        .split('\n')
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty && Uri.tryParse(url) != null)
        .toList();
  }

  Future<void> startBatchDownload() async {
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

      final urls = _parseUrls(_urlsController.text.trim());
      if (urls.isEmpty) {
        _showSnackBar('Please enter valid URLs (one per line)');
        return;
      }

      final maxTasks = int.tryParse(_maxTasksController.text) ?? 4;

      final success = await MultithreadedDownloads.startDownload(
        urls: urls,
        filePath: directory.path,
        maxConcurrentTasks: maxTasks,
        retryCount: 3,
        timeoutSeconds: 30,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Android)',
        },
      );

      if (success) {
        _showSnackBar('Batch download started (${urls.length} files)');
        setState(() {
          _isBatchOperationInProgress = false;
        });
      } else {
        _showSnackBar('Failed to start batch download');
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
        batchProgress = null;
      });
      _showSnackBar('Completed downloads cleared');
    }
  }

  Future<void> _pauseAllDownloads() async {
    if (_isBatchOperationInProgress) return;

    setState(() {
      _isBatchOperationInProgress = true;
    });

    try {
      final success = await MultithreadedDownloads.pauseAllDownloads();
      if (success) {
        _showSnackBar('All downloads paused');
      } else {
        _showSnackBar('No active downloads to pause');
      }
    } catch (e) {
      _showSnackBar('Error pausing downloads: ${e.toString()}');
    } finally {
      setState(() {
        _isBatchOperationInProgress = false;
      });
    }
  }

  Future<void> _resumeAllDownloads() async {
    if (_isBatchOperationInProgress) return;

    setState(() {
      _isBatchOperationInProgress = true;
    });

    try {
      await MultithreadedDownloads.resumeAllDownloads();
      _showSnackBar('All downloads resumed');
    } catch (e) {
      _showSnackBar('Error resuming downloads: ${e.toString()}');
    } finally {
      setState(() {
        _isBatchOperationInProgress = false;
      });
    }
  }

  Future<void> _cancelAllDownloads() async {
    if (_isBatchOperationInProgress) return;

    setState(() {
      _isBatchOperationInProgress = true;
    });

    try {
      final success = await MultithreadedDownloads.cancelAllDownloads();
      if (success) {
        setState(() {
          downloads.clear();
          batchProgress = null;
        });
        _showSnackBar('All downloads cancelled');
      }
    } catch (e) {
      _showSnackBar('Error cancelling downloads: ${e.toString()}');
    } finally {
      setState(() {
        _isBatchOperationInProgress = false;
      });
    }
  }

  Future<void> _pauseDownload(DownloadProgress download, String url) async {
    download.status = DownloadStatus.paused;
    if (_buttonStates[url] == true) return;

    setState(() {
      _buttonStates[url] = true;
    });

    try {
      final success = await MultithreadedDownloads.pauseDownload(url);
      if (success) {
        _showSnackBar('Download paused');
      } else {
        _showSnackBar('Failed to pause download');
      }
    } catch (e) {
      _showSnackBar('Error pausing download: ${e.toString()}');
    } finally {
      setState(() {
        _buttonStates[url] = false;
      });
    }
  }

  Future<void> _resumeDownload(String url) async {
    if (_buttonStates[url] == true) return;

    setState(() {
      _buttonStates[url] = true;
    });

    try {
      await MultithreadedDownloads.resumeDownload(url);
      _showSnackBar('Download resumed');
    } catch (e) {
      _showSnackBar('Error resuming download: ${e.toString()}');
    } finally {
      setState(() {
        _buttonStates[url] = false;
      });
    }
  }

  Future<void> _cancelDownload(String url) async {
    if (_buttonStates[url] == true) return;

    setState(() {
      _buttonStates[url] = true;
    });

    try {
      final success = await MultithreadedDownloads.cancelDownload(url);
      if (success) {
        setState(() {
          downloads.removeWhere((d) => d.url == url);
        });
        _showSnackBar('Download cancelled');
      } else {
        _showSnackBar('Failed to cancel download');
      }
    } catch (e) {
      _showSnackBar('Error cancelling download: ${e.toString()}');
    } finally {
      setState(() {
        _buttonStates[url] = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Multi-URL Downloads'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'pause_all':
                  _pauseAllDownloads();
                  break;
                case 'resume_all':
                  _resumeAllDownloads();
                  break;
                case 'cancel_all':
                  _cancelAllDownloads();
                  break;
                case 'clear_completed':
                  _clearCompletedDownloads();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'pause_all', child: Text('Pause All')),
              PopupMenuItem(value: 'resume_all', child: Text('Resume All')),
              PopupMenuItem(value: 'cancel_all', child: Text('Cancel All')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'clear_completed', child: Text('Clear Completed')),
            ],
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
                  controller: _urlsController,
                  decoration: InputDecoration(
                    labelText: 'Download URLs (one per line)',
                    hintText: 'Enter URLs separated by new lines',
                    border: OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(Icons.clear),
                      onPressed: () => _urlsController.clear(),
                    ),
                  ),
                  maxLines: 5,
                  minLines: 3,
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _maxTasksController,
                        decoration: InputDecoration(
                          labelText: 'Max Concurrent Tasks',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: ElevatedButton.icon(
                        onPressed: startBatchDownload,
                        icon: Icon(Icons.download),
                        label: Text('Start Downloads'),
                        style: ElevatedButton.styleFrom(
                          padding: EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Batch Progress Section
          if (batchProgress != null) ...[
            Container(
              margin: EdgeInsets.symmetric(horizontal: 16),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Overall Progress',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        '${batchProgress!.completedDownloads}/${batchProgress!.totalDownloads}',
                        style: TextStyle(
                          color: Colors.blue[700],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: batchProgress!.overallProgress / 100.0,
                    backgroundColor: Colors.grey[300],
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                  SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${batchProgress!.overallProgress}%',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                      if (batchProgress!.averageSpeed > 0)
                        Text(
                          '${_formatBytes(batchProgress!.averageSpeed.toInt())}/s',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blue[700],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    '${_formatBytes(batchProgress!.totalBytesDownloaded)} / ${_formatBytes(batchProgress!.totalBytes)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            SizedBox(height: 8),
          ],

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
                    'Enter URLs above and tap "Start Downloads"',
                    style: TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
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

      // Floating Action Button for batch operations
      floatingActionButton: downloads.isNotEmpty ? FloatingActionButton(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            builder: (context) => Container(
              padding: EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Batch Operations',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isBatchOperationInProgress ? null : _pauseAllDownloads,
                          icon: _isBatchOperationInProgress
                              ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(Icons.pause),
                          label: Text('Pause All'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isBatchOperationInProgress ? null : _resumeAllDownloads,
                          icon: _isBatchOperationInProgress
                              ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(Icons.play_arrow),
                          label: Text('Resume All'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isBatchOperationInProgress ? null : _cancelAllDownloads,
                      icon: _isBatchOperationInProgress
                          ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.cancel),
                      label: Text('Cancel All'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        child: Icon(Icons.more_vert),
      ) : null,
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
            if (download.error != null && download.error!.isNotEmpty) ...[
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
    _urlsController.dispose();
    _maxTasksController.dispose();
    super.dispose();
  }
}