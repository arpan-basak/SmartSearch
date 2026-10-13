import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// A browser surface for Google searches initiated from Apex AI.
class GoogleSearchBrowserPage extends StatefulWidget {
  const GoogleSearchBrowserPage({required this.query, super.key});

  final String query;

  static Uri searchUri(String query) =>
      Uri.https('www.google.com', '/search', {'q': query});

  @override
  State<GoogleSearchBrowserPage> createState() =>
      _GoogleSearchBrowserPageState();
}

class _GoogleSearchBrowserPageState extends State<GoogleSearchBrowserPage> {
  WebViewController? _controller;
  bool _isLoading = true;
  String? _errorMessage;

  bool get _isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  void initState() {
    super.initState();
    if (!_isSupportedPlatform) return;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _isLoading = true;
                _errorMessage = null;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() {
                _isLoading = false;
                _errorMessage =
                    'Could not load this page. Check your internet connection and try again.';
              });
            }
          },
          onNavigationRequest: (_) => NavigationDecision.navigate,
        ),
      )
      ..loadRequest(GoogleSearchBrowserPage.searchUri(widget.query));
  }

  Future<void> _goBack() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
    }
  }

  Future<void> _goForward() async {
    final controller = _controller;
    if (controller != null && await controller.canGoForward()) {
      await controller.goForward();
    }
  }

  Future<void> _openExternally() async {
    final url = await _controller?.currentUrl();
    final opened = await launchUrl(
      url == null
          ? GoogleSearchBrowserPage.searchUri(widget.query)
          : Uri.parse(url),
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open this page externally.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.query.trim().isEmpty ? 'Google Search' : widget.query;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: const BackButton(),
        actions: [
          IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: _goBack,
          ),
          IconButton(
            tooltip: 'Forward',
            icon: const Icon(Icons.arrow_forward),
            onPressed: _goForward,
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _controller?.reload,
          ),
          IconButton(
            tooltip: 'Open externally',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openExternally,
          ),
        ],
      ),
      body: !_isSupportedPlatform
          ? const _UnsupportedBrowser()
          : Stack(
              children: [
                if (_errorMessage == null)
                  WebViewWidget(controller: _controller!),
                if (_errorMessage != null)
                  _BrowserError(
                    message: _errorMessage!,
                    onRetry: _controller!.reload,
                  ),
                if (_isLoading) const LinearProgressIndicator(),
              ],
            ),
    );
  }
}

class _BrowserError extends StatelessWidget {
  const _BrowserError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 48),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
}

class _UnsupportedBrowser extends StatelessWidget {
  const _UnsupportedBrowser();

  @override
  Widget build(BuildContext context) => const _BrowserError(
        message: 'In-app web search is not available on this platform.',
        onRetry: _noOp,
      );

  static void _noOp() {}
}
