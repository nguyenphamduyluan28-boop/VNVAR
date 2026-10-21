import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/recording_service.dart';
import '../services/app_language_service.dart';
import '../services/camera_server.dart';
import '../theme/app_theme.dart';
import '../widgets/app_notice.dart';
import '../widgets/brand_widgets.dart';

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
  _StoragePane _pane = _StoragePane.videos;

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
    } catch (error) {
      // Không để màn hình quay vòng mãi: hiện danh sách đang có và báo lỗi.
      if (mounted) {
        setState(() {
          _videos = widget.recordingService.segments;
          _loading = false;
        });
        showAppNotice(
          context,
          vi: 'Không tải lại được danh sách: ${localizedUserFacingError(error, english: false)}',
          en: 'Unable to refresh list: ${localizedUserFacingError(error, english: true)}',
          kind: NoticeKind.error,
        );
      }
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
      final folderName = _selectedFolderName(path);
      final accepted = await showAppConfirm(
        context,
        titleVi: 'Dùng thư mục này?',
        titleEn: 'Use this folder?',
        messageVi: '$folderName\nVideo .ts tự xếp theo ngày',
        messageEn: '$folderName\n.ts videos sorted by date',
        confirmVi: 'Sử dụng',
        confirmEn: 'Use',
        cancelVi: 'Chọn lại',
        cancelEn: 'Choose again',
        icon: Icons.folder_rounded,
      );
      if (!accepted) return;
      await widget.recordingService.setStoragePath(path);
      // Giữ clip export tablet đang dùng (chúng vẫn nằm ở thư mục cũ).
      await widget.recordingService.cleanupOldTempFiles(
        includeExportDownloads: false,
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      showAppNotice(
        context,
        vi: 'Không dùng được thư mục: ${localizedUserFacingError(error, english: false)}',
        en: 'Cannot use this folder: ${localizedUserFacingError(error, english: true)}',
        kind: NoticeKind.error,
      );
    }
  }

  Future<void> _changeSegmentMinutes(int? minutes) async {
    if (minutes == null || minutes == _segmentMinutes) return;
    await widget.recordingService.setSegmentMinutes(minutes);
    if (!mounted) return;
    setState(() => _segmentMinutes = minutes);
    showAppNotice(
      context,
      vi: 'Áp dụng từ đoạn kế tiếp',
      en: 'Applies from the next segment',
      kind: NoticeKind.success,
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

  String _selectedFolderName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized
        .split('/')
        .where((part) => part.trim().isNotEmpty)
        .toList();
    return parts.isEmpty
        ? appText(context, 'Bộ nhớ thiết bị', 'Device storage')
        : parts.last;
  }

  Future<void> _viewVideo(RecordedSegment video) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _VideoPlayerScreen(
          video: video,
          recordingService: widget.recordingService,
        ),
      ),
    );
  }

  String _time(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}  '
        '${two(value.day)}/${two(value.month)}/${value.year}';
  }

  @override
  Widget build(BuildContext context) {
    final viewerUri = Uri.tryParse(widget.viewerAddress);
    final host = viewerUri?.host ?? '';
    final port = viewerUri?.hasPort == true
        ? viewerUri!.port
        : CameraServer.defaultApiPort;
    final apiBase = host.isEmpty
        ? appText(context, 'Chưa có kết nối LAN', 'No LAN connection')
        : 'http://$host:$port';
    final service = widget.recordingService;
    final isRecording =
        service.currentPath != null && service.currentSegmentStartedAt != null;
    final capacity = _CapacityCard(
      usedBytes: _totalBytes,
      formatSize: _size,
      stats: [
        BrandPill(
          icon: Icons.video_library_rounded,
          text: appText(
            context,
            '${_videos.length} video',
            '${_videos.length} videos',
          ),
        ),
        if (isRecording)
          BrandPill(
            dot: true,
            color: BrandColors.live,
            text: appText(context, 'Đang ghi', 'Recording'),
          )
        else
          BrandPill(
            icon: Icons.stop_circle_outlined,
            color: BrandColors.textSecondary,
            text: appText(context, 'Không ghi', 'Idle'),
          ),
        BrandPill(
          icon: Icons.timer_rounded,
          color: BrandColors.textSecondary,
          text: appText(
            context,
            '$_segmentMinutes phút',
            '$_segmentMinutes min',
          ),
        ),
      ],
    );
    final settings = _StorageSettings(
      apiBase: apiBase,
      hasLan: host.isNotEmpty,
      segmentMinutes: _segmentMinutes,
      storagePath: _storagePath,
      onSegmentChanged: _changeSegmentMinutes,
      onChooseStorage: service.supportsStorageFolderSelection
          ? _chooseStorage
          : null,
    );
    VideoList videoList({Widget? header}) => VideoList(
      loading: _loading,
      videos: _videos,
      activeCameraId: service.cameraId,
      activeRecordingPath: service.currentPath,
      activeRecordingStartedAt: service.currentSegmentStartedAt,
      formatSize: _size,
      formatTime: _time,
      onView: _viewVideo,
      header: header,
    );
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(appText(context, 'Kho video', 'Video storage')),
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
            // Máy tính bảng / màn rộng: cột trái dung lượng + cài đặt, cột
            // phải danh sách video.
            if (constraints.maxWidth >= 900) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1240),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 360,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            BrandSpace.lg,
                            BrandSpace.lg,
                            0,
                            BrandSpace.xl,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              capacity,
                              const SizedBox(height: BrandSpace.xl),
                              settings,
                            ],
                          ),
                        ),
                      ),
                      Expanded(child: videoList()),
                    ],
                  ),
                ),
              );
            }
            final header = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                capacity,
                const SizedBox(height: BrandSpace.lg),
                Center(
                  child: BrandSegmented<_StoragePane>(
                    values: _StoragePane.values,
                    selected: _pane,
                    labelOf: (pane) => switch (pane) {
                      _StoragePane.videos => appText(context, 'Video', 'Videos'),
                      _StoragePane.settings => appText(
                        context,
                        'Cài đặt',
                        'Settings',
                      ),
                    },
                    onChanged: (pane) => setState(() => _pane = pane),
                  ),
                ),
              ],
            );
            if (_pane == _StoragePane.videos) {
              return videoList(header: header);
            }
            final side = _sideGutter(constraints.maxWidth);
            return ListView(
              padding: EdgeInsets.fromLTRB(
                side,
                BrandSpace.lg,
                side,
                BrandSpace.xl,
              ),
              children: [
                header,
                const SizedBox(height: BrandSpace.xl),
                settings,
              ],
            );
          },
        ),
      ),
    );
  }
}

