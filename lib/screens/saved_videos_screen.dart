import 'dart:io';

import 'package:flutter/material.dart';

import '../services/recording_service.dart';
import '../services/app_language_service.dart';

class SavedVideosScreen extends StatefulWidget {
  final RecordingService recordingService;

  const SavedVideosScreen({super.key, required this.recordingService});

  @override
  State<SavedVideosScreen> createState() => _SavedVideosScreenState();
}

class _SavedVideosScreenState extends State<SavedVideosScreen> {
  bool _loading = true;
  List<RecordedSegment> _videos = const [];
  int _totalBytes = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    var videos = _videos;
    var bytes = _totalBytes;
    Object? failure;
    try {
      // Station có thể đang chạy: không xoá clip export tablet đang dùng.
      await widget.recordingService.cleanupOldTempFiles(
        includeExportDownloads: false,
      );
      videos = widget.recordingService.segments;
      bytes = await widget.recordingService.storageSizeBytes();
    } catch (error) {
      // Vẫn hiện danh sách đang có thay vì quay vòng mãi.
      failure = error;
      videos = widget.recordingService.segments;
    }
    if (!mounted) return;
    setState(() {
      _videos = videos;
      _totalBytes = bytes;
      _loading = false;
    });
    if (failure != null) {
      _showMessage(
        appText(
          context,
          'Không tải lại được danh sách video: $failure',
          'Unable to refresh videos: $failure',
        ),
      );
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _delete(RecordedSegment video) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(appText(context, 'Xóa video?', 'Delete video?')),
        content: Text(
          appText(
            context,
            'File ${video.fileName} sẽ bị xóa khỏi điện thoại.',
            'File ${video.fileName} will be deleted from this phone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(appText(context, 'HỦY', 'CANCEL')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(appText(context, 'XÓA', 'DELETE')),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final deleted = await widget.recordingService.deleteSegment(video.id);
    if (!mounted) return;
    if (!deleted) {
      _showMessage(
        appText(
          context,
          'Không xoá được ${video.fileName} (file đang được tải hoặc bị khoá).',
          'Could not delete ${video.fileName} (in use or locked).',
        ),
      );
    }
    await _refresh();
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

  String _time(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}  '
        '${two(value.day)}/${two(value.month)}/${value.year}';
  }

  @override
  Widget build(BuildContext context) {
    final ratio = (_totalBytes / RecordingService.storageLimitBytes).clamp(
      0.0,
      1.0,
    );
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FB),
      appBar: AppBar(
        title: Text(
          appText(context, 'VIDEO ĐÃ LƯU', 'SAVED VIDEOS'),
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          const AppLanguageButton(),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.storage_rounded),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_videos.length} video  ·  ${_size(_totalBytes)} / 20 GB',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(value: ratio),
                      const SizedBox(height: 7),
                      const Text(
                        'Chỉ giữ dữ liệu hôm nay; khi đầy 20 GB sẽ xóa cuốn chiếu.',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_videos.isEmpty) {
      return Center(
        child: Text(
          appText(context, 'Chưa có video đã lưu', 'No saved videos'),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: _videos.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final video = _videos[index];
        return Card(
          child: FutureBuilder<int>(
            future: File(video.path).length(),
            builder: (context, snapshot) => ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.play_arrow_rounded),
              ),
              title: Text(
                video.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                '${_time(video.startedAt)}  ·  ${_size(snapshot.data ?? 0)}',
              ),
              trailing: IconButton(
                onPressed: () => _delete(video),
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
