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
      final id = await provider.addServer(
        enabled: true,
        name: 'Auto Reconnect',
        transport: McpTransportType.http,
        url: 'http://127.0.0.1:$port/mcp',
        // 1s supervisor heartbeat so the test does not wait 12s.
        heartbeatIntervalSeconds: 1,
      );
      await pumpEventQueue();

      // Phase 1: server is down — connect fails and the provider reports
      // the error state (no tools available to the main agent).
      expect(provider.isConnected(id), isFalse);
      expect(provider.statusFor(id), McpStatus.error);

      // Phase 2: server comes up (e.g. the network is restored). The
      // supervisor heartbeat must reconnect automatically without any
      // user action.
      final server = await _startMcpServer(port);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          if (provider.isConnected(id)) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(
          provider.isConnected(id),
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
