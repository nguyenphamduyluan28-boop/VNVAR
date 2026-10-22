import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/recording_service.dart';
import '../services/app_language_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_notice.dart';
import '../widgets/brand_widgets.dart';

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
      showAppNotice(
        context,
        vi: 'Không tải lại được danh sách: '
            '${localizedUserFacingError(failure, english: false)}',
        en: 'Unable to refresh list: '
            '${localizedUserFacingError(failure, english: true)}',
        kind: NoticeKind.error,
      );
    }
  }

  Future<void> _delete(RecordedSegment video) async {
    final accepted = await showAppConfirm(
      context,
      titleVi: 'Xoá video?',
      titleEn: 'Delete video?',
      messageVi: '${video.fileName} sẽ bị xoá khỏi máy.',
      messageEn: '${video.fileName} will be deleted from this device.',
      confirmVi: 'Xoá',
      confirmEn: 'Delete',
      icon: Icons.delete_outline_rounded,
      destructive: true,
    );
    if (!accepted) return;
    final deleted = await widget.recordingService.deleteSegment(video.id);
    if (!mounted) return;
    if (!deleted) {
      showAppNotice(
        context,
        vi: 'Không xoá được ${video.fileName} (đang dùng/bị khoá)',
        en: 'Could not delete ${video.fileName} (in use/locked)',
        kind: NoticeKind.error,
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
    const limit = RecordingService.storageLimitBytes;
    final ratio = (_totalBytes / limit).clamp(0.0, 1.0);
    final Color barColor;
    if (ratio >= 0.9) {
      barColor = BrandColors.danger;
    } else if (ratio >= 0.8) {
      barColor = BrandColors.warning;
    } else {
      barColor = BrandColors.primaryBright;
    }
    final limitGb = (limit / (1024 * 1024 * 1024)).round();
    final header = Container(
      padding: const EdgeInsets.all(BrandSpace.lg),
      decoration: BoxDecoration(
        color: BrandColors.surface,
        borderRadius: BorderRadius.circular(BrandRadius.large),
        border: Border.all(color: BrandColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.sd_storage_rounded,
                size: 16,
                color: BrandColors.textSecondary,
              ),
              const SizedBox(width: BrandSpace.sm),
              Expanded(
                child: Text(
                  appText(context, 'DUNG LƯỢNG', 'STORAGE'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BrandText.label,
                ),
              ),
              Text(
                '${(ratio * 100).round()}%',
                style: BrandText.label.copyWith(color: barColor),
              ),
            ],
          ),
          const SizedBox(height: BrandSpace.md),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: _size(_totalBytes)),
                TextSpan(
                  text: '  /  $limitGb GB',
                  style: const TextStyle(
                    color: BrandColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: BrandColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: BrandSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              color: barColor,
              backgroundColor: BrandColors.surfaceRaised,
            ),
          ),
          const SizedBox(height: BrandSpace.lg),
          Wrap(
            spacing: BrandSpace.sm,
            runSpacing: BrandSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              BrandPill(
                icon: Icons.video_library_rounded,
                text: appText(
                  context,
                  '${_videos.length} video',
                  '${_videos.length} videos',
                ),
              ),
              Tooltip(
                message: appText(
                  context,
                  'Chỉ giữ video hôm nay; đầy $limitGb GB sẽ xoá cũ nhất.',
                  'Today only; oldest removed at $limitGb GB.',
                ),
                child: BrandPill(
                  icon: Icons.auto_delete_rounded,
                  color: BrandColors.textSecondary,
                  text: appText(context, 'Tự dọn', 'Auto-clean'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(appText(context, 'Video đã lưu', 'Saved videos')),
        actions: [
          const AppLanguageButton(),
          IconButton(
            tooltip: appText(context, 'Làm mới', 'Refresh'),
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: BrandSpace.xs),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = math.max(
              BrandSpace.lg,
              (constraints.maxWidth - _maxContentWidth) / 2,
            );
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, BrandSpace.lg, side, 0),
                  sliver: SliverToBoxAdapter(child: header),
                ),
                ..._buildList(context, side),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildList(BuildContext context, double side) {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.all(BrandSpace.xl),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (_videos.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: BrandEmptyState(
            icon: Icons.video_library_outlined,
            message: appText(context, 'Chưa có video', 'No videos yet'),
          ),
        ),
      ];
    }
    // Danh sách phẳng: tiêu đề ngày (DateTime) xen giữa các video.
    final entries = <Object>[];
    DateTime? currentDay;
    for (final video in _videos) {
      final started = video.startedAt;
      final day = DateTime(started.year, started.month, started.day);
      if (day != currentDay) {
        currentDay = day;
        entries.add(day);
      }
      entries.add(video);
    }
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(side, BrandSpace.sm, side, BrandSpace.xl),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final entry = entries[index];
            if (entry is DateTime) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  BrandSpace.xs,
                  BrandSpace.lg,
                  BrandSpace.xs,
                  BrandSpace.sm,
                ),
                child: Text(
                  _dayLabel(context, entry).toUpperCase(),
                  style: BrandText.label,
                ),
              );
            }
            final video = entry as RecordedSegment;
            return Padding(
              padding: const EdgeInsets.only(bottom: BrandSpace.sm),
              child: _SavedVideoCard(
                key: ValueKey(video.path),
                video: video,
                formatSize: _size,
                formatTime: _time,
                onDelete: () => _delete(video),
              ),
            );
          }, childCount: entries.length),
        ),
      ),
    ];
  }
}