enum _StoragePane { videos, settings }

/// Lề hai bên để nội dung rộng tối đa [_maxContentWidth] và nằm giữa màn.
const double _maxContentWidth = 840;

double _sideGutter(double width) =>
    math.max(BrandSpace.lg, (width - _maxContentWidth) / 2);

String _two(int value) => value.toString().padLeft(2, '0');

/// Giờ trong ngày (HH:mm:ss) cho dòng phụ của thẻ video.
String _clockOf(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';

/// Thời lượng gọn: mm:ss hoặc h:mm:ss.
String _durationLabel(Duration value) {
  final duration = value.isNegative ? Duration.zero : value;
  final hours = duration.inHours;
  final minutes = _two(duration.inMinutes % 60);
  final seconds = _two(duration.inSeconds % 60);
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

/// Tiêu đề nhóm ngày: Hôm nay / Hôm qua / dd/MM/yyyy.
String _dayLabel(BuildContext context, DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return appText(context, 'Hôm nay', 'Today');
  if (difference == 1) return appText(context, 'Hôm qua', 'Yesterday');
  return '${_two(day.day)}/${_two(day.month)}/${day.year}';
}

DateTime _dayOf(DateTime value) => DateTime(value.year, value.month, value.day);

// ============================================================
// CAPACITY CARD
// ============================================================

class _CapacityCard extends StatelessWidget {
  const _CapacityCard({
    required this.usedBytes,
    required this.formatSize,
    this.stats = const [],
  });

  final int usedBytes;
  final String Function(int) formatSize;
  final List<Widget> stats;

  @override
  Widget build(BuildContext context) {
    const limit = RecordingService.storageLimitBytes;
    final ratio = (usedBytes / limit).clamp(0.0, 1.0);
    final Color barColor;
    if (ratio >= 0.9) {
      barColor = BrandColors.danger;
    } else if (ratio >= 0.8) {
      barColor = BrandColors.warning;
    } else {
      barColor = BrandColors.primaryBright;
    }
    final limitGb = (limit / (1024 * 1024 * 1024)).round();
    return Container(
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
                TextSpan(text: formatSize(usedBytes)),
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
          if (stats.isNotEmpty) ...[
            const SizedBox(height: BrandSpace.lg),
            Wrap(
              spacing: BrandSpace.sm,
              runSpacing: BrandSpace.sm,
              children: stats,
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// STORAGE SETTINGS
// ============================================================

class _StorageSettings extends StatelessWidget {
  final String apiBase;
  final bool hasLan;
  final int segmentMinutes;
  final String storagePath;
  final ValueChanged<int?> onSegmentChanged;
  final VoidCallback? onChooseStorage;

  const _StorageSettings({
    required this.apiBase,
    required this.hasLan,
    required this.segmentMinutes,
    required this.storagePath,
    required this.onSegmentChanged,
    required this.onChooseStorage,
  });

  static const _segmentOptions = [1, 2, 3, 5, 10, 15, 30];

  String _folderName(BuildContext context) {
    if (storagePath.trim().isEmpty) {
      return appText(context, 'Chưa chọn nơi lưu', 'No folder selected');
    }
    final parts = storagePath
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.trim().isNotEmpty)
        .toList();
    return parts.isEmpty
        ? appText(context, 'Bộ nhớ thiết bị', 'Device storage')
        : parts.last;
  }

  Widget _urlTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String path,
  }) {
    final url = hasLan ? '$apiBase$path' : apiBase;
    return BrandTile(
      icon: icon,
      title: title,
      subtitle: url,
      iconColor: hasLan ? BrandColors.primaryBright : BrandColors.textDisabled,
      trailing: hasLan
          ? IconButton(
              tooltip: appText(context, 'Sao chép', 'Copy'),
              icon: const Icon(
                Icons.copy_rounded,
                size: 20,
                color: BrandColors.textSecondary,
              ),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (!context.mounted) return;
                showAppNotice(
                  context,
                  vi: 'Đã sao chép',
                  en: 'Copied',
                  kind: NoticeKind.success,
                );
              },
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final choose = onChooseStorage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandSection(
          title: appText(context, 'Lưu trữ', 'Storage'),
          children: [
            BrandTile(
              icon: Icons.folder_rounded,
              title: _folderName(context),
              subtitle: storagePath.isEmpty
                  ? appText(context, 'Chọn thư mục lưu video', 'Pick a folder')
                  : appText(context, 'Theo ngày · AUTOMODE', 'By date · AUTOMODE'),
              onTap: choose,
              trailing: choose == null
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          storagePath.isEmpty
                              ? appText(context, 'Chọn', 'Choose')
                              : appText(context, 'Đổi', 'Change'),
                          style: BrandText.body.copyWith(
                            color: BrandColors.primarySoft,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: BrandColors.textDisabled,
                        ),
                      ],
                    ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                BrandTile(
                  icon: Icons.timer_rounded,
                  title: appText(context, 'Độ dài đoạn', 'Segment length'),
                  subtitle: appText(context, 'Phút', 'Minutes'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    BrandSpace.lg,
                    0,
                    BrandSpace.lg,
                    BrandSpace.md,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: BrandSegmented<int>(
                      values: _segmentOptions,
                      selected: segmentMinutes,
                      labelOf: (minutes) => '$minutes',
                      onChanged: (minutes) => onSegmentChanged(minutes),
                      dense: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: BrandSpace.xl),
        BrandSection(
          title: appText(context, 'Kết nối mạng', 'Network'),
          children: [
            _urlTile(
              context,
              icon: Icons.lan_rounded,
              title: appText(context, 'Danh sách qua IP', 'List via IP'),
              path: '/segments',
            ),
            _urlTile(
              context,
              icon: Icons.content_cut_rounded,
              title: appText(context, 'API cắt video', 'Clip API'),
              path: '/trim',
            ),
          ],
        ),
      ],
    );
  }
}

// ============================================================
// VIDEO LIST
// ============================================================

class VideoList extends StatefulWidget {
  final bool loading;
  final List<RecordedSegment> videos;
  final String activeCameraId;
  final String? activeRecordingPath;
  final DateTime? activeRecordingStartedAt;
  final String Function(int) formatSize;
  final String Function(DateTime) formatTime;
  final ValueChanged<RecordedSegment> onView;

  /// Khối đầu trang cuộn cùng danh sách (thẻ dung lượng, bộ chọn tab).
  final Widget? header;

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
    this.header,
  });

  @override
  State<VideoList> createState() => _VideoListState();
}

/// Một dòng trong danh sách phẳng: tiêu đề ngày, đoạn đang ghi hoặc video.
class _ListEntry {
  const _ListEntry.day(this.day) : video = null, active = false;
  const _ListEntry.active() : day = null, video = null, active = true;
  const _ListEntry.video(this.video) : day = null, active = false;

  final DateTime? day;
  final RecordedSegment? video;
  final bool active;
}

class _VideoListState extends State<VideoList> {
  String? _camera;

  String _cameraLabel(String cameraId) {
    final number = RegExp(r'\d+').firstMatch(cameraId)?.group(0);
    return number == null ? cameraId.toUpperCase() : 'CAM $number';
  }

  String _cameraKey(String cameraId) {
    final number = RegExp(r'\d+').firstMatch(cameraId)?.group(0);
    return number == null ? cameraId.toUpperCase() : 'CAM${int.parse(number)}';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = _sideGutter(constraints.maxWidth);
        final header = widget.header;
        return CustomScrollView(
          slivers: [
            if (header != null)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(side, BrandSpace.lg, side, 0),
                sliver: SliverToBoxAdapter(child: header),
              ),
            if (widget.loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.all(BrandSpace.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else
              ..._buildContent(context, side),
          ],
        );
      },
    );
  }

  List<Widget> _buildContent(BuildContext context, double side) {
    final videosByCamera = <String, List<RecordedSegment>>{
      'CAM1': <RecordedSegment>[],
      'CAM2': <RecordedSegment>[],
      'CAM3': <RecordedSegment>[],
    };
    for (final video in widget.videos) {
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
    final activeKey = _cameraKey(widget.activeCameraId);
    final selected = cameraIds.contains(_camera)
        ? _camera!
        : (cameraIds.contains(activeKey) ? activeKey : cameraIds.first);
    final cameraVideos = videosByCamera[selected]!;
    final startedAt = widget.activeRecordingStartedAt;
    final isActivelyRecording =
        activeKey == selected &&
        widget.activeRecordingPath != null &&
        startedAt != null;

    final entries = <_ListEntry>[];
    DateTime? currentDay;
    void addDay(DateTime value) {
      final day = _dayOf(value);
      if (day != currentDay) {
        currentDay = day;
        entries.add(_ListEntry.day(day));
      }
    }

    if (isActivelyRecording) {
      addDay(startedAt);
      entries.add(const _ListEntry.active());
    }
    for (final video in cameraVideos) {
      addDay(video.startedAt);
      entries.add(_ListEntry.video(video));
    }

    final count = cameraVideos.length;
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(side, BrandSpace.lg, side, 0),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: BrandSegmented<String>(
                      values: cameraIds,
                      selected: selected,
                      labelOf: _cameraLabel,
                      onChanged: (camera) => setState(() => _camera = camera),
                      dense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: BrandSpace.sm),
              Text(
                appText(context, '$count video', '$count videos'),
                style: BrandText.caption,
              ),
            ],
          ),
        ),
      ),
      if (entries.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: BrandEmptyState(
            icon: Icons.videocam_off_rounded,
            message: appText(context, 'Chưa có video', 'No videos yet'),
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, BrandSpace.sm, side, BrandSpace.xl),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildEntry(context, entries[index]),
              childCount: entries.length,
            ),
          ),
        ),
    ];
  }

  Widget _buildEntry(BuildContext context, _ListEntry entry) {
    final day = entry.day;
    if (day != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          BrandSpace.xs,
          BrandSpace.lg,
          BrandSpace.xs,
          BrandSpace.sm,
        ),
        child: Text(
          _dayLabel(context, day).toUpperCase(),
          style: BrandText.label,
        ),
      );
    }
    if (entry.active) {
      return Padding(
        padding: const EdgeInsets.only(bottom: BrandSpace.sm),
        child: _ActiveRecordingTile(
          startedAt: widget.activeRecordingStartedAt!,
          formatTime: widget.formatTime,
        ),
      );
    }
    final video = entry.video!;
    return Padding(
      padding: const EdgeInsets.only(bottom: BrandSpace.sm),
      child: _SegmentCard(
        key: ValueKey(video.path),
        video: video,
        formatSize: widget.formatSize,
        formatTime: widget.formatTime,
        onTap: () => widget.onView(video),
        trailing: IconButton(
          tooltip: appText(context, 'Xem video', 'Play video'),
          onPressed: () => widget.onView(video),
          icon: const Icon(
            Icons.play_circle_outline_rounded,
            color: BrandColors.primarySoft,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// VIDEO CARDS
// ============================================================

/// Thẻ một video: ô thumbnail bo góc + tên + dòng phụ + badge + hành động.
class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.icon,
    required this.accent,
    required this.title,
    required this.meta,
    this.badge,
    this.trailing,
    this.onTap,
    this.tint,
    this.thumbTooltip,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String meta;
  final Widget? badge;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? tint;
  final String? thumbTooltip;

  @override
  Widget build(BuildContext context) {
    Widget thumb = Container(
      width: 64,
      height: 48,
      decoration: BoxDecoration(
        color: tint ?? BrandColors.surfaceRaised,
        borderRadius: BorderRadius.circular(BrandRadius.small),
        border: Border.all(color: BrandColors.border),
      ),
      child: Icon(icon, color: accent, size: 24),
    );
    final tip = thumbTooltip;
    if (tip != null) thumb = Tooltip(message: tip, child: thumb);
    final badgeWidget = badge;
    return Material(
      color: BrandColors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.medium),
        side: BorderSide(
          color: tint == null ? BrandColors.border : accent.withValues(alpha: 0.4),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            BrandSpace.sm + 2,
            BrandSpace.sm + 2,
            trailing == null ? BrandSpace.md : BrandSpace.xs,
            BrandSpace.sm + 2,
          ),
          child: Row(
            children: [
              thumb,
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
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BrandText.body.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (badgeWidget != null) ...[
                          const SizedBox(width: BrandSpace.sm),
                          badgeWidget,
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BrandText.caption,
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentCard extends StatefulWidget {
  const _SegmentCard({
    super.key,
    required this.video,
    required this.formatSize,
    required this.formatTime,
    this.onTap,
    this.trailing,
  });

  final RecordedSegment video;
  final String Function(int) formatSize;
  final String Function(DateTime) formatTime;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  State<_SegmentCard> createState() => _SegmentCardState();
}

class _SegmentCardState extends State<_SegmentCard> {
  late Future<int> _sizeFuture;

  @override
  void initState() {
    super.initState();
    _sizeFuture = File(widget.video.path).length();
  }

  @override
  void didUpdateWidget(covariant _SegmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.path != widget.video.path) {
      _sizeFuture = File(widget.video.path).length();
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final isClip = video.type == 'CLIP';
    final accent = isClip ? BrandColors.warningSoft : BrandColors.primarySoft;
    final duration = video.duration;
    return FutureBuilder<int>(
      future: _sizeFuture,
      builder: (context, snapshot) => _MediaCard(
        icon: isClip ? Icons.content_cut_rounded : Icons.play_arrow_rounded,
        accent: accent,
        title: video.fileName,
        thumbTooltip: widget.formatTime(video.startedAt),
        meta: [
          _clockOf(video.startedAt),
          if (duration > Duration.zero) _durationLabel(duration),
          widget.formatSize(snapshot.data ?? 0),
        ].join('  ·  '),
        badge: isClip
            ? const BrandPill(text: 'CLIP', color: BrandColors.warningSoft)
            : null,
        onTap: widget.onTap,
        trailing: widget.trailing,
      ),
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
    final fileName =
        '${_two(widget.startedAt.hour)}-'
        '${_two(widget.startedAt.minute)}-'
        '${_two(widget.startedAt.second)}.ts';
    return _MediaCard(
      icon: Icons.fiber_manual_record_rounded,
      accent: BrandColors.live,
      tint: BrandColors.live.withValues(alpha: 0.14),
      title: fileName,
      thumbTooltip: widget.formatTime(widget.startedAt),
      meta: '${_clockOf(widget.startedAt)}  ·  ${_elapsed()}',
      badge: BrandPill(
        dot: true,
        filled: true,
        color: BrandColors.live,
        text: appText(context, 'ĐANG GHI', 'REC'),
      ),
    );
  }
}

class _VideoPlayerScreen extends StatefulWidget {
  final RecordedSegment video;
  final RecordingService recordingService;

  const _VideoPlayerScreen({
    required this.video,
    required this.recordingService,
  });

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen> {
  VideoPlayerController? _controller;
  File? _temporaryPlaybackFile;
  late final Future<void> _initialization;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initialization = _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    final file = await widget.recordingService.preparePlaybackFile(
      widget.video,
    );
    if (file.path != widget.video.path) _temporaryPlaybackFile = file;
    if (_disposed) {
      await _deleteTemporaryPlaybackFile();
      return;
    }
    final controller = VideoPlayerController.file(file);
    _controller = controller;
    await controller.initialize();
    if (_disposed) {
      await controller.dispose();
      await _deleteTemporaryPlaybackFile();
      return;
    }
    await controller.play();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    // Đóng trình phát xong mới xoá file tạm (tên riêng cho từng trình phát)
    // để không xoá file đang mở.
    unawaited(() async {
      try {
        await controller?.dispose();
      } catch (_) {}
      await _deleteTemporaryPlaybackFile();
    }());
    super.dispose();
  }

  Future<void> _deleteTemporaryPlaybackFile() async {
    final temporary = _temporaryPlaybackFile;
    _temporaryPlaybackFile = null;
    if (temporary == null) return;
    try {
      if (await temporary.exists()) await temporary.delete();
    } catch (_) {}
  }

  void _togglePlayback() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
      } else {
        controller.play();
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
        scrolledUnderElevation: 0,
        title: Text(
          widget.video.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: FutureBuilder<void>(
        future: _initialization,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return BrandEmptyState(
              icon: Icons.error_outline_rounded,
              message: appText(
                context,
                'Không thể phát video: ${localizedUserFacingError(snapshot.error!, english: false)}',
                'Cannot play video: ${localizedUserFacingError(snapshot.error!, english: true)}',
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final controller = _controller!;
          return ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final aspectRatio = value.aspectRatio > 0
                  ? value.aspectRatio
                  : 16 / 9;
              final playing = value.isPlaying;
              return Column(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _togglePlayback,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Center(
                            child: AspectRatio(
                              aspectRatio: aspectRatio,
                              child: VideoPlayer(controller),
                            ),
                          ),
                          if (!playing)
                            _RoundPlayButton(
                              tooltip: appText(context, 'Phát', 'Play'),
                              onPressed: _togglePlayback,
                            ),
                        ],
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        BrandSpace.xs,
                        BrandSpace.xs,
                        BrandSpace.lg,
                        BrandSpace.sm,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: playing
                                ? appText(context, 'Tạm dừng', 'Pause')
                                : appText(context, 'Phát', 'Play'),
                            onPressed: _togglePlayback,
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            _durationLabel(value.position),
                            style: _playerTimeStyle,
                          ),
                          Expanded(
                            child: VideoProgressIndicator(
                              controller,
                              allowScrubbing: true,
                              padding: const EdgeInsets.symmetric(
                                horizontal: BrandSpace.md,
                                vertical: BrandSpace.lg,
                              ),
                              colors: const VideoProgressColors(
                                playedColor: BrandColors.primaryBright,
                                bufferedColor: Colors.white38,
                                backgroundColor: Colors.white24,
                              ),
                            ),
                          ),
                          Text(
                            _durationLabel(value.duration),
                            style: _playerTimeStyle.copyWith(
                              color: Colors.white60,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

const _playerTimeStyle = TextStyle(
  color: Colors.white,
  fontSize: 12,
  fontWeight: FontWeight.w600,
);

/// Nút phát tròn lớn giữa khung hình khi đang tạm dừng.
class _RoundPlayButton extends StatelessWidget {
  const _RoundPlayButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0x99000000),
        shape: const CircleBorder(side: BorderSide(color: Color(0x33FFFFFF))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: const SizedBox(
            width: 72,
            height: 72,
            child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 44),
          ),
        ),
      ),
    );
  }
}
