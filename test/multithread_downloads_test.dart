// import 'package:flutter_test/flutter_test.dart';
// import 'package:multithread_downloads/multithread_downloads.dart';
// import 'package:multithread_downloads/multithread_downloads_platform_interface.dart';
// import 'package:multithread_downloads/multithread_downloads_method_channel.dart';
// import 'package:plugin_platform_interface/plugin_platform_interface.dart';
//
// class MockMultithreadDownloadsPlatform
//     with MockPlatformInterfaceMixin
//     implements MultithreadDownloadsPlatform {
//
//   @override
//   Future<String?> getPlatformVersion() => Future.value('42');
// }
//
// void main() {
//   final MultithreadDownloadsPlatform initialPlatform = MultithreadDownloadsPlatform.instance;
//
//   test('$MethodChannelMultithreadDownloads is the default instance', () {
//     expect(initialPlatform, isInstanceOf<MethodChannelMultithreadDownloads>());
//   });
//
//   test('getPlatformVersion', () async {
//     MultithreadDownloads multithreadDownloadsPlugin = MultithreadDownloads();
//     MockMultithreadDownloadsPlatform fakePlatform = MockMultithreadDownloadsPlatform();
//     MultithreadDownloadsPlatform.instance = fakePlatform;
//
//     expect(await multithreadDownloadsPlugin.getPlatformVersion(), '42');
//   });
// }
