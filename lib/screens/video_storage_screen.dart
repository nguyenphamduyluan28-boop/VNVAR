import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/recording_service.dart';

class VideoStorageScreen extends StatefulWidget {
  final RecordingService recordingService;
  final String viewerAddress;

  const VideoStorageScreen({
    super.key,
    required this.recordingService,
    required this.viewerAddress,
  });

  @override
  State<VideoStorageScreen> createState() => _VideoStorageScreenState();
}

class _VideoStorageScreenState extends State<VideoStorageScreen> {
  bool _loading = true;
  int _totalBytes = 0;
  List<RecordedSegment> _videos = const [];
  int _segmentMinutes = 3;
  String _storagePath = '';
  StreamSubscription<void>? _videoChangesSubscription;
  bool _refreshing = false;
  bool _refreshPending = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _videoChangesSubscription = widget.recordingService.videoChanges.listen((
      _,
    ) {
      unawaited(_refresh(showLoading: false));
    });
  }

  Future<void> _refresh({bool showLoading = true}) async {
    if (_refreshing) {
      _refreshPending = true;
      return;
    }
    _refreshing = true;
    if (showLoading && mounted) setState(() => _loading = true);
    try {
      final videos = widget.recordingService.segments;
      var bytes = 0;
      for (final video in videos) {
        final file = File(video.path);
        try {
          if (await file.exists()) bytes += await file.length();
        } catch (_) {}
      }
      final storagePath = await widget.recordingService.getStoragePath();
      if (!mounted) return;
      setState(() {
        _videos = videos;
        _totalBytes = bytes;
        _segmentMinutes = widget.recordingService.segmentMinutes;
        _storagePath = storagePath;
        _loading = false;
      });
    } finally {
      _refreshing = false;
      if (_refreshPending && mounted) {
        _refreshPending = false;
        unawaited(_refresh(showLoading: false));
      }
    }
  }

  @override
  void dispose() {
    _videoChangesSubscription?.cancel();
    super.dispose();
  }

  Future<void> _chooseStorage() async {
    try {
      final path = await widget.recordingService.selectStorageFolder();
      if (path == null || path.trim().isEmpty) return;
      if (!mounted) return;
      final finalPath =
          '$path${Platform.pathSeparator}ngày-tháng-năm'
          '${Platform.pathSeparator}AUTOMODE';
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text('Xác nhận thư mục lưu'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Video .ts sẽ được lưu tại:'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F6F9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  finalPath,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CHỌN LẠI'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('SỬ DỤNG'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      await widget.recordingService.setStoragePath(path);
      await widget.recordingService.cleanupOldTempFiles();
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể sử dụng thư mục này: $error')),
      );
    }
  }

  Future<void> _changeSegmentMinutes(int? minutes) async {
    if (minutes == null || minutes == _segmentMinutes) return;
    await widget.recordingService.setSegmentMinutes(minutes);
    if (!mounted) return;
    setState(() => _segmentMinutes = minutes);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Thời lượng mới áp dụng từ đoạn kế tiếp.')),
    );
  }

  String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  Future<void> _viewVideo(RecordedSegment video) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => _VideoPlayerScreen(video: video)),
    );
  }

  String _time(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}  '
        '${two(value.day)}/${two(value.month)}/${value.year}';
  }

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(widget.viewerAddress)?.host ?? '';
    final apiBase = host.isEmpty ? 'Chưa có kết nối LAN' : 'http://$host:8080';
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FB),
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 1,
        title: const Text(
          'LƯU VIDEO',
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.4),
        ),
        actions: [
          IconButton(
            tooltip: 'Làm mới',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/vnvar_logo.png'),
            fit: BoxFit.contain,
            opacity: 0.03,
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              final information = _InformationPanel(
                totalSize: _size(_totalBytes),
                videoCount: _videos.length,
                apiBase: apiBase,
                segmentMinutes: _segmentMinutes,
                storagePath: _storagePath,
                onSegmentChanged: _changeSegmentMinutes,
                onChooseStorage:
                    widget.recordingService.supportsStorageFolderSelection
                    ? _chooseStorage
                    : null,
              );
              final savedVideos = VideoList(
                loading: _loading,
                videos: _videos,
                activeCameraId: widget.recordingService.cameraId,
                activeRecordingPath: widget.recordingService.currentPath,
                activeRecordingStartedAt:
                    widget.recordingService.currentSegmentStartedAt,
                formatSize: _size,
                formatTime: _time,
                onView: _viewVideo,
              );
              return Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: wide ? 1180 : 520),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(width: 480, child: information),
                              const SizedBox(width: 16),
                              Expanded(child: savedVideos),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(child: information),
                              const SizedBox(height: 12),
                              SizedBox(height: 300, child: savedVideos),
                            ],
                          ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ============================================================
// INFORMATION PANEL
// ============================================================

