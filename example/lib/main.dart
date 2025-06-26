import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:multithread_downloads/multithread_downloads.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(MaterialApp(
    title: 'Multi-URL Downloads',
    theme: ThemeData(
      primarySwatch: Colors.blue,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    ),
    home: MyApp(),
  ));
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
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
  ];

  final TextEditingController _urlsController = TextEditingController();
  final TextEditingController _maxTasksController = TextEditingController();
  final Map<String, bool> _buttonStates = {};
  bool _isBatchOperationInProgress = false;

  @override
  void initState() {
    super.initState();
    _urlsController.text = _defaultUrls.join('\n');
    _maxTasksController.text = '4';

    MultithreadedDownloads.progressStream.listen((progress) {
      setState(() {
        if (progress.url.isEmpty && progress.filePath.isEmpty) return;

        final index = downloads.indexWhere((d) => d.url == progress.url);
        if (index != -1) {
          downloads[index] = progress;
        } else {
          downloads.add(progress);
        }

        if ([DownloadStatus.paused, DownloadStatus.downloading, DownloadStatus.cancelled,
          DownloadStatus.completed, DownloadStatus.failed].contains(progress.status)) {
          _buttonStates[progress.url] = false;
        }
      });
      _updateBatchProgress();
    });

    _requestPermissions();
  }

  Future<void> _updateBatchProgress() async {
    try {
      final progress = await MultithreadedDownloads.getBatchProgress();
      if (progress != null) setState(() => batchProgress = progress);
    } catch (e) {}
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) await Permission.storage.request();
  }

  List<String> _parseUrls(String input) {
    return input.split('\n')
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty && Uri.tryParse(url) != null)
        .toList();
  }

  Future<void> startBatchDownload() async {
    try {
      Directory? directory = Platform.isAndroid
          ? Directory('${(await getExternalStorageDirectory())!.path}/Downloads')
          : await getApplicationDocumentsDirectory();

      if (Platform.isAndroid && !await directory.exists()) {
        await directory.create(recursive: true);
      }

      final urls = _parseUrls(_urlsController.text.trim());
      if (urls.isEmpty) {
        _showSnackBar('Please enter valid URLs (one per line)');
        return;
      }

      final maxTasks = int.tryParse(_maxTasksController.text) ?? 4;

      // Separate M3U8 and regular URLs
      final m3u8Urls = urls.where((url) => MultithreadedDownloads.isM3u8Url(url)).toList();
      final regularUrls = urls.where((url) => !MultithreadedDownloads.isM3u8Url(url)).toList();

      bool success = true;

      // Start M3U8 downloads individually
      for (String url in m3u8Urls) {
        final fileName = _getFileNameFromUrl(url, isM3u8: true);
        final filePath = '${directory.path}/$fileName';

        final m3u8Success = await MultithreadedDownloads.startM3u8Download(
          url: url,
          filePath: filePath,
          headers: {'User-Agent': 'Mozilla/5.0 (Android)'},
        );

        if (!m3u8Success) success = false;
      }

      // Start regular HTTP downloads as batch
      if (regularUrls.isNotEmpty) {
        final batchSuccess = await MultithreadedDownloads.startDownload(
          urls: regularUrls,
          filePath: directory.path,
          maxConcurrentTasks: maxTasks,
          retryCount: 3,
          timeoutSeconds: 30,
          headers: {'User-Agent': 'Mozilla/5.0 (Android)'},
        );

        if (!batchSuccess) success = false;
      }

      if (success) {
        _showSnackBar('Downloads started (${urls.length} files - ${m3u8Urls.length} M3U8, ${regularUrls.length} HTTP)');
      } else {
        _showSnackBar('Some downloads failed to start');
      }
    } catch (e) {
      _showSnackBar('Error: ${e.toString()}');
    }
  }

  String _getFileNameFromUrl(String url, {bool isM3u8 = false}) {
    final uri = Uri.parse(url);
    String fileName = uri.pathSegments.last;

    if (fileName.isEmpty || fileName == '/') {
      fileName = 'download_${DateTime.now().millisecondsSinceEpoch}';
    }

    if (isM3u8 && !fileName.endsWith('.mp4')) {
      fileName = fileName.replaceAll('.m3u8', '') + '.mp4';
    }

    return fileName;
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: Duration(seconds: 3)),
    );
  }

  Future<void> _clearCompletedDownloads() async {
    final success = await MultithreadedDownloads.clearCompletedDownloads();
    final m3u8Success = await MultithreadedDownloads.clearCompletedM3u8Downloads();

    if (success || m3u8Success) {
      setState(() {
        downloads.removeWhere((d) => d.status == DownloadStatus.completed);
        batchProgress = null;
      });
      _showSnackBar('Completed downloads cleared');
    }
  }

  Future<void> _batchOperation(String operation) async {
    if (_isBatchOperationInProgress) return;

    setState(() => _isBatchOperationInProgress = true);

    try {
      bool success = false;
      String message = '';

      switch (operation) {
        case 'pause':
          success = await MultithreadedDownloads.pauseAllDownloads();
          message = success ? 'All downloads paused' : 'No active downloads to pause';
          break;
        case 'resume':
          await MultithreadedDownloads.resumeAllDownloads();
          success = true;
          message = 'All downloads resumed';
          break;
        case 'cancel':
          success = await MultithreadedDownloads.cancelAllDownloads();
          if (success) {
            setState(() {
              downloads.clear();
              batchProgress = null;
            });
            message = 'All downloads cancelled';
          }
          break;
      }

      _showSnackBar(message);
    } catch (e) {
      _showSnackBar('Error: ${e.toString()}');
    } finally {
      setState(() => _isBatchOperationInProgress = false);
    }
  }

  Future<void> _downloadOperation(String operation, DownloadProgress download) async {
    if (_buttonStates[download.url] == true) return;

    setState(() => _buttonStates[download.url] = true);

    try {
      bool success = false;
      String message = '';

      if (download.isM3u8) {
        // M3U8 operations
        switch (operation) {
          case 'pause':
            success = await MultithreadedDownloads.pauseM3u8Download(download.url);
            message = success ? 'M3U8 download paused' : 'Failed to pause M3U8 download';
            break;
          case 'resume':
            success = await MultithreadedDownloads.resumeM3u8Download(download.url);
            message = success ? 'M3U8 download resumed' : 'Failed to resume M3U8 download';
            break;
          case 'cancel':
            success = await MultithreadedDownloads.cancelM3u8Download(download.url);
            if (success) {
              setState(() => downloads.removeWhere((d) => d.url == download.url));
              message = 'M3U8 download cancelled';
            } else {
              message = 'Failed to cancel M3U8 download';
            }
            break;
        }
      } else {
        // Regular HTTP operations
        switch (operation) {
          case 'pause':
            success = await MultithreadedDownloads.pauseDownload(download.url);
            message = success ? 'Download paused' : 'Failed to pause download';
            break;
          case 'resume':
            success = await MultithreadedDownloads.resumeDownload(download.url);
            message = success ? 'Download resumed' : 'Failed to resume download';
            break;
          case 'cancel':
            success = await MultithreadedDownloads.cancelDownload(download.url);
            if (success) {
              setState(() => downloads.removeWhere((d) => d.url == download.url));
              message = 'Download cancelled';
            } else {
              message = 'Failed to cancel download';
            }
            break;
        }
      }

      _showSnackBar(message);
    } catch (e) {
      _showSnackBar('Error: ${e.toString()}');
    } finally {
      setState(() => _buttonStates[download.url] = false);
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
                case 'pause_all': _batchOperation('pause'); break;
                case 'resume_all': _batchOperation('resume'); break;
                case 'cancel_all': _batchOperation('cancel'); break;
                case 'clear_completed': _clearCompletedDownloads(); break;
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
                    labelText: 'Download URLs (M3U8 & HTTP supported)',
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
                      Text('Overall Progress', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('${batchProgress!.completedDownloads}/${batchProgress!.totalDownloads}',
                          style: TextStyle(color: Colors.blue[700], fontWeight: FontWeight.w600)),
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
                      Text('${batchProgress!.overallProgress}%', style: TextStyle(fontWeight: FontWeight.w500)),
                      if (batchProgress!.averageSpeed > 0)
                        Text('${_formatBytes(batchProgress!.averageSpeed.toInt())}/s',
                            style: TextStyle(fontSize: 12, color: Colors.blue[700], fontWeight: FontWeight.w500)),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text('${_formatBytes(batchProgress!.totalBytesDownloaded)} / ${_formatBytes(batchProgress!.totalBytes)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
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
                  Text('No downloads yet', style: TextStyle(fontSize: 18, color: Colors.grey)),
                  SizedBox(height: 8),
                  Text('Enter URLs above and tap "Start Downloads"',
                      style: TextStyle(color: Colors.grey), textAlign: TextAlign.center),
                ],
              ),
            )
                : ListView.builder(
              itemCount: downloads.length,
              itemBuilder: (context, index) => _buildDownloadCard(downloads[index]),
            ),
          ),
        ],
      ),

      // Floating Action Button for batch operations
      floatingActionButton: downloads.isNotEmpty ? FloatingActionButton(
        onPressed: () => _showBatchOperationsSheet(),
        child: Icon(Icons.more_vert),
      ) : null,
    );
  }

  void _showBatchOperationsSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Batch Operations', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isBatchOperationInProgress ? null : () => _batchOperation('pause'),
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
                    onPressed: _isBatchOperationInProgress ? null : () => _batchOperation('resume'),
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
                onPressed: _isBatchOperationInProgress ? null : () => _batchOperation('cancel'),
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
  }

  Widget _buildDownloadCard(DownloadProgress download) {
    final bool isButtonLoading = _buttonStates[download.url] ?? false;

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // URL and filename with type indicator
            Row(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: download.isM3u8 ? Colors.purple[100] : Colors.blue[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    download.isM3u8 ? 'M3U8' : 'HTTP',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: download.isM3u8 ? Colors.purple[700] : Colors.blue[700],
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'File: ${_getFilenameFromPath(download.filePath)}',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            SizedBox(height: 4),
            Text(
              download.url,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: 12),

            // Status indicator
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _getStatusColor(download.status).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _getStatusColor(download.status).withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_getStatusIcon(download.status), size: 16, color: _getStatusColor(download.status)),
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
              valueColor: AlwaysStoppedAnimation<Color>(_getStatusColor(download.status)),
            ),
            SizedBox(height: 8),

            // Progress details
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${download.progress.toStringAsFixed(1)}%', style: TextStyle(fontWeight: FontWeight.w500)),
                if (download.status == DownloadStatus.downloading && download.speed > 0)
                  Text('${_formatBytes(download.speed.toInt())}/s',
                      style: TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.w500)),
              ],
            ),
            SizedBox(height: 8),

            // Download info
            Text('${_formatBytes(download.bytesDownloaded)} / ${_formatBytes(download.totalBytes)}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),

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
                      child: Text(download.error!, style: TextStyle(color: Colors.red[800], fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],

            SizedBox(height: 12),

            // Action buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (download.status == DownloadStatus.downloading) ...[
                  ElevatedButton.icon(
                    onPressed: isButtonLoading ? null : () => _downloadOperation('pause', download),
                    icon: isButtonLoading
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
                    onPressed: isButtonLoading ? null : () => _downloadOperation('resume', download),
                    icon: isButtonLoading
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
                    onPressed: isButtonLoading ? null : () => _downloadOperation('resume', download),
                    icon: isButtonLoading
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
                    onPressed: isButtonLoading ? null : () => _downloadOperation('cancel', download),
                    icon: isButtonLoading
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.red)))
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

  String _getFilenameFromPath(String path) => path.split('/').last;

  String _getStatusText(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.pending: return 'Pending';
      case DownloadStatus.downloading: return 'Downloading';
      case DownloadStatus.paused: return 'Paused';
      case DownloadStatus.completed: return 'Completed';
      case DownloadStatus.failed: return 'Failed';
      case DownloadStatus.cancelled: return 'Cancelled';
    }
  }

  IconData _getStatusIcon(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.pending: return Icons.schedule;
      case DownloadStatus.downloading: return Icons.download;
      case DownloadStatus.paused: return Icons.pause_circle_filled;
      case DownloadStatus.completed: return Icons.check_circle;
      case DownloadStatus.failed: return Icons.error;
      case DownloadStatus.cancelled: return Icons.cancel;
    }
  }

  Color _getStatusColor(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.pending: return Colors.grey;
      case DownloadStatus.downloading: return Colors.blue;
      case DownloadStatus.paused: return Colors.orange;
      case DownloadStatus.completed: return Colors.green;
      case DownloadStatus.failed: return Colors.red;
      case DownloadStatus.cancelled: return Colors.grey;
    }
  }

  void _openFile(String filePath) {
    _showSnackBar('File saved at: $filePath');
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