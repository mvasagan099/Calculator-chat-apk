import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/security/private_media_files.dart';
import '../../core/widgets/actions.dart';
import 'private_media_guard.dart';

class FullScreenImageViewer extends ConsumerStatefulWidget {
  const FullScreenImageViewer({
    super.key,
    required this.bytes,
    this.expiresAt,
    this.filename,
    this.sizeBytes,
    this.attachment,
    this.client,
  });

  final Uint8List bytes;
  final DateTime? expiresAt;
  final String? filename;
  final int? sizeBytes;
  final Map<String, dynamic>? attachment;
  final SupabaseClient? client;

  @override
  ConsumerState<FullScreenImageViewer> createState() =>
      _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends ConsumerState<FullScreenImageViewer> {
  late final Uint8List _imageBytes;
  final TransformationController _transformController =
      TransformationController();
  bool _isZoomed = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    // Make a defensive copy to own the memory buffer independently of list recycles.
    _imageBytes = Uint8List.fromList(widget.bytes);
    _transformController.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    final scale = _transformController.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.05;
    if (zoomed != _isZoomed && mounted) {
      setState(() => _isZoomed = zoomed);
    }
  }

  void _toggleZoom() {
    if (_isZoomed) {
      _transformController.value = Matrix4.identity();
    } else {
      _transformController.value = Matrix4.identity()..scaleByDouble(2.5, 2.5, 1.0, 1.0);
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final ext = widget.filename?.split('.').last ?? 'jpg';
      final file = await PrivateMediaFiles().save(
        _imageBytes,
        extension: ext,
        expiresAt: widget.expiresAt,
      );
      try {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)]),
        );
      } finally {
        if (await file.exists()) await file.delete();
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  void dispose() {
    _transformController.removeListener(_onTransformChanged);
    _transformController.dispose();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _imageBytes.fillRange(0, _imageBytes.length, 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filename = widget.filename ?? 'Image';
    final sizeStr = widget.sizeBytes != null
        ? '${((widget.sizeBytes!) / 1024).ceil()} KB'
        : null;

    return PrivateMediaGuard(
      expiresAt: widget.expiresAt,
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black.withValues(alpha: 0.7),
          iconTheme: const IconThemeData(color: Colors.white),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                filename,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (sizeStr != null)
                Text(
                  sizeStr,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          actions: [
            if (_isZoomed)
              IconButton(
                tooltip: 'Reset zoom',
                icon: const Icon(Icons.zoom_out_map, color: Colors.white),
                onPressed: () {
                  _transformController.value = Matrix4.identity();
                },
              ),
            IconButton(
              tooltip: 'Share',
              icon: _sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.ios_share, color: Colors.white),
              onPressed: _sharing ? null : () => act(context, _share),
            ),
          ],
        ),
        body: Center(
          child: GestureDetector(
            onDoubleTap: _toggleZoom,
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: 0.8,
              maxScale: 5.0,
              child: Image.memory(
                _imageBytes,
                fit: BoxFit.contain,
                cacheWidth: 2160,
                errorBuilder: (_, _, _) => const Center(
                  child: Text(
                    'Media unavailable',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
