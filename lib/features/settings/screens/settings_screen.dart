import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/services/music_folder_service.dart';
import 'package:flick/services/library_scanner_service.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/widgets/common/glass_dialog.dart';

/// Settings screen matching the design language.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Sample settings state
  bool _gaplessPlayback = true;
  bool _crossfade = false;
  bool _showAlbumArt = true;
  double _crossfadeDuration = 5.0;

  // Library state
  final MusicFolderService _folderService = MusicFolderService();
  final LibraryScannerService _scannerService = LibraryScannerService();
  final SongRepository _songRepository = SongRepository();
  List<MusicFolder> _folders = [];
  int _songCount = 0;
  bool _isScanning = false;
  ScanProgress? _scanProgress;

  @override
  void initState() {
    super.initState();
    _loadLibraryData();
  }

  Future<void> _loadLibraryData() async {
    final folders = await _folderService.getSavedFolders();
    final count = await _songRepository.getSongCount();
    if (mounted) {
      setState(() {
        _folders = folders;
        _songCount = count;
      });
    }
  }

  Future<void> _addFolder() async {
    try {
      final folder = await _folderService.addFolder();
      if (folder != null) {
        await _loadLibraryData();
        // Start scanning the new folder
        await _scanFolder(folder.uri, folder.displayName);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to add folder: $e')));
      }
    }
  }

  Future<void> _removeFolder(MusicFolder folder) async {
    try {
      await _folderService.removeFolder(folder.uri);
      await _loadLibraryData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to remove folder: $e')));
      }
    }
  }

  Future<void> _scanFolder(String uri, String displayName) async {
    setState(() {
      _isScanning = true;
      _scanProgress = null;
    });

    await for (final progress in _scannerService.scanFolder(uri, displayName)) {
      if (mounted) {
        setState(() => _scanProgress = progress);
      }
    }

    await _loadLibraryData();
    if (mounted) {
      setState(() {
        _isScanning = false;
        _scanProgress = null;
      });
    }
  }

  Future<void> _rescanAllFolders() async {
    setState(() {
      _isScanning = true;
      _scanProgress = null;
    });

    await for (final progress in _scannerService.scanAllFolders()) {
      if (mounted) {
        setState(() => _scanProgress = progress);
      }
    }

    await _loadLibraryData();
    if (mounted) {
      setState(() {
        _isScanning = false;
        _scanProgress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            _buildHeader(context),

            const SizedBox(height: AppConstants.spacingMd),

            // Settings sections
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppConstants.spacingMd,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Library section
                    _buildSectionHeader(context, 'Library'),
                    _buildLibraryCard(context),

                    const SizedBox(height: AppConstants.spacingLg),

                    // Playback section
                    _buildSectionHeader(context, 'Playback'),
                    _buildSettingsCard(
                      context,
                      children: [
                        _buildToggleSetting(
                          context,
                          icon: LucideIcons.repeat,
                          title: 'Gapless Playback',
                          subtitle: 'Seamless transition between tracks',
                          value: _gaplessPlayback,
                          onChanged: (value) {
                            setState(() => _gaplessPlayback = value);
                          },
                        ),
                        _buildDivider(),
                        _buildToggleSetting(
                          context,
                          icon: LucideIcons.shuffle,
                          title: 'Crossfade',
                          subtitle: 'Blend tracks together',
                          value: _crossfade,
                          onChanged: (value) {
                            setState(() => _crossfade = value);
                          },
                        ),
                        if (_crossfade) ...[
                          _buildDivider(),
                          _buildSliderSetting(
                            context,
                            icon: LucideIcons.timer,
                            title: 'Crossfade Duration',
                            subtitle: '${_crossfadeDuration.toInt()} seconds',
                            value: _crossfadeDuration,
                            min: 1,
                            max: 12,
                            onChanged: (value) {
                              setState(() => _crossfadeDuration = value);
                            },
                          ),
                        ],
                      ],
                    ),

                    const SizedBox(height: AppConstants.spacingLg),

                    // Display section
                    _buildSectionHeader(context, 'Display'),
                    _buildSettingsCard(
                      context,
                      children: [
                        _buildToggleSetting(
                          context,
                          icon: LucideIcons.image,
                          title: 'Show Album Art',
                          subtitle: 'Display album artwork in player',
                          value: _showAlbumArt,
                          onChanged: (value) {
                            setState(() => _showAlbumArt = value);
                          },
                        ),
                        _buildDivider(),
                        _buildNavigationSetting(
                          context,
                          icon: LucideIcons.palette,
                          title: 'Theme',
                          subtitle: 'Dark',
                          onTap: () {},
                        ),
                      ],
                    ),

                    const SizedBox(height: AppConstants.spacingLg),

                    // Audio section
                    _buildSectionHeader(context, 'Audio'),
                    _buildSettingsCard(
                      context,
                      children: [
                        _buildNavigationSetting(
                          context,
                          icon: LucideIcons.slidersHorizontal,
                          title: 'Equalizer',
                          subtitle: 'Adjust audio frequencies',
                          onTap: () {},
                        ),
                        _buildDivider(),
                        _buildNavigationSetting(
                          context,
                          icon: LucideIcons.volume2,
                          title: 'Audio Output',
                          subtitle: 'System default',
                          onTap: () {},
                        ),
                        _buildDivider(),
                        _buildNavigationSetting(
                          context,
                          icon: LucideIcons.audioWaveform,
                          title: 'Audio Quality',
                          subtitle: 'Original quality',
                          onTap: () {},
                        ),
                      ],
                    ),

                    const SizedBox(height: AppConstants.spacingLg),

                    // About section
                    _buildSectionHeader(context, 'About'),
                    _buildSettingsCard(
                      context,
                      children: [
                        _buildNavigationSetting(
                          context,
                          icon: LucideIcons.info,
                          title: 'About Flick Player',
                          subtitle: 'Version 1.0.0',
                          onTap: () {},
                        ),
                        _buildDivider(),
                        _buildNavigationSetting(
                          context,
                          icon: LucideIcons.fileText,
                          title: 'Licenses',
                          subtitle: 'Open source licenses',
                          onTap: () {},
                        ),
                      ],
                    ),

                    // Spacing for nav bar
                    const SizedBox(height: AppConstants.navBarHeight + 60),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Text(
        'Settings',
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppConstants.spacingXs,
        bottom: AppConstants.spacingSm,
      ),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: AppColors.textTertiary,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildLibraryCard(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppConstants.radiusLg),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: AppConstants.glassBlurSigmaLight,
          sigmaY: AppConstants.glassBlurSigmaLight,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.glassBackground,
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            border: Border.all(color: AppColors.glassBorder, width: 1),
          ),
          child: Column(
            children: [
              // Song count info
              _buildLibraryInfo(context),
              _buildDivider(),

              // Scanning progress (if scanning)
              if (_isScanning && _scanProgress != null) ...[
                _buildScanProgress(context),
                _buildDivider(),
              ],

              // Music folders list
              ..._folders.map(
                (folder) => Column(
                  children: [
                    _buildFolderItem(context, folder),
                    if (_folders.last != folder) _buildDivider(),
                  ],
                ),
              ),

              if (_folders.isNotEmpty) _buildDivider(),

              // Add folder button
              _buildActionButton(
                context,
                icon: LucideIcons.folderPlus,
                title: 'Add Music Folder',
                subtitle: 'Select a folder to scan',
                onTap: _isScanning ? null : _addFolder,
              ),

              if (_folders.isNotEmpty) ...[
                _buildDivider(),
                _buildActionButton(
                  context,
                  icon: LucideIcons.refreshCw,
                  title: 'Rescan Library',
                  subtitle: 'Re-index all folders',
                  onTap: _isScanning ? null : _rescanAllFolders,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryInfo(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong,
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
            ),
            child: const Icon(
              LucideIcons.music,
              color: AppColors.textSecondary,
              size: 20,
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Library', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  '$_songCount songs in ${_folders.length} ${_folders.length == 1 ? 'folder' : 'folders'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanProgress(BuildContext context) {
    final progress = _scanProgress!;
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Expanded(
                child: Text(
                  progress.currentFolder ?? 'Scanning...',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingXs),
          Text(
            'Found ${progress.songsFound} songs',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderItem(BuildContext context, MusicFolder folder) {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppConstants.spacingMd,
          vertical: AppConstants.spacingSm,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.glassBackgroundStrong,
                borderRadius: BorderRadius.circular(AppConstants.radiusSm),
              ),
              child: const Icon(
                LucideIcons.folder,
                color: AppColors.textSecondary,
                size: 20,
              ),
            ),
            const SizedBox(width: AppConstants.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.displayName,
                    style: Theme.of(context).textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(
                LucideIcons.trash2,
                color: AppColors.textTertiary,
                size: 18,
              ),
              onPressed: () => _confirmRemoveFolder(folder),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmRemoveFolder(MusicFolder folder) {
    showDialog(
      context: context,
      builder: (context) => GlassDialog(
        title: 'Remove Folder?',
        content: Text('Remove "${folder.displayName}" from your library?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _removeFolder(folder);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.glassBackgroundStrong,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Icon(
                  icon,
                  color: onTap != null
                      ? AppColors.textSecondary
                      : AppColors.textTertiary,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppConstants.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: onTap != null ? null : AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsCard(
    BuildContext context, {
    required List<Widget> children,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppConstants.radiusLg),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: AppConstants.glassBlurSigmaLight,
          sigmaY: AppConstants.glassBlurSigmaLight,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.glassBackground,
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            border: Border.all(color: AppColors.glassBorder, width: 1),
          ),
          child: Column(children: children),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 1,
      margin: const EdgeInsets.only(left: 56 + AppConstants.spacingMd),
      color: AppColors.glassBorder,
    );
  }

  Widget _buildToggleSetting(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          child: Row(
            children: [
              // Icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.glassBackgroundStrong,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Icon(icon, color: AppColors.textSecondary, size: 20),
              ),

              const SizedBox(width: AppConstants.spacingMd),

              // Text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),

              // Toggle switch
              _buildCustomSwitch(value, onChanged),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCustomSwitch(bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: AppConstants.animationFast,
        width: 48,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: value
              ? AppColors.textPrimary.withValues(alpha: 0.9)
              : AppColors.glassBackgroundStrong,
          border: Border.all(
            color: value ? Colors.transparent : AppColors.glassBorderStrong,
            width: 1,
          ),
        ),
        child: AnimatedAlign(
          duration: AppConstants.animationFast,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? AppColors.background : AppColors.textTertiary,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSliderSetting(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Column(
        children: [
          Row(
            children: [
              // Icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.glassBackgroundStrong,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Icon(icon, color: AppColors.textSecondary, size: 20),
              ),

              const SizedBox(width: AppConstants.spacingMd),

              // Text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: AppConstants.spacingSm),

          // Slider
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: AppColors.textPrimary,
              inactiveTrackColor: AppColors.glassBackgroundStrong,
              thumbColor: AppColors.textPrimary,
              overlayColor: AppColors.textPrimary.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationSetting(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          child: Row(
            children: [
              // Icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.glassBackgroundStrong,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Icon(icon, color: AppColors.textSecondary, size: 20),
              ),

              const SizedBox(width: AppConstants.spacingMd),

              // Text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),

              // Chevron
              const Icon(
                LucideIcons.chevronRight,
                color: AppColors.textTertiary,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