const double _maxContentWidth = 840;

String _two(int value) => value.toString().padLeft(2, '0');

String _dayLabel(BuildContext context, DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return appText(context, 'Hôm nay', 'Today');
  if (difference == 1) return appText(context, 'Hôm qua', 'Yesterday');
  return '${_two(day.day)}/${_two(day.month)}/${day.year}';
}

/// Thẻ một video đã lưu: thumbnail bo góc, tên, "giờ · thời lượng · dung
/// lượng", badge CLIP và nút xoá.
class _SavedVideoCard extends StatefulWidget {
  const _SavedVideoCard({
    super.key,
    required this.video,
    required this.formatSize,
    required this.formatTime,
    required this.onDelete,
  });

  final RecordedSegment video;
  final String Function(int) formatSize;
  final String Function(DateTime) formatTime;
  final VoidCallback onDelete;

  @override
  State<_SavedVideoCard> createState() => _SavedVideoCardState();
}

class _SavedVideoCardState extends State<_SavedVideoCard> {
  late Future<int> _sizeFuture;

  @override
  void initState() {
    super.initState();
    _sizeFuture = File(widget.video.path).length();
  }

  @override
  void didUpdateWidget(covariant _SavedVideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.path != widget.video.path) {
      _sizeFuture = File(widget.video.path).length();
    }
  }

  String _durationLabel(Duration value) {
    final hours = value.inHours;
    final minutes = _two(value.inMinutes % 60);
    final seconds = _two(value.inSeconds % 60);
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final isClip = video.type == 'CLIP';
    final accent = isClip ? BrandColors.warningSoft : BrandColors.primarySoft;
    final started = video.startedAt;
    final duration = video.duration;
    return Material(
      color: BrandColors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.medium),
        side: const BorderSide(color: BrandColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BrandSpace.sm + 2,
          BrandSpace.sm + 2,
          BrandSpace.xs,
          BrandSpace.sm + 2,
        ),
        child: Row(
          children: [
            Tooltip(
              message: widget.formatTime(started),
              child: Container(
                width: 64,
                height: 48,
                decoration: BoxDecoration(
                  color: BrandColors.surfaceRaised,
                  borderRadius: BorderRadius.circular(BrandRadius.small),
                  border: Border.all(color: BrandColors.border),
                ),
                child: Icon(
                  isClip ? Icons.content_cut_rounded : Icons.play_arrow_rounded,
                  color: accent,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: BrandSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          video.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BrandText.body.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (isClip) ...[
                        const SizedBox(width: BrandSpace.sm),
                        const BrandPill(
                          text: 'CLIP',
                          color: BrandColors.warningSoft,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  FutureBuilder<int>(
                    future: _sizeFuture,
                    builder: (context, snapshot) => Text(
                      [
                        '${_two(started.hour)}:${_two(started.minute)}:'
                            '${_two(started.second)}',
                        if (duration > Duration.zero) _durationLabel(duration),
                        widget.formatSize(snapshot.data ?? 0),
                      ].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BrandText.caption,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: appText(context, 'Xoá', 'Delete'),
              onPressed: widget.onDelete,
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: BrandColors.dangerSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
