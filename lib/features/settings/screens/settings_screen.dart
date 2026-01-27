import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/services/music_folder_service.dart';
import 'package:flick/services/library_scanner_service.dart';
import 'package:flick/services/permission_service.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/widgets/common/glass_dialog.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';
import 'package:flick/features/settings/screens/equalizer_screen.dart';

/// Settings screen matching the design language.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Sample settings state
  bool _gaplessPlayback = true;
  bool _showAlbumArt = true;

  // Library state
  final MusicFolderService _folderService = MusicFolderService();
  final LibraryScannerService _scannerService = LibraryScannerService();
  final SongRepository _songRepository = SongRepository();
  List<MusicFolder> _folders = [];
  int _songCount = 0;
  bool _isScanning = false;
  ScanProgress? _scanProgress;

  // ValueNotifier for bottom sheet progress updates
  final ValueNotifier<ScanProgress?> _scanProgressNotifier = ValueNotifier(
    null,
  );

  @override
  void initState() {
    super.initState();
    _loadLibraryData();
  }

  @override
  void dispose() {
    _scanProgressNotifier.dispose();
    super.dispose();
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
      // Check if we need to request storage permission
      // Only prompt if there are no existing folders (first-time setup)
      final permissionService = PermissionService();
      final hasPermission = await permissionService.hasStoragePermission();

      if (!hasPermission && _folders.isEmpty) {
        // No permission and no folders - prompt for permission
        final granted = await permissionService.requestStoragePermission();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Storage permission is required to add music folders',
                ),
              ),
            );
          }
          return;
        }
      }

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

    // Show scanning bottom sheet
    _showScanningBottomSheet(displayName);

    await for (final progress in _scannerService.scanFolder(uri, displayName)) {
      if (mounted) {
        setState(() => _scanProgress = progress);
        _scanProgressNotifier.value = progress;
      }
    }

    await _loadLibraryData();
    if (mounted) {
      // Close the bottom sheet
      Navigator.of(context).pop();
      _scanProgressNotifier.value = null;
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

    // Show scanning bottom sheet
    _showScanningBottomSheet('All Folders');

    await for (final progress in _scannerService.scanAllFolders()) {
      if (mounted) {
        setState(() => _scanProgress = progress);
        _scanProgressNotifier.value = progress;
      }
    }

    await _loadLibraryData();
    if (mounted) {
      // Close the bottom sheet
      Navigator.of(context).pop();
      _scanProgressNotifier.value = null;
      setState(() {
        _isScanning = false;
        _scanProgress = null;
      });
    }
  }

  void _showScanningBottomSheet(String folderName) {
    GlassBottomSheet.show(
      context: context,
      title: 'Scanning Library',
      isDismissible: false,
      enableDrag: false,
      maxHeightRatio: 0.35,
      content: ValueListenableBuilder<ScanProgress?>(
        valueListenable: _scanProgressNotifier,
        builder: (context, progress, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppConstants.spacingMd),
              // Progress indicator
              Row(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: AppConstants.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          progress?.currentFolder ?? folderName,
                          style: const TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          progress?.currentFile ?? 'Initializing...',
                          style: const TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 13,
                            color: AppColors.textTertiary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppConstants.spacingLg),
              // Stats row
              Container(
                padding: const EdgeInsets.all(AppConstants.spacingMd),
                decoration: BoxDecoration(
                  color: AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildScanStat(
                      'Songs Found',
                      '${progress?.songsFound ?? 0}',
                      LucideIcons.music,
                    ),
                    Container(
                      width: 1,
                      height: 40,
                      color: AppColors.glassBorder,
                    ),
                    _buildScanStat(
                      'Total Files',
                      '${progress?.totalFiles ?? 0}',
                      LucideIcons.file,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppConstants.spacingMd),
              // Cancel button
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () {
                    _scannerService.cancelScan();
                    Navigator.of(context).pop();
                    _scanProgressNotifier.value = null;
                    setState(() {
                      _isScanning = false;
                      _scanProgress = null;
                    });
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildScanStat(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: AppColors.textSecondary, size: 20),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'ProductSans',
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'ProductSans',
            fontSize: 12,
            color: AppColors.textTertiary,
          ),
        ),
      ],
    );
  }

  void _showThemeBottomSheet() {
    GlassBottomSheet.show(
      context: context,
      title: 'Theme',
      maxHeightRatio: 0.4,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildThemeOption('Dark', 'Current theme', true),
          _buildThemeOption('Light', 'Coming soon', false),
          _buildThemeOption('System', 'Follow system settings', false),
          _buildThemeOption('AMOLED', 'Pure black background', false),
        ],
      ),
    );
  }

  Widget _buildThemeOption(String title, String subtitle, bool isSelected) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (title == 'Dark') {
            Navigator.pop(context);
          }
        },
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingMd,
            vertical: AppConstants.spacingSm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 13,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Icon(
                  LucideIcons.check,
                  color: AppColors.textPrimary,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAudioOutputBottomSheet() {
    GlassBottomSheet.show(
      context: context,
      title: 'Audio Output',
      maxHeightRatio: 0.4,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildOutputOption(
            'System Default',
            'Use system audio routing',
            LucideIcons.smartphone,
            true,
          ),
          _buildOutputOption(
            'Speaker',
            'Built-in device speaker',
            LucideIcons.volume2,
            false,
          ),
          _buildOutputOption(
            'Bluetooth',
            'Connected Bluetooth devices',
            LucideIcons.bluetooth,
            false,
          ),
          _buildOutputOption(
            'Wired',
            'Headphones or external DAC',
            LucideIcons.headphones,
            false,
          ),
        ],
      ),
    );
  }

  Widget _buildOutputOption(
    String title,
    String subtitle,
    IconData icon,
    bool isSelected,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pop(context),
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
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
                  color: isSelected
                      ? AppColors.glassBackgroundStrong
                      : AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Icon(
                  icon,
                  color: isSelected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
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
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 13,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Icon(
                  LucideIcons.check,
                  color: AppColors.textPrimary,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAboutBottomSheet() {
    GlassBottomSheet.show(
      context: context,
      title: 'About Flick Player',
      maxHeightRatio: 0.5,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppConstants.spacingMd),
          // App icon
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong,
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: const Icon(
              LucideIcons.music2,
              color: AppColors.textPrimary,
              size: 40,
            ),
          ),
          const SizedBox(height: AppConstants.spacingMd),
          const Text(
            'Flick Player',
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Version 1.0.0',
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 14,
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Container(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: const Text(
              'A premium music player with custom UAC 2.0 powered by Rust for the best audio experience.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: AppConstants.spacingMd),
          // Links
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildAboutLink('GitHub', LucideIcons.github),
              const SizedBox(width: AppConstants.spacingLg),
              _buildAboutLink('Website', LucideIcons.globe),
            ],
          ),
          const SizedBox(height: AppConstants.spacingMd),
        ],
      ),
    );
  }

  Widget _buildAboutLink(String label, IconData icon) {
    return TextButton.icon(
      onPressed: () {},
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontFamily: 'ProductSans')),
      style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          _buildHeader(context),

          const SizedBox(height: AppConstants.spacingMd),

          // Settings sections
          Expanded(
            child: RepaintBoundary(
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
                          onTap: _showThemeBottomSheet,
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
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const EqualizerScreen(),
                              ),
                            );
                          },
                        ),
                        _buildDivider(),
                        _buildNavigationSetting(
                          context,
                          icon: LucideIcons.volume2,
                          title: 'Audio Output',
                          subtitle: 'System default',
                          onTap: _showAudioOutputBottomSheet,
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
                          onTap: _showAboutBottomSheet,
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

                    // Spacing for nav bar with mini player
                    const SizedBox(height: AppConstants.navBarHeight + 120),
                  ],
                ),
              ),
            ),
          ),
        ],
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
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: context.adaptiveTextPrimary,
        ),
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
          color: context.adaptiveTextTertiary,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildLibraryCard(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
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

                // Scanning indicator (progress shown in bottom sheet)
                if (_isScanning) ...[
                  _buildScanningIndicator(context),
                  _buildDivider(),
                ],

                // Music folders list
                ..._folders.map(
                  (folder) => RepaintBoundary(
                    child: Column(
                      children: [
                        _buildFolderItem(context, folder),
                        if (_folders.last != folder) _buildDivider(),
                      ],
                    ),
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
      ),
    );
  }

  Widget _buildLibraryInfo(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Row(
        children: [
          Container(
            width: context.scaleSize(AppConstants.containerSizeSm),
            height: context.scaleSize(AppConstants.containerSizeSm),
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong,
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
            ),
            child: Icon(
              LucideIcons.music,
              color: AppColors.textSecondary,
              size: context.responsiveIcon(AppConstants.iconSizeMd),
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Library',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$_songCount songs in ${_folders.length} ${_folders.length == 1 ? 'folder' : 'folders'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
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

  Widget _buildScanningIndicator(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.adaptiveTextPrimary,
            ),
          ),
          const SizedBox(width: AppConstants.spacingSm),
          Text(
            'Scanning... ${_scanProgress?.songsFound ?? 0} songs found',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.adaptiveTextSecondary,
            ),
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
              width: context.scaleSize(AppConstants.containerSizeSm),
              height: context.scaleSize(AppConstants.containerSizeSm),
              decoration: BoxDecoration(
                color: AppColors.glassBackgroundStrong,
                borderRadius: BorderRadius.circular(AppConstants.radiusSm),
              ),
              child: Icon(
                LucideIcons.folder,
                color: context.adaptiveTextSecondary,
                size: context.responsiveIcon(AppConstants.iconSizeMd),
              ),
            ),
            const SizedBox(width: AppConstants.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.displayName,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.adaptiveTextPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                LucideIcons.trash2,
                color: context.adaptiveTextTertiary,
                size: context.responsiveIcon(AppConstants.iconSizeSm),
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
                width: context.scaleSize(AppConstants.containerSizeSm),
                height: context.scaleSize(AppConstants.containerSizeSm),
                decoration: BoxDecoration(
                  color: AppColors.glassBackgroundStrong,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Icon(
                  icon,
                  color: onTap != null
                      ? context.adaptiveTextSecondary
                      : context.adaptiveTextTertiary,
                  size: context.responsiveIcon(AppConstants.iconSizeMd),
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
                        color: onTap != null
                            ? context.adaptiveTextPrimary
                            : context.adaptiveTextTertiary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.adaptiveTextTertiary,
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
    return RepaintBoundary(
      child: ClipRRect(
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
      ),
    );
  }

  Widget _buildDivider() {
    return RepaintBoundary(
      child: Container(
        height: 1,
        margin: EdgeInsets.only(left: 56 + AppConstants.spacingMd),
        color: AppColors.glassBorder,
      ),
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
    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            child: Row(
              children: [
                // Icon
                Container(
                  width: context.scaleSize(AppConstants.containerSizeSm),
                  height: context.scaleSize(AppConstants.containerSizeSm),
                  decoration: BoxDecoration(
                    color: AppColors.glassBackgroundStrong,
                    borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                  ),
                  child: Icon(
                    icon,
                    color: context.adaptiveTextSecondary,
                    size: context.responsiveIcon(AppConstants.iconSizeMd),
                  ),
                ),

                const SizedBox(width: AppConstants.spacingMd),

                // Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: context.adaptiveTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
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

  Widget _buildNavigationSetting(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return RepaintBoundary(
      child: Material(
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
                  child: Icon(
                    icon,
                    color: context.adaptiveTextSecondary,
                    size: 20,
                  ),
                ),

                const SizedBox(width: AppConstants.spacingMd),

                // Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: context.adaptiveTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                        ),
                      ),
                    ],
                  ),
                ),

                // Chevron
                Icon(
                  LucideIcons.chevronRight,
                  color: context.adaptiveTextTertiary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
