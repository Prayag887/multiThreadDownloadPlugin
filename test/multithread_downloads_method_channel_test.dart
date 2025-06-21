import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multithread_downloads/multithread_downloads_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelMultithreadDownloads platform = MethodChannelMultithreadDownloads();
  const MethodChannel channel = MethodChannel('multithread_downloads');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
