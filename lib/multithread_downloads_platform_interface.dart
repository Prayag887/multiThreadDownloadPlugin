import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'multithread_downloads_method_channel.dart';

abstract class MultithreadDownloadsPlatform extends PlatformInterface {
  /// Constructs a MultithreadDownloadsPlatform.
  MultithreadDownloadsPlatform() : super(token: _token);

  static final Object _token = Object();

  static MultithreadDownloadsPlatform _instance = MethodChannelMultithreadDownloads();

  /// The default instance of [MultithreadDownloadsPlatform] to use.
  ///
  /// Defaults to [MethodChannelMultithreadDownloads].
  static MultithreadDownloadsPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MultithreadDownloadsPlatform] when
  /// they register themselves.
  static set instance(MultithreadDownloadsPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
