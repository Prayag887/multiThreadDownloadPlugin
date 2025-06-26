import 'dart:io';
import 'package:flutter/material.dart';
import 'package:multithread_downloads/multithread_downloads.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:better_player/better_player.dart';
import 'package:path/path.dart' as p; // for path operations

void main() {
  runApp(MaterialApp(
    title: 'Multi-URL Downloads',
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
  BetterPlayerController? _playerController;
  final List<String> _defaultUrls = [
    'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
  ];
  final TextEditingController _urlsController = TextEditingController();
  int _downloadCounter = 1;
  MultithreadedDownloads _multithreadedDownloads = MultithreadedDownloads();

  @override
  void initState() {
    super.initState();
    _urlsController.text = _defaultUrls.join('\n');
    _requestPermissions();

    MultithreadedDownloads.progressStream.listen((progress) {
      setState(() {
        if (progress.url.isEmpty) return;

        final index = downloads.indexWhere((d) => d.url == progress.url);
        if (index != -1) {
          downloads[index] = progress;
        } else {
          downloads.add(progress);
        }
      });
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [Permission.storage, Permission.accessMediaLocation].request();
    }
  }

  List<String> _parseUrls(String input) {
    return input
        .split('\n')
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty && Uri.tryParse(url) != null)
        .toList();
  }

  /// Ensures the filePath is a directory (no filename).
  /// If filePath is a file, returns its parent directory path.
  /// Prints debug logs for tracing.
  String prepareFilePathForDownload(String filePath) {
    final file = File(filePath);
    if (file.existsSync()) {
      final parentDir = file.parent.path;
      debugPrint('[prepareFilePathForDownload] filePath is a file. Using parent directory: $parentDir');
      return parentDir;
    }

    final dir = Directory(filePath);
    if (dir.existsSync()) {
      debugPrint('[prepareFilePathForDownload] filePath is a directory: $filePath');
      return filePath;
    }

    final ext = p.extension(filePath);
    if (ext.isNotEmpty) {
      final guessedDir = p.dirname(filePath);
      debugPrint('[prepareFilePathForDownload] filePath looks like a file path (ext: $ext). Using guessed directory: $guessedDir');
      return guessedDir;
    }

    debugPrint('[prepareFilePathForDownload] filePath does not exist, no extension found. Using as is: $filePath');
    return filePath;
  }

  Future startDownloads() async {
    try {
      Directory directory = await getApplicationDocumentsDirectory();
      directory = Directory('${directory.path}/Downloads');

      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final urls = _parseUrls(_urlsController.text.trim());
      if (urls.isEmpty) {
        _showSnackBar('Please enter valid URLs');
        return;
      }

      for (int i = 0; i < urls.length; i++) {
        final folderName = 'download_${_downloadCounter + i}';
        final downloadDir = Directory('${directory.path}/$folderName');
        if (!await downloadDir.exists()) {
          await downloadDir.create(recursive: true);
        }

        final safeFilePath = prepareFilePathForDownload(downloadDir.path);
        debugPrint('Starting download for URL: ${urls[i]}');
        debugPrint('Original folder path: ${downloadDir.path}');
        debugPrint('Prepared filePath passed to native: $safeFilePath');

        await MultithreadedDownloads.startDownload(
          urls: [urls[i]],
          filePath: safeFilePath,
          maxConcurrentTasks: 4,
          retryCount: 3,
          timeoutSeconds: 30,
        );
      }

      _downloadCounter += urls.length;
      _showSnackBar('Downloads started');
    } catch (e) {
      _showSnackBar('Error: $e');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _playLocalFile(String playlistFilePath) async {
    try {
      _playerController?.dispose();

      final playlistFile = File(playlistFilePath);
      if (!playlistFile.existsSync()) {
        _showSnackBar('Playlist file does not exist');
        return;
      }

      // Get directory containing playlist and start server there
      final directoryPath = playlistFile.parent.path;

      // Pick any free port, e.g. 8080
      const port = 8080;

      await _multithreadedDownloads.stopLocalHttpServer(); // stop old server if running
      await _multithreadedDownloads.startLocalHttpServer(directoryPath, port);

      // Create URL pointing to the playlist file served by your local HTTP server
      final url = 'http://localhost:$port/${playlistFile.uri.pathSegments.last}';

      final dataSource = BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        url,
        videoFormat: BetterPlayerVideoFormat.hls,
      );

      _playerController = BetterPlayerController(
        BetterPlayerConfiguration(
          autoPlay: true,
          allowedScreenSleep: false,
          handleLifecycle: true,
          autoDetectFullscreenDeviceOrientation: true,
          controlsConfiguration: const BetterPlayerControlsConfiguration(
            enablePlayPause: true,
            enableFullscreen: true,
            enableProgressBar: true,
            enableMute: true,
          ),
        ),
        betterPlayerDataSource: dataSource,
      );

      setState(() {});
      _showSnackBar('Playing via local HTTP server');
    } catch (e) {
      _showSnackBar('Playback error: $e');
    }
  }



  String _getFilenameFromPath(String path) {
    return path.split('/').last;
  }

  Color _getStatusColor(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.downloading:
        return Colors.blue;
      case DownloadStatus.completed:
        return Colors.green;
      case DownloadStatus.failed:
        return Colors.red;
      case DownloadStatus.paused:
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String getDirectoryPath(String path) {
    final file = File(path);
    if (file.existsSync()) {
      return file.parent.path; // get directory containing the file
    }
    final dir = Directory(path);
    if (dir.existsSync()) {
      return dir.path;
    }
    return path;
  }

  String? _findPlaylistFile(String dirPath) {
    final directoryPath = getDirectoryPath(dirPath);
    final dir = Directory(directoryPath);

    if (!dir.existsSync()) return null;

    final files = dir.listSync().whereType<File>();

    final playlist = files.firstWhere(
          (file) =>
      file.path.endsWith('.m3u8') &&
          !file.path.contains('variant') &&
          !file.path.contains('audio'),
      orElse: () => files.firstWhere(
            (file) => file.path.endsWith('.m3u8'),
      ),
    );

    return playlist?.path;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-URL Downloads'),
        backgroundColor: Colors.blue,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _urlsController,
                  decoration: const InputDecoration(
                    labelText: 'URLs (one per line)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: startDownloads,
                  child: const Text('Start Downloads'),
                ),
              ],
            ),
          ),
          if (_playerController != null) ...[
            Container(
              height: 200,
              margin: const EdgeInsets.all(16),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: BetterPlayer(controller: _playerController!),
              ),
            ),
          ],
          Expanded(
            child: downloads.isEmpty
                ? const Center(child: Text('No downloads yet'))
                : ListView.builder(
              itemCount: downloads.length,
              itemBuilder: (context, index) {
                final download = downloads[index];
                final isHls = download.url.contains('.m3u8');

                return Card(
                  margin: const EdgeInsets.all(8),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'File: ${_getFilenameFromPath(download.filePath)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: download.progress / 100.0,
                          backgroundColor: Colors.grey[300],
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _getStatusColor(download.status),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('${download.progress.toStringAsFixed(1)}%'),
                            Text(
                              '${_formatBytes(download.bytesDownloaded)} / ${_formatBytes(download.totalBytes)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                        // if (download.status == DownloadStatus.completed) ...[
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: () {
                              if (isHls) {
                                final playlistPath = _findPlaylistFile(download.filePath);
                                if (playlistPath != null) {
                                  _playLocalFile(playlistPath);
                                } else {
                                  _showSnackBar('Playlist file not found');
                                }
                              } else {
                                _playLocalFile(download.filePath);
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                            ),
                            child: const Text('Play'),
                          ),
                        ],
                      // ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _urlsController.dispose();
    _playerController?.dispose();
    super.dispose();
  }
}
