import 'dart:async';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const WalrusDemoApp());
}

class WalrusDemoApp extends StatefulWidget {
  const WalrusDemoApp({super.key});

  @override
  State<WalrusDemoApp> createState() => _WalrusDemoAppState();
}

class _WalrusDemoAppState extends State<WalrusDemoApp> {
  late WalrusManager _manager;
  final ValueNotifier<String?> _recentBlobId = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _manager = WalrusManager();
  }

  @override
  void dispose() {
    _recentBlobId.dispose();
    unawaited(_manager.dispose());
    super.dispose();
  }

  void _handleBlobCreated(String blobId) {
    _recentBlobId.value = blobId;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Walrus Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Walrus Demo'),
            bottom: const TabBar(
              tabs: <Widget>[
                Tab(text: 'Upload'),
                Tab(text: 'Fetch'),
              ],
            ),
          ),
          body: TabBarView(
            children: <Widget>[
              UploadTab(manager: _manager, onBlobCreated: _handleBlobCreated),
              FetchTab(manager: _manager, recentBlobId: _recentBlobId),
            ],
          ),
        ),
      ),
    );
  }
}

class WalrusManager {
  WalrusManager()
    : client = WalrusClient(
        publisherBaseUrl: Uri.parse(
          'https://walrus-testnet-publisher.starduststaking.com', //this endpoint was changed to https to avoid 301 redirects
        ),
        aggregatorBaseUrl: Uri.parse('https://agg.test.walrus.eosusa.io'),
        timeout: const Duration(seconds: 30),
        cacheMaxSize: 100,
        useSecureConnection: false, // testnet certs are currently untrusted
        // logLevel: WalrusLogLevel.basic,
      );

  final WalrusClient client;

  Future<void> dispose() async {
    await client.close();
  }
}

class UploadTab extends StatefulWidget {
  const UploadTab({
    required this.manager,
    required this.onBlobCreated,
    super.key,
  });

  final WalrusManager manager;
  final ValueChanged<String> onBlobCreated;

  @override
  State<UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<UploadTab> {
  final ImagePicker _picker = ImagePicker();
  String _status = 'Pick an image to upload';
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    if (_supportsRetrieveLostData) {
      unawaited(_recoverPendingSelection());
    }
  }

  bool get _supportsRetrieveLostData {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<void> _recoverPendingSelection() async {
    if (!_supportsRetrieveLostData) {
      return;
    }
    try {
      final LostDataResponse response = await _picker.retrieveLostData();
      if (!mounted || response.isEmpty) {
        return;
      }
      if (response.file != null) {
        await _handleFile(response.file!);
      } else if (response.files != null && response.files!.isNotEmpty) {
        await _handleFile(response.files!.first);
      } else if (response.exception != null) {
        debugPrint('Picker error: ${response.exception}');
      }
    } on UnimplementedError {
      debugPrint('retrieveLostData is not implemented on this platform');
    }
  }

  Future<void> _pickImage() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 20,
    );
    if (file == null) {
      return;
    }
    await _handleFile(file);
  }

  Future<void> _handleFile(XFile file) async {
    setState(() {
      _uploading = true;
      _status = 'Awaiting response...';
    });

    try {
      final Uint8List data = await file.readAsBytes();
      final Map<String, dynamic> response = await widget.manager.client.putBlob(
        data: data,
      );
      final String? blobId = findBlobId(response);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = blobId != null
            ? 'Blob ID: $blobId'
            : 'Upload succeeded: ${response.toString()}';
      });
      if (blobId != null) {
        widget.onBlobCreated(blobId);
      }
    } catch (error, stackTrace) {
      debugPrint('Upload failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FilledButton.icon(
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Pick image from library'),
            onPressed: _uploading ? null : _pickImage,
          ),
          const SizedBox(height: 16),
          if (_uploading) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          Text(_status, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class FetchTab extends StatefulWidget {
  const FetchTab({
    required this.manager,
    required this.recentBlobId,
    super.key,
  });

  final WalrusManager manager;
  final ValueNotifier<String?> recentBlobId;

  @override
  State<FetchTab> createState() => _FetchTabState();
}

class _FetchTabState extends State<FetchTab> {
  late final TextEditingController _controller;
  Uint8List? _imageBytes;
  String _status = 'Enter a blob ID to download';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    widget.recentBlobId.addListener(_handleRecentBlobId);
  }

  @override
  void didUpdateWidget(FetchTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recentBlobId != widget.recentBlobId) {
      oldWidget.recentBlobId.removeListener(_handleRecentBlobId);
      widget.recentBlobId.addListener(_handleRecentBlobId);
    }
  }

  void _handleRecentBlobId() {
    final String? value = widget.recentBlobId.value;
    if (value == null || value.isEmpty) {
      return;
    }
    if (_controller.text == value) {
      return;
    }
    _controller.text = value;
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    setState(() {
      _status = 'Blob ID ready for download';
    });
  }

  Future<void> _fetch() async {
    final String blobId = _controller.text.trim();
    if (blobId.isEmpty) {
      setState(() {
        _status = 'Please enter a blob ID';
      });
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Fetching content...';
    });

    try {
      final Uint8List bytes = await widget.manager.client.getBlobByObjectId(
        blobId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _imageBytes = bytes;
        _status = 'Download complete';
      });
    } catch (error, stackTrace) {
      debugPrint('Download failed for $blobId: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _imageBytes = null;
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.recentBlobId.removeListener(_handleRecentBlobId);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: <Widget>[
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'Blob ID',
              hintText: 'Paste the blob ID from the upload tab',
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _fetch(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.download_outlined),
            label: const Text('Download blob'),
            onPressed: _busy ? null : _fetch,
          ),
          const SizedBox(height: 24),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          Text(_status, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 16),
          if (_imageBytes != null)
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(_imageBytes!, fit: BoxFit.cover),
              ),
            ),
        ],
      ),
    );
  }
}

String? findBlobId(dynamic json) {
  if (json is Map<String, dynamic>) {
    for (final MapEntry<String, dynamic> entry in json.entries) {
      if (entry.key == 'blobId') {
        final dynamic value = entry.value;
        if (value is String && value.isNotEmpty) {
          return value;
        }
      }
      final String? nested = findBlobId(entry.value);
      if (nested != null) {
        return nested;
      }
    }
  } else if (json is Iterable) {
    for (final dynamic element in json) {
      final String? nested = findBlobId(element);
      if (nested != null) {
        return nested;
      }
    }
  }
  return null;
}
