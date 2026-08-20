import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  static const _platform = MethodChannel('vnvar/camera_station_service');
  bool _loading = true;
  int _totalBytes = 0;
  List<RecordedSegment> _videos = const [];
  int _segmentMinutes = 3;
  String _storagePath = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    final videos = widget.recordingService.segments;
    var bytes = 0;
    for (final video in videos) {
      final file = File(video.path);
      if (await file.exists()) bytes += await file.length();
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
  }

  Future<void> _chooseStorage() async {
    try {
      final path = await _platform.invokeMethod<String>('selectVideoFolder');
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

  Future<void> _deleteVideo(RecordedSegment video) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa video?'),
        content: Text('File ${video.fileName} sẽ bị xóa khỏi điện thoại.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('HỦY'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('XÓA'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await widget.recordingService.deleteSegment(video.id);
    await _refresh();
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
                onChooseStorage: _chooseStorage,
              );
              final savedVideos = VideoList(
                loading: _loading,
                videos: _videos,
                formatSize: _size,
                formatTime: _time,
                onDelete: _deleteVideo,
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
  final VoidCallback onChooseStorage;

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

              const SizedBox(height: 10),
              const Text(
                'Giới hạn 20 GB · Tự xóa video ngày cũ nhất khi đầy',
                style: TextStyle(fontSize: 12, color: Colors.black54),
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
                value: '$apiBase/videos/process/trim',
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
  final String Function(int) formatSize;
  final String Function(DateTime) formatTime;
  final ValueChanged<RecordedSegment> onDelete;

  const VideoList({
    super.key,
    required this.loading,
    required this.videos,
    required this.formatSize,
    required this.formatTime,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_library_outlined, size: 48, color: Colors.black26),
            const SizedBox(height: 12),
            const Text(
              'Chưa có video đã lưu',
              style: TextStyle(
                color: Colors.black45,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE3E8EF)),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: videos.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, indent: 70, endIndent: 16),
        itemBuilder: (context, index) {
          final video = videos[index];
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
                tooltip: 'Xóa video',
                onPressed: () => onDelete(video),
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
