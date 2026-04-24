import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/album_art_import_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class AlbumArtPickerBottomSheet extends StatefulWidget {
  const AlbumArtPickerBottomSheet({super.key, required this.song});

  final Song song;

  static Future<void> show(BuildContext context, Song song) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await showModalBottomSheet<_AlbumArtSheetResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => AppBottomSheetSurface(
        maxHeightRatio: 0.88,
        child: AlbumArtPickerBottomSheet(song: song),
      ),
    );

    if (!context.mounted || messenger == null || result == null) {
      return;
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(result.message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  State<AlbumArtPickerBottomSheet> createState() =>
      _AlbumArtPickerBottomSheetState();
}

class _AlbumArtPickerBottomSheetState extends State<AlbumArtPickerBottomSheet> {
  final AlbumArtImportService _service = AlbumArtImportService.instance;
  final PlayerService _playerService = PlayerService();

  List<AlbumArtCandidate> _candidates = const [];
  String? _searchError;
  int _selectedCandidateIndex = 0;
  bool _isSearching = false;
  bool _isWorking = false;
  late bool _hasCustomArtwork;

  @override
  void initState() {
    super.initState();
    _hasCustomArtwork = _service.isCustomArtworkPath(widget.song.albumArt);
    _searchOnlineCandidates();
  }

  AlbumArtCandidate? get _selectedCandidate {
    if (_selectedCandidateIndex < 0 ||
        _selectedCandidateIndex >= _candidates.length) {
      return null;
    }
    return _candidates[_selectedCandidateIndex];
  }

  Future<void> _searchOnlineCandidates() async {
    if (_isWorking) {
      return;
    }

    setState(() {
      _isSearching = true;
      _searchError = null;
    });

    try {
      final candidates = await _service.searchOnlineCandidates(widget.song);
      if (!mounted) {
        return;
      }

      setState(() {
        _candidates = candidates;
        _selectedCandidateIndex = 0;
        _searchError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _candidates = const [];
        _selectedCandidateIndex = 0;
        _searchError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  Future<void> _pickLocalImage() async {
    if (_isWorking) {
      return;
    }

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
        withData: kIsWeb,
      );
      final file = result?.files.single;
      if (file == null) {
        return;
      }

      final bytes = file.bytes ?? await _readFileBytes(file.path);
      if (bytes == null || bytes.isEmpty) {
        throw const AlbumArtImportException(
          'Could not read the selected image.',
        );
      }

      await _runMutation(
        action: () => _service.applyImageBytes(song: widget.song, bytes: bytes),
        successMessage: (result) =>
            'Updated album art for "${result.albumName}".',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showInlineMessage(error.toString());
    }
  }

  Future<void> _applySelectedCandidate() async {
    final candidate = _selectedCandidate;
    if (candidate == null || _isWorking) {
      return;
    }

    await _runMutation(
      action: () => _service.applyOnlineCandidate(
        song: widget.song,
        candidate: candidate,
      ),
      successMessage: (result) =>
          'Updated album art for "${result.albumName}".',
    );
  }

  Future<void> _removeCustomArtwork() async {
    if (_isWorking) {
      return;
    }

    await _runMutation(
      action: () => _service.removeCustomArtwork(widget.song),
      successMessage: (result) =>
          'Removed custom album art for "${result.albumName}".',
    );
  }

  Future<void> _runMutation({
    required Future<AlbumArtUpdateResult> Function() action,
    required String Function(AlbumArtUpdateResult result) successMessage,
  }) async {
    setState(() {
      _isWorking = true;
    });

    try {
      final result = await action();
      _playerService.syncAlbumArtPaths(
        filePaths: result.filePaths,
        albumArtPath: result.albumArtPath,
      );
      if (!mounted) {
        return;
      }

      Navigator.of(
        context,
      ).pop(_AlbumArtSheetResult(message: successMessage(result)));
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showInlineMessage(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isWorking = false;
        });
      }
    }
  }

  Future<Uint8List?> _readFileBytes(String? path) async {
    if (path == null || path.isEmpty) {
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      return null;
    }

    return file.readAsBytes();
  }

  void _showInlineMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    final selectedCandidate = _selectedCandidate;
    final previewPath = selectedCandidate?.previewUrl ?? widget.song.albumArt;
    final previewSourcePath = selectedCandidate == null
        ? widget.song.filePath
        : null;
    final albumName = widget.song.album?.trim();
    final albumArtist = widget.song.albumArtist?.trim();
    final effectiveAlbumArtist = (albumArtist != null && albumArtist.isNotEmpty)
        ? albumArtist
        : widget.song.artist;

    return Stack(
      children: [
        SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDragHandle(),
              const SizedBox(height: AppConstants.spacingMd),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Set Album Art',
                          style: TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: context.adaptiveTextPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          albumName != null && albumName.isNotEmpty
                              ? '$albumName • $effectiveAlbumArtist'
                              : widget.song.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 14,
                            color: context.adaptiveTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _isSearching || _isWorking
                        ? null
                        : _searchOnlineCandidates,
                    icon: const Icon(LucideIcons.refreshCw, size: 18),
                    color: context.adaptiveTextSecondary,
                    tooltip: 'Search Again',
                  ),
                ],
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Text(
                  'Applied to the whole album',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextSecondary,
                  ),
                ),
              ),
              const SizedBox(height: AppConstants.spacingLg),
              _buildPreviewCard(
                context,
                imagePath: previewPath,
                audioSourcePath: previewSourcePath,
                title: selectedCandidate == null
                    ? (_hasCustomArtwork
                          ? 'Current custom art'
                          : 'Current artwork')
                    : selectedCandidate.title,
                subtitle: selectedCandidate == null
                    ? effectiveAlbumArtist
                    : _candidateSubtitle(selectedCandidate),
              ),
              const SizedBox(height: AppConstants.spacingMd),
              Wrap(
                spacing: AppConstants.spacingSm,
                runSpacing: AppConstants.spacingSm,
                children: [
                  FilledButton.icon(
                    onPressed: _isWorking ? null : _pickLocalImage,
                    icon: const Icon(LucideIcons.folderOpen, size: 18),
                    label: const Text('Pick Image'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  if (selectedCandidate != null)
                    OutlinedButton.icon(
                      onPressed: _isWorking ? null : _applySelectedCandidate,
                      icon: const Icon(LucideIcons.check, size: 18),
                      label: const Text('Apply Selected'),
                    ),
                  if (_hasCustomArtwork)
                    OutlinedButton.icon(
                      onPressed: _isWorking ? null : _removeCustomArtwork,
                      icon: const Icon(LucideIcons.trash2, size: 18),
                      label: const Text('Remove Custom Art'),
                    ),
                ],
              ),
              const SizedBox(height: AppConstants.spacingLg),
              Row(
                children: [
                  Text(
                    'Online Results',
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: context.adaptiveTextPrimary,
                    ),
                  ),
                  if (_isSearching) ...[
                    const SizedBox(width: AppConstants.spacingSm),
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppConstants.spacingSm),
              _buildOnlineResults(context),
            ],
          ),
        ),
        if (_isWorking)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.18),
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Widget _buildOnlineResults(BuildContext context) {
    if (_isSearching && _candidates.isEmpty) {
      return _buildInfoCard(
        context,
        icon: LucideIcons.search,
        title: 'Searching online',
        subtitle:
            'Looking for cover art from MusicBrainz and Cover Art Archive.',
      );
    }

    if (_searchError != null) {
      return _buildInfoCard(
        context,
        icon: LucideIcons.wifiOff,
        title: 'Search failed',
        subtitle: _searchError!,
      );
    }

    if (_candidates.isEmpty) {
      final albumName = widget.song.album?.trim();
      return _buildInfoCard(
        context,
        icon: LucideIcons.imageOff,
        title: 'No online artwork found',
        subtitle: albumName == null || albumName.isEmpty
            ? 'This song is missing album metadata, so online matching is limited.'
            : 'Try picking a local image if the release metadata is uncommon.',
      );
    }

    return SizedBox(
      height: 176,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _candidates.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: AppConstants.spacingSm),
        itemBuilder: (context, index) {
          final candidate = _candidates[index];
          final isSelected = index == _selectedCandidateIndex;
          return GestureDetector(
            onTap: _isWorking
                ? null
                : () {
                    setState(() {
                      _selectedCandidateIndex = index;
                    });
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 132,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? AppColors.accent : AppColors.glassBorder,
                  width: isSelected ? 1.6 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 116,
                      height: 116,
                      child: CachedImageWidget(
                        imagePath: candidate.previewUrl,
                        fit: BoxFit.cover,
                        placeholder: const ColoredBox(
                          color: AppColors.surface,
                          child: Icon(
                            LucideIcons.image,
                            color: AppColors.textTertiary,
                          ),
                        ),
                        errorWidget: const ColoredBox(
                          color: AppColors.surface,
                          child: Icon(
                            LucideIcons.imageOff,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    candidate.sourceLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? AppColors.accent
                          : context.adaptiveTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    candidate.releaseDate?.isNotEmpty == true
                        ? candidate.releaseDate!
                        : candidate.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      fontSize: 11,
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPreviewCard(
    BuildContext context, {
    required String? imagePath,
    required String? audioSourcePath,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 112,
              height: 112,
              child: CachedImageWidget(
                imagePath: imagePath,
                audioSourcePath: audioSourcePath,
                fit: BoxFit.cover,
                placeholder: const ColoredBox(
                  color: AppColors.surface,
                  child: Icon(
                    LucideIcons.image,
                    color: AppColors.textTertiary,
                    size: 30,
                  ),
                ),
                errorWidget: const ColoredBox(
                  color: AppColors.surface,
                  child: Icon(
                    LucideIcons.imageOff,
                    color: AppColors.textTertiary,
                    size: 30,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 13,
                    color: context.adaptiveTextSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Imported art is saved inside the app and synced to every song in this album.',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 12,
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: context.adaptiveTextSecondary),
          ),
          const SizedBox(width: AppConstants.spacingSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 13,
                    color: context.adaptiveTextSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.glassBorderStrong,
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        ),
      ),
    );
  }

  String _candidateSubtitle(AlbumArtCandidate candidate) {
    if (candidate.releaseDate != null && candidate.releaseDate!.isNotEmpty) {
      return '${candidate.artist} • ${candidate.releaseDate}';
    }
    return candidate.artist;
  }
}

class _AlbumArtSheetResult {
  const _AlbumArtSheetResult({required this.message});

  final String message;
}
