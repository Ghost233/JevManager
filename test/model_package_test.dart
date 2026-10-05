import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jev_manager/hf_model_browser.dart';
import 'package:jev_manager/model_downloader.dart';
import 'package:jev_manager/model_package.dart';

const _revision = '0123456789012345678901234567890123456789';

void main() {
  test('a GGUF quantization resolves its complete shards and companions', () {
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: _revision,
      requestedRevision: 'main',
      source: Uri.parse('https://huggingface.co'),
      files: const [
        HfModelFile(path: 'Model-Q4_K_M-00001-of-00002.gguf', sizeBytes: 3),
        HfModelFile(path: 'Model-Q4_K_M-00002-of-00002.gguf', sizeBytes: 3),
        HfModelFile(path: 'Model-Q8_0.gguf', sizeBytes: 99),
        HfModelFile(path: 'config.json', sizeBytes: 2),
        HfModelFile(path: 'tokenizer.json', sizeBytes: 2),
        HfModelFile(path: 'decision_head.safetensors', sizeBytes: 4),
        HfModelFile(path: 'README.md', sizeBytes: 8),
      ],
    );
    final packages = ModelPackage.discover(repository);
    expect(packages, hasLength(1));
    final model = packages.single;
    expect(model.label, 'Model');
    expect(model.repository.revision, _revision);
    expect(model.variants.map((variant) => variant.quantization).toSet(), {
      'Q4_K_M',
      'Q8_0',
    });
    final q4 = model.variants.singleWhere(
      (variant) => variant.quantization == 'Q4_K_M',
    );
    final selection = model.selectVariant(q4.id);
    expect(selection.variant.canDownload, isTrue);
    expect(selection.variant.format, 'GGUF');
    expect(selection.variant.sizeBytes, 14);
    expect(selection.variant.files.map((file) => file.path).toSet(), {
      'Model-Q4_K_M-00001-of-00002.gguf',
      'Model-Q4_K_M-00002-of-00002.gguf',
      'config.json',
      'tokenizer.json',
      'decision_head.safetensors',
    });
    expect(() => selection.variant.files.clear(), throwsUnsupportedError);
  });

  test(
    'package action reuses only complete full-hash verified installations',
    () async {
      final root = await Directory.systemTemp.createTemp('jev-package-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.add(utf8.encode('abc'));
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      addTearDown(() async {
        downloader.close();
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final repository = HfRepositoryFiles(
        summary: const HfRepositorySummary(id: 'publisher/model'),
        revision: _revision,
        requestedRevision: 'main',
        source: endpoint,
        files: const [
          HfModelFile(
            path: 'Model-Q8_0.gguf',
            sizeBytes: 3,
            isLfs: true,
            sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
          ),
          HfModelFile(path: 'Model-Q4_K_M.gguf', sizeBytes: 99),
        ],
      );
      await downloader.download(
        repository: repository,
        selectedFilePaths: {'Model-Q8_0.gguf'},
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      final file = File('${root.path}/publisher/model/Model-Q8_0.gguf');
      final modified = (await file.stat()).modified;
      final records = await Directory('${root.path}/.jevmanager/installations')
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      final originalRecord = await records.single.readAsString();
      final package = ModelPackage.discover(repository).single;
      final selection = package.selectVariant(
        package.variants
            .singleWhere((variant) => variant.quantization == 'Q8_0')
            .id,
      );
      await downloader.downloadPackage(
        selection: selection,
        currentRepository: repository,
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      expect(requests, 1);
      expect((await file.stat()).modified, modified);
      expect(await records.single.readAsString(), originalRecord);
      await file.writeAsString('xyz');
      await downloader.downloadPackage(
        selection: selection,
        currentRepository: repository,
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.conflict);
      expect(await file.readAsString(), 'xyz');
      expect(requests, 1);
      final newer = HfRepositoryFiles(
        summary: repository.summary,
        revision: '1111111111111111111111111111111111111111',
        requestedRevision: 'main',
        source: endpoint,
        files: repository.files,
      );
      await downloader.downloadPackage(
        selection: selection,
        currentRepository: newer,
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.failed);
      expect(requests, 1);
    },
  );

  test(
    'a Safetensors folder package resolves its index tokenizer and head',
    () async {
      final root = await Directory.systemTemp.createTemp('jev-package-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = {
        'encoder/model.safetensors.index.json': '{"weight_map":{"layer.a":"alpha.safetensors","layer.b":"beta.safetensors"}}',
        'encoder/alpha.safetensors': 'abc',
        'encoder/beta.safetensors': 'def',
        'encoder/unused-quant.safetensors': 'unselected',
        'encoder/config.json': '{}',
        'encoder/tokenizer.json': '{}',
        'encoder/decision_head.npz': 'head',
        'other-model/model.safetensors': 'other',
        'other-model/config.json': '{}',
        'other-model/tokenizer.json': '{}',
      };
      final requested = <String>[];
      server.listen((request) async {
        final path = request.uri.pathSegments.skip(4).join('/');
        requested.add(path);
        request.response.add(utf8.encode(bodies[path]!));
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      addTearDown(() async {
        downloader.close();
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final repository = HfRepositoryFiles(
        summary: const HfRepositorySummary(id: 'publisher/model'),
        revision: _revision,
        requestedRevision: 'main',
        source: endpoint,
        files: bodies.entries
            .map(
              (entry) => HfModelFile(
                path: entry.key,
                sizeBytes: utf8.encode(entry.value).length,
              ),
            )
            .toList(),
      );
      final packages = ModelPackage.discover(repository);
      expect(packages.map((package) => package.directory).toSet(), {
        'encoder',
        'other-model',
      });
      final package = packages.singleWhere(
        (package) => package.directory == 'encoder',
      );
      final variant = package.variants.single;
      expect(variant.format, 'Safetensors');
      expect(variant.canDownload, isTrue);
      expect(variant.resolution, PackageResolution.indexed);
      expect(variant.sizeBytes, isNull);
      await downloader.downloadPackage(
        selection: package.selectVariant(variant.id),
        currentRepository: repository,
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      final expected = bodies.keys
          .where(
            (path) => path.startsWith('encoder/') && !path.contains('unused-'),
          )
          .toSet();
      expect(requested.toSet(), expected);
      for (final path in expected) {
        expect(
          await File('${root.path}/publisher/model/$path').readAsString(),
          bodies[path],
        );
      }
      expect(
        await File(
          '${root.path}/publisher/model/encoder/unused-quant.safetensors',
        ).exists(),
        isFalse,
      );
      expect(
        await Directory('${root.path}/publisher/model/other-model').exists(),
        isFalse,
      );
    },
  );

  test(
    'a model includes its sole projector and rejects ambiguous projectors',
    () {
      final repository = HfRepositoryFiles(
        summary: const HfRepositorySummary(
          id: 'lmstudio-community/Qwen3.5-0.8B-GGUF',
        ),
        revision: '26bab2c9369648924251c0ebb3dae012f5147707',
        requestedRevision: 'main',
        source: Uri.parse('https://huggingface.co'),
        files: const [
          HfModelFile(path: 'Qwen3.5-0.8B-Q4_K_M.gguf', sizeBytes: 527502816),
          HfModelFile(path: 'Qwen3.5-0.8B-Q6_K.gguf', sizeBytes: 629743584),
          HfModelFile(path: 'Qwen3.5-0.8B-Q8_0.gguf', sizeBytes: 811843040),
          HfModelFile(
            path: 'mmproj-Qwen3.5-0.8B-BF16.gguf',
            sizeBytes: 207345952,
          ),
          HfModelFile(path: 'README.md', sizeBytes: 2108),
        ],
      );
      final model = ModelPackage.discover(repository).single;
      expect(model.variants, hasLength(3));
      final q8 = model.variants.singleWhere(
        (variant) => variant.quantization == 'Q8_0',
      );
      expect(q8.canDownload, isTrue);
      expect(q8.sizeBytes, 1019188992);
      expect(q8.files.map((file) => file.path).toSet(), {
        'Qwen3.5-0.8B-Q8_0.gguf',
        'mmproj-Qwen3.5-0.8B-BF16.gguf',
      });
      final ambiguous = HfRepositoryFiles(
        summary: repository.summary,
        revision: repository.revision,
        requestedRevision: 'main',
        source: repository.source,
        files: [
          ...repository.files,
          const HfModelFile(path: 'mmproj-other-F16.gguf', sizeBytes: 100),
        ],
      );
      final unresolved = ModelPackage.discover(ambiguous).single;
      expect(unresolved.variants, hasLength(3));
      expect(
        unresolved.variants.every(
          (variant) =>
              variant.resolution == PackageResolution.ambiguous &&
              !variant.canDownload &&
              variant.sizeBytes == null,
        ),
        isTrue,
      );
      expect(
        unresolved.variants.first.unavailableReason,
        contains('projector'),
      );
      final projectorOnly = HfRepositoryFiles(
        summary: repository.summary,
        revision: repository.revision,
        requestedRevision: 'main',
        source: repository.source,
        files: [repository.files[3]],
      );
      expect(ModelPackage.discover(projectorOnly), isEmpty);
    },
  );
}
