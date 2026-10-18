import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/widgets/actions.dart';
import 'private_media_guard.dart';

class TextDocumentViewer extends StatefulWidget {
  const TextDocumentViewer({
    super.key,
    required this.filename,
    required this.content,
    this.expiresAt,
  });

  final String filename;
  final String content;
  final DateTime? expiresAt;

  @override
  State<TextDocumentViewer> createState() => _TextDocumentViewerState();
}

class _TextDocumentViewerState extends State<TextDocumentViewer> {
  bool _sharing = false;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await SharePlus.instance.share(
        ShareParams(text: widget.content, subject: widget.filename),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) => PrivateMediaGuard(
    expiresAt: widget.expiresAt,
    builder: (context) => Scaffold(
      appBar: AppBar(
        title: Text(
          widget.filename,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Share text',
            icon: _sharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            onPressed: _sharing ? null : () => act(context, _share),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            widget.content,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      ),
    ),
  );
}
