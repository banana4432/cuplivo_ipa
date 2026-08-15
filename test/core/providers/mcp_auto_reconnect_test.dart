import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/mcp_provider.dart';

/// Minimal MCP streamable-HTTP server. Answers `initialize`,
/// `notifications/initialized` and `tools/list` so mcp_client can complete
/// a real connect handshake. No `MCP-Session-Id` header is sent, so the
/// transport stays in pure request/response mode (no SSE GET stream).
Future<HttpServer> _startMcpServer(int port) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((request) async {
    if (request.method != 'POST') {
      request.response.statusCode = 405;
      await request.response.close();
      return;
    }
    final body = await utf8.decoder.bind(request).join();
    final msg = jsonDecode(body) as Map<String, dynamic>;
    final method = msg['method'];
    final id = msg['id'];
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (method == 'initialize') {
      response.statusCode = 200;
      response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': (msg['params'] as Map)['protocolVersion'],
            'serverInfo': {'name': 'Test MCP', 'version': '1.0.0'},
            'capabilities': {'tools': true},
          },
        }),
      );
    } else if (method == 'notifications/initialized') {
      response.statusCode = 202;
    } else {
      // tools/list and anything else: an empty result.
      response.statusCode = 200;
      response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': <Object>[],
          },
        }),
      );
    }
    await response.close();
  });
  return server;
}

/// Returns a port that is free right now (bound then released).
Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

/// Polls [predicate] until it returns true or [timeout] elapses.
Future<bool> _waitUntil(
  Future<bool> Function() predicate,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return predicate();
}

void main() {
  test(
    'an enabled server whose initial connect failed auto-reconnects once it '
    'becomes reachable (network restore after app start)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final port = await _freePort();

      final provider = McpProvider(
        contextProvider: () => throw UnimplementedError(),
      );
      // Fail fast: mcp_client swallows transport errors, so a dead endpoint
      // only surfaces after the request timeout (default 30s would make this
      // test too slow). Each failed connect also retries 3x with 2s delays.
      await provider.updateRequestTimeout(const Duration(milliseconds: 800));
      final id = await provider.addServer(
        enabled: true,
        name: 'Auto Reconnect',
        transport: McpTransportType.http,
        url: 'http://127.0.0.1:$port/mcp',
        // 1s supervisor heartbeat so the test does not wait 12s.
        heartbeatIntervalSeconds: 1,
      );
      await pumpEventQueue();

      // Phase 1: server is down — the initial connect fails and the provider
      // lands in the error state (tools unavailable to the main agent).
      final reachedError = await _waitUntil(
        () async => provider.statusFor(id) == McpStatus.error,
        const Duration(seconds: 12),
      );
      expect(
        reachedError,
        isTrue,
        reason: 'connect to a dead endpoint should end in the error state',
      );
      expect(provider.isConnected(id), isFalse);

      // Phase 2: server comes up (e.g. the network is restored). The
      // supervisor heartbeat must reconnect automatically without any
      // user action.
      final server = await _startMcpServer(port);
      try {
        final reconnected = await _waitUntil(
          () async => provider.isConnected(id),
          const Duration(seconds: 15),
        );
        expect(
          reconnected,
          isTrue,
          reason: 'supervisor heartbeat should auto-reconnect the server',
        );
        expect(provider.statusFor(id), McpStatus.connected);
        expect(provider.errorFor(id), isNull);
      } finally {
        // Cancel the supervisor heartbeat and the disconnect listener.
        await provider.disconnect(id);
        await server.close(force: true);
      }
    },
  );
}
