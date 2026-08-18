import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/ios_tactile.dart';

/// Full-screen WebView render of a local `.html`/`.htm` file (workspace
/// mounts, storage uploads). Unlike the chat-side html preview (which
/// renders a code string), this loads the file from disk via `loadFile`, so
/// same-directory css/js/image resources resolve — on iOS the WKWebView read
/// access covers the containing directory (webview_flutter_wkwebview
/// `WebKitLoadFileParams.readAccessPath` defaults to `dirname`).
///
/// Only reachable on iOS/Android (desktop keeps the system default app);
/// still guards load failures with a readable error view instead of the
/// "success" lie the system-open path used to report.
class HtmlFilePreviewPage extends StatefulWidget {
  const HtmlFilePreviewPage({
    super.key,
    required this.hostPath,
    required this.displayName,
  });

  final String hostPath;
  final String displayName;

  @override
  State<HtmlFilePreviewPage> createState() => _HtmlFilePreviewPageState();
}

enum _HtmlFilePreviewState { loading, web, error }

class _HtmlFilePreviewPageState extends State<HtmlFilePreviewPage> {
  _HtmlFilePreviewState _state = _HtmlFilePreviewState.loading;
  bool _pageLoading = true;
  String? _errorMessage;
  WebViewController? _controller;
  int _generation = 0;

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Invalidate any in-flight load so its continuation cannot touch state
    // after disposal.
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_generation;
    try {
      final f = File(widget.hostPath);
      final stat = await f.stat();
      if (stat.size > KelivoFilesystemMcpServerEngine.readWindowBytes) {
        _fail(l10n.mountFilesPreviewTooLarge(widget.displayName));
        return;
      }
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) {
              if (mounted && gen == _generation) {
                setState(() => _pageLoading = true);
              }
            },
            onPageFinished: (_) {
              if (mounted && gen == _generation) {
                setState(() => _pageLoading = false);
              }
            },
            onWebResourceError: (err) {
              if (!(err.isForMainFrame ?? false)) return;
              if (mounted && gen == _generation) {
                _fail(
                  l10n.mountFilesPreviewReadFailed(
                    widget.displayName,
                    err.description,
                  ),
                );
              }
            },
            onNavigationRequest: (req) async {
              // Main-frame navigation away from the local page: hand http(s)
              // to the system browser instead of losing the preview context
              // inside the app. Relative file:// navigations stay in place.
              final uri = Uri.tryParse(req.url);
              if (uri != null &&
                  (uri.scheme == 'http' || uri.scheme == 'https')) {
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } catch (e) {
                  debugPrint('HtmlFilePreviewPage: open in browser failed: $e');
                }
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
          ),
        );
      await c.loadFile(widget.hostPath);
      if (mounted && gen == _generation) {
        setState(() {
          _controller = c;
          _state = _HtmlFilePreviewState.web;
        });
      }
    } catch (e) {
      if (!mounted || gen != _generation) return;
      _fail(l10n.mountFilesPreviewReadFailed(widget.displayName, '$e'));
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _state = _HtmlFilePreviewState.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(widget.displayName),
      ),
      body: switch (_state) {
        _HtmlFilePreviewState.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        _HtmlFilePreviewState.error => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _errorMessage ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
        _HtmlFilePreviewState.web => Column(
          children: [
            if (_pageLoading) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: WebViewWidget(controller: _controller!)),
          ],
        ),
      },
    );
  }
}
