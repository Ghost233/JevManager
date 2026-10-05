import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jev_manager/download_panel.dart';
import 'package:jev_manager/download_preferences.dart';
import 'package:jev_manager/hf_model_browser.dart';
import 'package:jev_manager/model_downloader.dart';
import 'package:jev_manager/model_package.dart';

void main() {
  test(
    'changing download settings affects the next task, not cancelled resume',
    () async {
      const revision = '0123456789012345678901234567890123456789';
      final directory = await Directory.systemTemp.createTemp('task-source-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final fragment = Completer<void>();
      final requests = <String>[];
      final ranges = <String?>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response.headers.set(HttpHeaders.etagHeader, '"fixed-asset"');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (requests.length == 1) {
          request.response.bufferOutput = false;
          request.response.contentLength = 6;
          request.response.add(utf8.encode('abc'));
          await request.response.flush();
          await release.future;
          try {
            await request.response.close();
          } on IOException {
            /* cancelled */
          }
        } else if (requests.length == 2) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 3-5/6',
          );
          request.response.contentLength = 3;
          request.response.add(utf8.encode('def'));
          await request.response.close();
        } else {
          request.response.contentLength = 6;
          request.response.add(utf8.encode('abcdef'));
          await request.response.close();
        }
      });
      final base = 'http://127.0.0.1:${server.port}';
      final downloader = ModelDownloader(
        hfEndpoint: Uri.parse('$base/hf'),
        lmStudioEndpoint: Uri.parse('$base/proxy'),
      );
      final preferences = DownloadPreferences(
        file: File('${directory.path}/preferences.json'),
      );
      await preferences.saveSource(DownloadSource.lmStudio);
      final tasks = DownloadTaskController(
        downloader: downloader,
        preferences: preferences,
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        downloader.close();
        preferences.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      HfRepositoryFiles repository(String id) => HfRepositoryFiles(
        summary: HfRepositorySummary(id: id),
        revision: revision,
        requestedRevision: 'main',
        source: Uri.parse('$base/hf'),
        files: const [
          HfModelFile(
            path: 'model.gguf',
            sizeBytes: 6,
            sha256: 'bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721',
          ),
        ],
      );
      final first = repository('publisher/first');
      final sub = downloader.changes.listen((state) {
        if (state.downloadedBytes == 3 && !fragment.isCompleted) {
          fragment.complete();
        }
      });
      final transfer = tasks.start(
        selection: ModelPackage.discover(first).single.selectVariant(
          ModelPackage.discover(first).single.variants.single.id,
        ),
        currentRepository: first,
        libraryPath: directory.path,
      );
      await fragment.future.timeout(const Duration(seconds: 5));
      await preferences.saveSource(DownloadSource.hf);
      expect(downloader.state.source, DownloadSource.lmStudio);
      downloader.cancel();
      await transfer.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(downloader.state.status, DownloadStatus.cancelled);
      await tasks.retry();
      expect(
        downloader.state.status,
        DownloadStatus.installed,
        reason: downloader.state.error,
      );
      expect(requests, [
        '/proxy/publisher/first/resolve/$revision/model.gguf',
        '/proxy/publisher/first/resolve/$revision/model.gguf',
      ]);
      expect(ranges, [null, 'bytes=3-']);
      expect(downloader.state.libraryPath, directory.path);
      expect(
        await File('${directory.path}/publisher/first/model.gguf')
            .readAsString(),
        'abcdef',
      );
      final second = repository('publisher/second');
      final secondPackage = ModelPackage.discover(second).single;
      final nextDirectory = '${directory.path}/new model directory';
      await tasks.start(
        selection: secondPackage.selectVariant(
          secondPackage.variants.single.id,
        ),
        currentRepository: second,
        libraryPath: nextDirectory,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      expect(downloader.state.source, DownloadSource.hf);
      expect(downloader.state.libraryPath, nextDirectory);
      expect(
        requests.last,
        '/hf/publisher/second/resolve/$revision/model.gguf',
      );
    },
  );
}
