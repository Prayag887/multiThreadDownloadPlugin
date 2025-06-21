import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'multithread_downloads_platform_interface.dart';

/// An implementation of [MultithreadDownloadsPlatform] that uses method channels.
class MethodChannelMultithreadDownloads extends MultithreadDownloadsPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('multithread_downloads');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
