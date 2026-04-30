import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/models/song_view_mode.dart';
import 'package:flick/services/music_folder_service.dart';
import 'package:flick/services/library_scanner_service.dart';
import 'package:flick/services/library_scan_preferences_service.dart';
import 'package:flick/services/permission_service.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/data/repositories/folder_repository.dart';
import 'package:flick/data/entities/folder_entity.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/glass_dialog.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/features/settings/screens/equalizer_screen.dart';
import 'package:flick/features/settings/screens/uac2_settings_screen.dart';
import 'package:flick/features/settings/screens/duplicate_cleaner_screen.dart';
import 'package:flick/features/settings/widgets/lastfm_settings_tile.dart';
import 'package:flick/services/android_audio_device_service.dart';

/// Settings screen matching the design language.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static final Uri _releaseNotesApiUri = Uri.parse(
    'https://api.github.com/repos/ultraelectronica/flick_player/releases/latest',
  );
  static const String _releaseNotesUrl =
      'https://github.com/ultraelectronica/flick_player/releases/latest';
  static const bool _updatesComingSoon = false;

  // Sample settings state
  bool _gaplessPlayback = true;

  // Library state
  final MusicFolderService _folderService = MusicFolderService();
  final LibraryScannerService _scannerService = LibraryScannerService();
  final SongRepository _songRepository = SongRepository();
  List<MusicFolder> _folders = [];
  int _songCount = 0;
  bool _isScanning = false;
  ScanProgress? _scanProgress;
  bool _showBatteryOptimizationNotice = false;
  bool _isXiaomiDevice = false;
  final ShorebirdUpdater _updater = ShorebirdUpdater();
  bool _isCheckingForUpdates = false;
  bool _isInstallingUpdate = false;
  bool _hasScannedForUpdates = false;
  UpdateStatus? _lastScannedUpdateStatus;
  String? _updateCheckErrorMessage;
  bool _scanSettingsExpanded = false;
  late final AnimationController _scanSettingsController;
  late final Animation<double> _scanSettingsRotation;
  late final AnimationController _donationPulseController;
  late final Animation<double> _donationPulseAnimation;

  // ValueNotifier for bottom sheet progress updates
  final ValueNotifier<ScanProgress?> _scanProgressNotifier = ValueNotifier(
    null,
  );

  @override
  void initState() {
    super.initState();
    _scanSettingsController = AnimationController(
      duration: AppConstants.animationFast,
      vsync: this,
    );
    _scanSettingsRotation = Tween<double>(begin: 0, end: 0.5).animate(
      CurvedAnimation(
        parent: _scanSettingsController,
        curve: Curves.easeInOut,
      ),
    );
    _donationPulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );
    _donationPulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _donationPulseController,
        curve: Curves.easeInOut,
      ),
    );
    _donationPulseController.repeat(reverse: true);
    _loadLibraryData();
    _syncFoldersToDatabase();
    _loadAndroidDeviceNotices();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanProgressNotifier.dispose();
    _scanSettingsController.dispose();
    _donationPulseController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadAndroidDeviceNotices();
    }
  }

  Future<void> _syncFoldersToDatabase() async {
    // Sync folders from SharedPreferences to database (migration)
    final folders = await _folderService.getSavedFolders();
    final repository = FolderRepository();

    for (final folder in folders) {
      final entity = FolderEntity()
        ..uri = folder.uri
        ..displayName = folder.displayName
        ..dateAdded = folder.dateAdded
        ..songCount = 0;
      await repository.upsertFolder(entity);
    }
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

  Future<void> _loadAndroidDeviceNotices() async {
    final permissionService = PermissionService();

    try {
      final isAndroid = Theme.of(context).platform == TargetPlatform.android;
      if (!isAndroid) {
        return;
      }

      final results = await Future.wait<dynamic>([
        AndroidAudioDeviceService.instance.refresh(),
        permissionService.isIgnoringBatteryOptimizations(),
        permissionService.isBatteryNoticeDismissed(),
      ]);
      final deviceInfo = results[0] as AndroidPlaybackDeviceInfo;
      final isIgnoringBatteryOptimizations = results[1] as bool;
      final isNoticeDismissed = results[2] as bool;

      if (!mounted) {
        return;
      }

      setState(() {
        _isXiaomiDevice = deviceInfo.isXiaomiDevice;
        _showBatteryOptimizationNotice =
            !isIgnoringBatteryOptimizations && !isNoticeDismissed;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _showBatteryOptimizationNotice = false;
      });
    }
  }

  Future<void> _requestBatteryOptimizationDisable() async {
    final permissionService = PermissionService();

    try {
      final launched = await permissionService.requestIgnoreBatteryOptimizations();
      if (!mounted) {
        return;
      }

      if (!launched) {
        _showToast('Unable to open battery optimization settings');
      }
    } catch (e) {
      if (!mounted) {
        return;
      }

      _showToast('Failed to open battery optimization settings: $e');
    }
  }

  Future<void> _dismissBatteryNotice() async {
    final permissionService = PermissionService();
    await permissionService.dismissBatteryNotice();
    if (!mounted) {
      return;
    }
    setState(() {
      _showBatteryOptimizationNotice = false;
    });
  }

  bool get _restartRequiredForUpdate {
    return _lastScannedUpdateStatus == UpdateStatus.restartRequired;
  }

  bool get _hasAvailableUpdate {
    return _lastScannedUpdateStatus == UpdateStatus.outdated;
  }

  void _showToast(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _scanForUpdates() async {
    if (_isCheckingForUpdates || _isInstallingUpdate) {
      return;
    }

    setState(() {
      _isCheckingForUpdates = true;
      _updateCheckErrorMessage = null;
    });

    try {
      final status = await _updater.checkForUpdate();
      if (!mounted) {
        return;
      }

      setState(() {
        _hasScannedForUpdates = true;
        _lastScannedUpdateStatus = status;
      });

      if (status == UpdateStatus.outdated) {
        _showToast('Update available.');
        return;
      }

      if (status == UpdateStatus.restartRequired) {
        _showToast('Update finished. Restart the app to use it.');
        return;
      }

      if (status == UpdateStatus.unavailable) {
        _showToast('Updates are unavailable in this build.');
        return;
      }

      _showToast('No new update found.');
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _hasScannedForUpdates = true;
        _lastScannedUpdateStatus = null;
        _updateCheckErrorMessage = 'Unable to reach the update service.';
      });
      _showToast('Failed to check for updates: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingForUpdates = false;
        });
      }
    }
  }

  Future<void> _installUpdate() async {
    if (_isInstallingUpdate) {
      return;
    }

    if (_restartRequiredForUpdate) {
      _showToast('Update finished. Restart the app to use it.');
      return;
    }

    if (!_hasAvailableUpdate) {
      _showToast(
        _hasScannedForUpdates
            ? 'No available update to install.'
            : 'Scan for updates first.',
      );
      return;
    }

    setState(() {
      _isInstallingUpdate = true;
    });

    try {
      _showToast('Installing update in the background. Keep using the app.');
      await _updater.update();
      if (!mounted) {
        return;
      }

      setState(() {
        _hasScannedForUpdates = true;
        _lastScannedUpdateStatus = UpdateStatus.restartRequired;
        _updateCheckErrorMessage = null;
      });
      _showToast('Update finished. Restart the app to use it.');
    } on UpdateException catch (error) {
      if (!mounted) {
        return;
      }
      _showToast('Failed to install update: ${error.message}');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showToast('Failed to install update: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isInstallingUpdate = false;
        });
      }
    }
  }

  Future<_PatchNotes> _fetchPatchNotes() async {
    final response = await http.get(
      _releaseNotesApiUri,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'FlickPlayer',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final title = (data['name'] as String?)?.trim();
    final tag = (data['tag_name'] as String?)?.trim();
    final body = (data['body'] as String?)?.trim();
    final htmlUrl = (data['html_url'] as String?)?.trim();

    return _PatchNotes(
      title: title?.isNotEmpty == true
          ? title!
          : tag?.isNotEmpty == true
          ? tag!
          : 'Latest Update',
      body: body?.isNotEmpty == true ? body! : 'No patch notes available yet.',
      url: htmlUrl?.isNotEmpty == true ? htmlUrl! : _releaseNotesUrl,
    );
  }

  void _showPatchNotesBottomSheet() {
    GlassBottomSheet.show(
      context: context,
      title: 'Patch Notes',
      maxHeightRatio: 0.7,
      content: FutureBuilder<_PatchNotes>(
        future: _fetchPatchNotes(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Padding(
              padding: const EdgeInsets.symmetric(
                vertical: AppConstants.spacingLg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: AppConstants.spacingMd),
                  const CircularProgressIndicator(color: AppColors.textPrimary),
                  const SizedBox(height: AppConstants.spacingMd),
                  Text(
                    'Loading patch notes...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.adaptiveTextSecondary,
                    ),
                  ),
                ],
              ),
            );
          }

          if (snapshot.hasError || !snapshot.hasData) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: AppConstants.spacingMd),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppConstants.spacingMd),
                  decoration: BoxDecoration(
                    color: AppColors.glassBackground,
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: Text(
                    'Unable to load patch notes right now.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.adaptiveTextSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: AppConstants.spacingMd),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => _launchUrl(_releaseNotesUrl),
                    icon: const Icon(LucideIcons.externalLink),
                    label: const Text('Open Release Notes'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: AppConstants.spacingMd),
              ],
            );
          }

          final notes = snapshot.data!;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppConstants.spacingMd),
                Text(
                  notes.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppConstants.spacingMd),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppConstants.spacingMd),
                  decoration: BoxDecoration(
                    color: AppColors.glassBackground,
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: SelectableText(
                    notes.body,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.adaptiveTextSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: AppConstants.spacingMd),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => _launchUrl(notes.url),
                    icon: const Icon(LucideIcons.externalLink),
                    label: const Text('Open Full Notes'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: AppConstants.spacingMd),
              ],
            ),
          );
        },
      ),
    );
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
    } on FolderAlreadyExistsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            duration: const Duration(seconds: 3),
          ),
        );
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

  void _openDuplicateCleaner() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const DuplicateCleanerScreen()),
    );
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

  void _showAboutBottomSheet() {
    GlassBottomSheet.show(
      context: context,
      title: 'About Flick Player',
      maxHeightRatio: 0.5,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppConstants.spacingMd),
          // App logo
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong,
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: SvgPicture.asset(
              'assets/icons/flicklogo_svg.svg',
              fit: BoxFit.contain,
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
            'Version 0.12.0-beta.2',
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
              _buildAboutLink(
                'GitHub',
                LucideIcons.squareCode,
                'https://github.com/ultraelectronica/flick_player',
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingMd),
        ],
      ),
    );
  }

  Widget _buildAboutLink(String label, IconData icon, String url) {
    return TextButton.icon(
      onPressed: () => _launchUrl(url),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontFamily: 'ProductSans')),
      style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        launched = await launchUrl(
          uri,
          mode: LaunchMode.platformDefault,
        );
      }
      if (!launched && mounted) {
        _showToast('Could not open the link');
      }
    } catch (e) {
      if (mounted) {
        _showToast('Could not open the link: $e');
      }
    }
  }

  void _showLicensesBottomSheet() {
    const licenseContent = '''
MIT License

Copyright (c) 2026 Flick Player Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
''';

    GlassBottomSheet.show(
      context: context,
      title: 'Licenses',
      maxHeightRatio: 0.7,
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppConstants.spacingMd),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppConstants.spacingMd),
              decoration: BoxDecoration(
                color: AppColors.glassBackground,
                borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: const Text(
                licenseContent,
                style: TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: AppConstants.spacingMd),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final songsViewMode = ref.watch(songsViewModeProvider);
    final navBarAlwaysVisible = ref.watch(navBarAlwaysVisibleProvider);
    final ambientBackgroundEnabled = ref.watch(
      ambientBackgroundEnabledProvider,
    );
    final libraryScanPreferences = ref.watch(libraryScanPreferencesProvider);

    return DisplayModeWrapper(
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
                      _buildLibraryCard(context, libraryScanPreferences),

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
                          _buildSelectionSetting(
                            context,
                            icon: LucideIcons.disc,
                            title: 'Song View: Orbital',
                            subtitle: 'Use the orbital songs browser',
                            selected: songsViewMode == SongViewMode.orbit,
                            onTap: () {
                              ref
                                  .read(songsViewModeProvider.notifier)
                                  .setMode(SongViewMode.orbit);
                            },
                          ),
                          _buildDivider(),
                          _buildSelectionSetting(
                            context,
                            icon: LucideIcons.list,
                            title: 'Song View: List',
                            subtitle: 'Use the list songs browser',
                            selected: songsViewMode == SongViewMode.list,
                            onTap: () {
                              ref
                                  .read(songsViewModeProvider.notifier)
                                  .setMode(SongViewMode.list);
                            },
                          ),
                          _buildDivider(),
                          _buildToggleSetting(
                            context,
                            icon: LucideIcons.panelBottom,
                            title: 'Bottom Bar Always Visible',
                            subtitle: 'Keep mini player and nav visible',
                            value: navBarAlwaysVisible,
                            onChanged: (value) {
                              ref
                                  .read(navBarAlwaysVisibleProvider.notifier)
                                  .setAlwaysVisible(value);
                            },
                          ),
                          _buildDivider(),
                          _buildToggleSetting(
                            context,
                            icon: LucideIcons.sparkles,
                            title: 'Ambient Background',
                            subtitle:
                                'Use album art as the blurred app background',
                            value: ambientBackgroundEnabled,
                            onChanged: (value) {
                              ref
                                  .read(
                                    ambientBackgroundEnabledProvider.notifier,
                                  )
                                  .setEnabled(value);
                            },
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
                            icon: LucideIcons.usb,
                            title: 'USB Audio (UAC2)',
                            subtitle: 'Configure USB DAC/AMP devices',
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const Uac2SettingsScreen(),
                                ),
                              );
                            },
                          ),
                          _buildDivider(),
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
                        ],
                      ),

                      const SizedBox(height: AppConstants.spacingLg),

                      // Integrations section
                      _buildSectionHeader(context, 'Integrations'),
                      _buildSettingsCard(
                        context,
                        children: [const LastFmSettingsTile()],
                      ),

                      const SizedBox(height: AppConstants.spacingLg),

                      _buildSectionHeader(context, 'Updates'),
                      _buildSettingsCard(
                        context,
                        children: [
                          _buildActionButton(
                            context,
                            icon: LucideIcons.scanSearch,
                            title: _updatesComingSoon
                                ? 'Scan for Updates'
                                : _isCheckingForUpdates
                                ? 'Scanning for Updates...'
                                : 'Scan for Updates',
                            subtitle: _updatesComingSoon
                                ? 'Coming soon'
                                : _isCheckingForUpdates
                                ? 'Checking for the latest update now'
                                : 'Check manually whenever you want',
                            onTap:
                                _updatesComingSoon ||
                                    _isCheckingForUpdates ||
                                    _isInstallingUpdate
                                ? null
                                : _scanForUpdates,
                          ),
                          _buildDivider(),
                          _buildUpdateStatusTile(context),
                          if (!_updatesComingSoon &&
                              (_hasAvailableUpdate ||
                                  _restartRequiredForUpdate)) ...[
                            _buildDivider(),
                            _buildNavigationSetting(
                              context,
                              icon: LucideIcons.fileText,
                              title: 'Patch Notes',
                              subtitle: 'See what is new in this update',
                              onTap: _showPatchNotesBottomSheet,
                            ),
                          ],
                          if (!_updatesComingSoon &&
                              (_hasAvailableUpdate || _isInstallingUpdate)) ...[
                            _buildDivider(),
                            _buildActionButton(
                              context,
                              icon: LucideIcons.download,
                              title: _isInstallingUpdate
                                  ? 'Installing Update...'
                                  : 'Install Update',
                              subtitle: _isInstallingUpdate
                                  ? 'Downloading in the background. Keep using the app'
                                  : 'Download now and restart the app when it finishes',
                              onTap: _isInstallingUpdate
                                  ? null
                                  : _installUpdate,
                            ),
                          ],
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
                            subtitle: 'Version 0.12.0-beta.2',
                            onTap: _showAboutBottomSheet,
                          ),
                          _buildDivider(),
                          _buildNavigationSetting(
                            context,
                            icon: LucideIcons.fileText,
                            title: 'Licenses',
                            subtitle: 'Open source licenses',
                            onTap: _showLicensesBottomSheet,
                          ),
                        ],
                      ),

                      const SizedBox(height: AppConstants.spacingLg),

                      // Support section
                      _buildSectionHeader(context, 'Support'),
                      AnimatedBuilder(
                        animation: _donationPulseAnimation,
                        builder: (context, child) {
                          return _buildSettingsCard(
                            context,
                            border: Border.all(
                              color: AppColors.textPrimary.withValues(
                                alpha: 0.25 + _donationPulseAnimation.value * 0.55,
                              ),
                              width: 1.0 + _donationPulseAnimation.value * 1.2,
                            ),
                            children: [
                              _buildNavigationSetting(
                                context,
                                icon: LucideIcons.heart,
                                title: 'Buy me a coffee',
                                subtitle: 'Support development on Ko-fi',
                                onTap: () => _launchUrl(
                                  'https://ko-fi.com/ultraelectronica',
                                ),
                              ),
                            ],
                          );
                        },
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

  Widget _buildLibraryCard(
    BuildContext context,
    LibraryScanPreferences libraryScanPreferences,
  ) {
    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Column(
        children: [
          // Song count info
          _buildLibraryInfo(context),
          if (_showBatteryOptimizationNotice) ...[
            _buildDivider(),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _requestBatteryOptimizationDisable,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(AppConstants.radiusLg),
                ),
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
                          LucideIcons.batteryWarning,
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
                              _isXiaomiDevice
                                  ? 'Disable Battery Optimization (Recommended)'
                                  : 'Disable Battery Optimization',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                color: context.adaptiveTextPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _isXiaomiDevice
                                  ? 'Required on many Xiaomi, Redmi, and POCO devices so rescans and background features keep working'
                                  : 'Allow Flick to run without aggressive background limits so rescans and background features keep working',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: context.adaptiveTextTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppConstants.spacingSm),
                      IconButton(
                        icon: Icon(
                          LucideIcons.x,
                          size: context.responsiveIcon(AppConstants.iconSizeSm),
                          color: context.adaptiveTextTertiary,
                        ),
                        tooltip: 'Dismiss',
                        onPressed: _dismissBatteryNotice,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          _buildDivider(),

          // Scanning indicator (progress shown in bottom sheet)
          if (_isScanning) ...[
            _buildScanningIndicator(context),
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
            _buildDivider(),
            _buildActionButton(
              context,
              icon: LucideIcons.copy,
              title: 'Remove Duplicates',
              subtitle: 'Find and remove duplicate songs',
              onTap: _isScanning ? null : _openDuplicateCleaner,
            ),
            _buildDivider(),
            _buildAutoSyncToggle(context),
          ],
          _buildDivider(),
          _buildExpandableScanSettings(context, libraryScanPreferences),
        ],
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
    // RepaintBoundary removed as it's not needed for simple list items in a scrolling list
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

  ({IconData icon, String title, String subtitle}) _getUpdateStatusDetails() {
    if (_updatesComingSoon) {
      return (
        icon: LucideIcons.info,
        title: 'Coming Soon',
        subtitle: 'In-app updates will be available in a future release',
      );
    }

    if (_isCheckingForUpdates) {
      return (
        icon: LucideIcons.refreshCw,
        title: 'Checking for Updates',
        subtitle: 'Looking for a new update right now',
      );
    }

    if (_isInstallingUpdate) {
      return (
        icon: LucideIcons.download,
        title: 'Installing Update',
        subtitle: 'The download is running in the background',
      );
    }

    if (_restartRequiredForUpdate) {
      return (
        icon: LucideIcons.badgeCheck,
        title: 'Update Ready',
        subtitle: 'Restart the app to finish updating',
      );
    }

    if (_hasAvailableUpdate) {
      return (
        icon: LucideIcons.download,
        title: 'Update Available',
        subtitle: 'A new update is ready to download',
      );
    }

    if (_updateCheckErrorMessage != null) {
      return (
        icon: LucideIcons.info,
        title: 'Could Not Check for Updates',
        subtitle: _updateCheckErrorMessage!,
      );
    }

    if (_lastScannedUpdateStatus == UpdateStatus.unavailable) {
      return (
        icon: LucideIcons.info,
        title: 'Updates Unavailable',
        subtitle: 'This build does not support in-app updates',
      );
    }

    if (_lastScannedUpdateStatus == UpdateStatus.upToDate) {
      return (
        icon: LucideIcons.badgeCheck,
        title: 'No Update Available',
        subtitle: 'You already have the latest update',
      );
    }

    return (
      icon: LucideIcons.info,
      title: 'No Update Scan Yet',
      subtitle: 'Run a manual scan to see whether an update is available',
    );
  }

  Widget _buildUpdateStatusTile(BuildContext context) {
    final details = _getUpdateStatusDetails();

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
              details.icon,
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
                  details.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  details.subtitle,
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

  Widget _buildAutoSyncToggle(BuildContext context) {
    return Consumer(
      builder: (context, ref, child) {
        final autoSyncEnabled = ref.watch(autoSyncEnabledProvider);
        final autoSyncService = ref.watch(autoLibrarySyncServiceProvider);
        final autoSyncInterval = ref.watch(autoSyncIntervalProvider);

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
                  LucideIcons.refreshCcw,
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
                      'Auto-Sync Library',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: context.adaptiveTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Check for new songs every $autoSyncInterval minutes',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.adaptiveTextTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: autoSyncEnabled,
                onChanged: (value) {
                  ref.read(autoSyncEnabledProvider.notifier).set(value);
                  if (value) {
                    autoSyncService.syncInterval = Duration(
                      minutes: autoSyncInterval,
                    );
                    autoSyncService.start();
                  } else {
                    autoSyncService.stop();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsCard(
    BuildContext context, {
    required List<Widget> children,
    BoxBorder? border,
  }) {
    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: border ?? Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 1,
      margin: EdgeInsets.only(left: 56 + AppConstants.spacingMd),
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

  Widget _buildExpandableScanSettings(
    BuildContext context,
    LibraryScanPreferences prefs,
  ) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              setState(() => _scanSettingsExpanded = !_scanSettingsExpanded);
              if (_scanSettingsExpanded) {
                _scanSettingsController.forward();
              } else {
                _scanSettingsController.reverse();
              }
            },
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
                      LucideIcons.settings2,
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
                          'Scanning Settings',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: context.adaptiveTextPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Filter files, size limits, and playlist import options',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: context.adaptiveTextTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  RotationTransition(
                    turns: _scanSettingsRotation,
                    child: Icon(
                      LucideIcons.chevronDown,
                      color: context.adaptiveTextTertiary,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizeTransition(
          sizeFactor: _scanSettingsController,
          child: Column(
            children: [
              _buildDivider(),
              _buildToggleSetting(
                context,
                icon: LucideIcons.scanSearch,
                title: 'Filter Non-Music Files & Folders',
                subtitle: 'Skip unsupported files and hidden .nomedia directories',
                value: prefs.filterNonMusicFilesAndFolders,
                onChanged: (value) {
                  ref
                      .read(libraryScanPreferencesProvider.notifier)
                      .setFilterNonMusicFilesAndFolders(value);
                },
              ),
              _buildDivider(),
              _buildToggleSetting(
                context,
                icon: LucideIcons.fileMinus,
                title: 'Ignore Tracks Under 500 KB',
                subtitle: 'Exclude tiny clips, previews, and accidental scraps',
                value: prefs.ignoreTracksSmallerThan500Kb,
                onChanged: (value) {
                  ref
                      .read(libraryScanPreferencesProvider.notifier)
                      .setIgnoreTracksSmallerThan500Kb(value);
                },
              ),
              _buildDivider(),
              _buildToggleSetting(
                context,
                icon: LucideIcons.timerOff,
                title: 'Ignore Tracks Under 60 Seconds',
                subtitle: 'Hide short stingers, ringtones, and voice fragments',
                value: prefs.ignoreTracksShorterThan60Seconds,
                onChanged: (value) {
                  ref
                      .read(libraryScanPreferencesProvider.notifier)
                      .setIgnoreTracksShorterThan60Seconds(value);
                },
              ),
              _buildDivider(),
              _buildToggleSetting(
                context,
                icon: LucideIcons.listMusic,
                title: 'Import M3U/M3U8 Playlists',
                subtitle:
                    'Create or refresh playlists found inside scanned folders',
                value: prefs.createPlaylistsFromM3uFiles,
                onChanged: (value) {
                  ref
                      .read(libraryScanPreferencesProvider.notifier)
                      .setCreatePlaylistsFromM3uFiles(value);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSelectionSetting(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
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
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                color: selected
                    ? context.adaptiveTextPrimary
                    : context.adaptiveTextTertiary,
                size: 20,
              ),
            ],
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
    );
  }
}

class _PatchNotes {
  const _PatchNotes({
    required this.title,
    required this.body,
    required this.url,
  });

  final String title;
  final String body;
  final String url;
}