class _InformationPanel extends StatelessWidget {
  final String totalSize;
  final int videoCount;
  final String apiBase;
  final int segmentMinutes;
  final String storagePath;
  final ValueChanged<int?> onSegmentChanged;
  final VoidCallback? onChooseStorage;

  const _InformationPanel({
    required this.totalSize,
    required this.videoCount,
    required this.apiBase,
    required this.segmentMinutes,
    required this.storagePath,
    required this.onSegmentChanged,
    required this.onChooseStorage,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE3E8EF)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ------------------------------------------------
              // SUMMARY
              // ------------------------------------------------
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1565C0).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.video_settings_rounded,
                      size: 30,
                      color: Color(0xFF1565C0),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$videoCount video',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        Text(
                          totalSize,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const Divider(height: 32),

              // ------------------------------------------------
              // SEGMENT DURATION
              // ------------------------------------------------
              const _SectionLabel(
                icon: Icons.timer_outlined,
                text: 'CHIA VIDEO TỰ ĐỘNG',
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: segmentMinutes,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.timer_outlined),
                  filled: true,
                  fillColor: const Color(0xFFF6F8FB),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
                items: const [1, 2, 3, 5, 10, 15, 30]
                    .map(
                      (minutes) => DropdownMenuItem(
                        value: minutes,
                        child: Text('$minutes phút'),
                      ),
                    )
                    .toList(),
                onChanged: onSegmentChanged,
              ),

              const SizedBox(height: 24),

              // ------------------------------------------------
              // STORAGE PATH
              // ------------------------------------------------
              const _SectionLabel(
                icon: Icons.folder_rounded,
                text: 'THƯ MỤC ĐANG LƯU',
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F1FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF90CAF9)),
                      ),
                      child: SelectableText(
                        storagePath.isEmpty ? 'Chưa chọn thư mục' : storagePath,
                        maxLines: 2,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  if (onChooseStorage != null) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 11,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: onChooseStorage,
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      label: Text(
                        storagePath.isEmpty ? 'CHỌN THƯ MỤC' : 'ĐỔI THƯ MỤC',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 24),

              // ------------------------------------------------
              // API ENDPOINTS
              // ------------------------------------------------
              const _SectionLabel(
                icon: Icons.api_rounded,
                text: 'KẾT NỐI MẠNG',
              ),
              const SizedBox(height: 10),
              _SettingLine(
                icon: Icons.lan_rounded,
                title: 'Danh sách qua IP',
                value: '$apiBase/segments',
              ),
              _SettingLine(
                icon: Icons.content_cut_rounded,
                title: 'API cắt video',
                value: '$apiBase/trim',
                last: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SECTION LABEL
// ============================================================

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String text;

  const _SectionLabel({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: Colors.black45),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 12,
            letterSpacing: 0.4,
            color: Colors.black54,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// SETTING LINE
// ============================================================

class _SettingLine extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final bool last;

  const _SettingLine({
    required this.icon,
    required this.title,
    required this.value,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: const Color(0xFF1565C0).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 16, color: const Color(0xFF1565C0)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// VIDEO LIST
// ============================================================

class VideoList extends StatelessWidget {
  final bool loading;
  final List<RecordedSegment> videos;
  final String activeCameraId;
  final String? activeRecordingPath;
  final DateTime? activeRecordingStartedAt;
  final String Function(int) formatSize;
  final String Function(DateTime) formatTime;
  final ValueChanged<RecordedSegment> onView;

  const VideoList({
    super.key,
    required this.loading,
    required this.videos,
    required this.activeCameraId,
    required this.activeRecordingPath,
    required this.activeRecordingStartedAt,
    required this.formatSize,
    required this.formatTime,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final videosByCamera = <String, List<RecordedSegment>>{
      'CAM1': <RecordedSegment>[],
      'CAM2': <RecordedSegment>[],
      'CAM3': <RecordedSegment>[],
    };
    for (final video in videos) {
      final cameraKey = _cameraKey(video.cameraId);
      videosByCamera.putIfAbsent(cameraKey, () => []).add(video);
    }
    final cameraIds = videosByCamera.keys.toList()
      ..sort((a, b) {
        final aNumber = int.tryParse(
          RegExp(r'\d+').firstMatch(a)?.group(0) ?? '',
        );
        final bNumber = int.tryParse(
          RegExp(r'\d+').firstMatch(b)?.group(0) ?? '',
        );
        if (aNumber != null && bNumber != null) {
          return aNumber.compareTo(bNumber);
        }
        return a.compareTo(b);
      });

    return DefaultTabController(
      length: cameraIds.length,
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFFE3E8EF)),
        ),
        child: Column(
          children: [
            Material(
              color: const Color(0xFFF4F7FB),
              child: TabBar(
                isScrollable: cameraIds.length > 3,
                tabs: cameraIds
                    .map(
                      (cameraId) => Tab(
                        text: _cameraLabel(cameraId),
                        icon: const Icon(Icons.videocam_rounded, size: 18),
                      ),
                    )
                    .toList(),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: cameraIds
                    .map(
                      (cameraId) =>
                          _buildCameraList(cameraId, videosByCamera[cameraId]!),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _cameraLabel(String cameraId) {
    final number = RegExp(r'\d+').firstMatch(cameraId)?.group(0);
    return number == null ? cameraId.toUpperCase() : 'CAM $number';
  }

  String _cameraKey(String cameraId) {
    final number = RegExp(r'\d+').firstMatch(cameraId)?.group(0);
    return number == null ? cameraId.toUpperCase() : 'CAM${int.parse(number)}';
  }

  Widget _buildCameraList(String cameraId, List<RecordedSegment> cameraVideos) {
    final isActivelyRecording =
        _cameraKey(activeCameraId) == cameraId &&
        activeRecordingPath != null &&
        activeRecordingStartedAt != null;
    if (cameraVideos.isEmpty && !isActivelyRecording) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off_rounded, size: 44, color: Colors.black26),
            SizedBox(height: 10),
            Text(
              'Camera này chưa có video',
              style: TextStyle(
                color: Colors.black45,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: cameraVideos.length + (isActivelyRecording ? 1 : 0),
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 70, endIndent: 16),
      itemBuilder: (context, index) {
        if (isActivelyRecording && index == cameraVideos.length) {
          return _ActiveRecordingTile(
            startedAt: activeRecordingStartedAt!,
            formatTime: formatTime,
          );
        }
        final video = cameraVideos[index];
        final isClip = video.type == 'CLIP';
        final accent = isClip
            ? const Color(0xFF7B1FA2)
            : const Color(0xFF1565C0);
        return FutureBuilder<int>(
          future: File(video.path).length(),
          builder: (context, snapshot) => ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            leading: CircleAvatar(
              backgroundColor: accent.withValues(alpha: 0.12),
              child: Icon(
                isClip ? Icons.content_cut_rounded : Icons.videocam_rounded,
                color: accent,
                size: 20,
              ),
            ),
            title: Text(
              video.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      '${formatTime(video.startedAt)} · '
                      '${formatSize(snapshot.data ?? 0)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      video.type,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        color: accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            trailing: IconButton(
              tooltip: 'Xem video',
              onPressed: () => onView(video),
              icon: const Icon(
                Icons.visibility_rounded,
                color: Color(0xFF1565C0),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActiveRecordingTile extends StatefulWidget {
  final DateTime startedAt;
  final String Function(DateTime) formatTime;

  const _ActiveRecordingTile({
    required this.startedAt,
    required this.formatTime,
  });

  @override
  State<_ActiveRecordingTile> createState() => _ActiveRecordingTileState();
}

class _ActiveRecordingTileState extends State<_ActiveRecordingTile> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _elapsed() {
    final duration = DateTime.now().difference(widget.startedAt);
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    String two(int value) => value.toString().padLeft(2, '0');
    final fileName =
        '${two(widget.startedAt.hour)}-'
        '${two(widget.startedAt.minute)}-'
        '${two(widget.startedAt.second)}.ts';
    return ListTile(
      tileColor: const Color(0xFFFFEBEE),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: const CircleAvatar(
        backgroundColor: Color(0xFFFFCDD2),
        child: Icon(Icons.fiber_manual_record_rounded, color: Colors.red),
      ),
      title: Text(
        fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        '${widget.formatTime(widget.startedAt)} · ${_elapsed()}',
        style: const TextStyle(color: Colors.black54, fontSize: 12),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'ĐANG GHI',
          style: TextStyle(
            color: Colors.red,
            fontSize: 10,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _VideoPlayerScreen extends StatefulWidget {
  final RecordedSegment video;

  const _VideoPlayerScreen({required this.video});

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen> {
  late final VideoPlayerController _controller;
  late final Future<void> _initialization;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.video.path));
    _initialization = _controller.initialize().then((_) async {
      await _controller.play();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayback() {
    if (!_controller.value.isInitialized) return;
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.video.fileName, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<void>(
        future: _initialization,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Không thể phát video: ${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final aspectRatio = _controller.value.aspectRatio > 0
              ? _controller.value.aspectRatio
              : 16 / 9;
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: GestureDetector(
                    onTap: _togglePlayback,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AspectRatio(
                          aspectRatio: aspectRatio,
                          child: VideoPlayer(_controller),
                        ),
                        if (!_controller.value.isPlaying)
                          const Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white70,
                            size: 72,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: VideoProgressIndicator(
                  _controller,
                  allowScrubbing: true,
                  padding: const EdgeInsets.all(16),
                  colors: const VideoProgressColors(
                    playedColor: Color(0xFF42A5F5),
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
