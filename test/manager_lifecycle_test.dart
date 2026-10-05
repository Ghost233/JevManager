import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jev_manager/council.dart';
import 'package:jev_manager/council_mcp.dart';
import 'package:jev_manager/engine_catalog.dart';
import 'package:jev_manager/manager_lifecycle.dart';
import 'package:jev_manager/llama_engine.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'fixtures/council_runtime.dart';

Future<McpClient> _client(Uri endpoint) async {
  final client = McpClient(
    const Implementation(name: 'lifecycle-test', version: '1'),
  );
  await client.connect(StreamableHttpClientTransport(endpoint));
  return client;
}

void main() {
  test('explicit shutdown drains desktop and two MCP callers, rejects new work and preserves a foreign endpoint', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    await mcp.start();
    final first = await _client(mcp.endpoint!),
        second = await _client(mcp.endpoint!);
    addTearDown(first.close);
    addTearDown(second.close);
    final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => foreign.close(force: true));
    foreign.listen((request) async {
      request.response.write('foreign still running');
      await request.response.close();
    });
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
    );
    runtime.io.holdConsultation();
    final desktop = council.consult(
      state: 'desktop-inflight',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    Map<String, dynamic> args(String state) => {
      'state': state,
      'options': [
        {'id': 'accept', 'text': '接受'},
        {'id': 'reject', 'text': '拒绝'},
      ],
    };
    final firstCall = first
        .callTool(
          CallToolRequest(
            name: 'consult_jev_council',
            arguments: args('mcp-first'),
          ),
        )
        .then<Object>((value) => value, onError: (Object error) => error);
    final secondCall = second
        .callTool(
          CallToolRequest(
            name: 'consult_jev_council',
            arguments: args('mcp-second'),
          ),
        )
        .then<Object>((value) => value, onError: (Object error) => error);
    final watch = Stopwatch()..start();
    while (runtime.io.requests.length < 6 || mcp.state.activeRequests < 2) {
      if (watch.elapsed > const Duration(seconds: 3)) {
        throw StateError('Callers did not reach external decision I/O');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final shutdown = manager.shutdown();
    final repeated = manager.shutdown();
    shutdown.ignore();
    repeated.ignore();
    expect(identical(shutdown, repeated), isTrue);
    await expectLater(
      council.consult(state: 'new', options: {'accept': '接受', 'reject': '拒绝'}),
      throwsStateError,
    );
    await expectLater(
      runtime.catalog
          .providerFor(EngineCatalog.officialId)
          .start(runtime.library.state.artifacts.first.id),
      throwsStateError,
    );
    await shutdown.timeout(const Duration(seconds: 3));
    final cancelled = await desktop;
    expect(
      cancelled.seats.every(
        (seat) => seat.status == CouncilSeatStatus.cancelled,
      ),
      isTrue,
    );
    await Future.wait([firstCall, secondCall]);
    expect(council.state.busy, isFalse);
    expect(mcp.state.status, CouncilMcpStatus.stopped);
    expect(mcp.state.activeRequests, 0);
    expect(runtime.io.killedChildren, 2);
    expect(manager.state, ManagerLifecycleState.stopped);
    final client = HttpClient();
    try {
      expect(
        await utf8.decoder
            .bind(
              await (await client.getUrl(
                Uri.parse('http://127.0.0.1:${foreign.port}'),
              )).close(),
            )
            .join(),
        'foreign still running',
      );
    } finally {
      client.close(force: true);
    }
  });

  test('shutdown awaits an in-flight spawn handle then stops its late child without waiting for cold load', () async {
    final io = _HeldSpawnIO();
    final runtime = await CouncilRuntime.create(modelCount: 1, processIO: io);
    addTearDown(runtime.close);
    await runtime.catalog.stopManaged();
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
    );
    io.hold = true;
    final starting = runtime.engine
        .start(runtime.library.state.artifacts.single.id)
        .then<Object>((value) => value, onError: (Object error) => error);
    await io.spawned.future.timeout(const Duration(seconds: 2));
    var finished = false;
    final shutdown = manager.shutdown();
    shutdown.ignore();
    shutdown.then((_) => finished = true, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(finished, isFalse);
    io.releaseHandle.complete();

    await shutdown.timeout(const Duration(milliseconds: 700));

    expect(await starting, isA<Exception>());
    expect(io.killedChildren, 2);
    expect(runtime.engine.hasLiveInstances, isFalse);
    expect(manager.state, ManagerLifecycleState.stopped);
  });

  test('queued MCP start and direct service restart are rejected once explicit exit begins', () async {
    final runtime = await CouncilRuntime.create(modelCount: 0);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
    );
    final queued = mcp.start();
    queued.ignore();
    final shutdown = manager.shutdown();
    await expectLater(queued, throwsStateError);
    await expectLater(mcp.start(), throwsStateError);
    await expectLater(runtime.catalog.refresh(), throwsStateError);
    await shutdown;
    expect(mcp.endpoint, isNull);
    expect(mcp.state.status, CouncilMcpStatus.stopped);
    expect(manager.state, ManagerLifecycleState.stopped);
  });

  test('a child cleanup failure is reported after the remaining owned child and MCP have been stopped', () async {
    final io = _KillFailureIO();
    final runtime = await CouncilRuntime.create(processIO: io);
    addTearDown(() async {
      io.failKills = false;
      await runtime.close();
    });
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    await mcp.start();
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
    );

    final attempt = manager.shutdown();
    await expectLater(attempt, throwsStateError);

    expect(manager.state, ManagerLifecycleState.failed);
    expect(manager.error, contains('simulated OS refusal'));
    expect(runtime.io.killedChildren, 1);
    expect(runtime.engine.hasLiveInstances, isTrue);
    expect(mcp.state.status, CouncilMcpStatus.stopped);
    expect(council.state.busy, isFalse);
    expect(identical(manager.shutdown(), attempt), isTrue);
    await expectLater(manager.shutdown(), throwsStateError);
  });

  test('exit during real model verification drains the file work and never creates a new child', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    await runtime.catalog.stopManaged();
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
    );
    final exiting = Completer<Future<void>>();
    final subscription = runtime.library.changes.listen((state) {
      if (state.scanning && !exiting.isCompleted) {
        exiting.complete(manager.shutdown());
      }
    });
    addTearDown(subscription.cancel);
    final starting = runtime.engine
        .start(runtime.library.state.artifacts.single.id)
        .then<Object>((value) => value, onError: (Object error) => error);

    final shutdown = await exiting.future.timeout(const Duration(seconds: 2));
    await shutdown.timeout(const Duration(seconds: 2));

    expect(await starting, isA<LlamaEngineException>());
    expect(runtime.io.killedChildren, 1);
    expect(runtime.engine.hasLiveInstances, isFalse);
    expect(runtime.library.state.scanning, isFalse);
    expect(manager.state, ManagerLifecycleState.stopped);
  });
}

class _HeldSpawnIO extends CouncilRuntimeIO {
  bool hold = false;
  final spawned = Completer<void>();
  final releaseHandle = Completer<void>();
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    final child = await super.start(executable, arguments);
    if (hold) {
      spawned.complete();
      await releaseHandle.future;
      final alias = arguments[arguments.indexOf('--alias') + 1];
      await closeEndpoint(alias);
    }
    return child;
  }
}

class _KillFailureIO extends CouncilRuntimeIO {
  bool failKills = true;
  int children = 0;
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    final child = await super.start(executable, arguments);
    return ++children == 1 ? _KillFailureChild(child, this) : child;
  }
}

class _KillFailureChild implements EngineChild {
  _KillFailureChild(this.child, this.owner);
  final EngineChild child;
  final _KillFailureIO owner;
  @override
  int get pid => child.pid;
  @override
  Future<int> get exitCode => child.exitCode;
  @override
  Stream<List<int>> get stdout => child.stdout;
  @override
  Stream<List<int>> get stderr => child.stderr;
  @override
  bool kill(ProcessSignal signal) {
    if (owner.failKills) {
      throw const ProcessException('kill', [], 'simulated OS refusal');
    }
    return child.kill(signal);
  }
}
