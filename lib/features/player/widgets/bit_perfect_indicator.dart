import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/models/album_color_mode.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/app_preferences_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/features/player/widgets/audio_visualizer.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Compact bit-perfect indicator capsule for the player file-info row.
///
/// Shows HQ/SD with color-coded status based on the active audio path.
/// Tapping opens a detailed bottom sheet with diagnostics.
class BitPerfectIndicator extends ConsumerWidget {
  final Song song;
  final PlayerService playerService;
  final VoidCallback? onTap;

  const BitPerfectIndicator({
    super.key,
    required this.song,
    required this.playerService,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diagnostics = ref.watch(audioOutputDiagnosticsProvider);
    final prefs = ref.watch(appPreferencesProvider);

    final state = _resolveState(
      diagnostics,
      suppressVerified: prefs.replaceAlbumWithBitPerfectCapsule,
    );
    final label = _getSongQuality(song);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.responsive(4.0, 5.0, 6.0),
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: state.bgColor,
          borderRadius: BorderRadius.circular(3),
          border: state.borderColor != null
              ? Border.all(color: state.borderColor!, width: 1)
              : null,
          boxShadow: state.glowColor != null
              ? [
                  BoxShadow(
                    color: state.glowColor!,
                    blurRadius: 6,
                    spreadRadius: -2,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.icon != null) ...[
              Icon(
                state.icon!,
                size: context.responsive(8.0, 9.0, 10.0),
                color: state.textColor,
              ),
              SizedBox(width: context.responsive(2.0, 2.5, 3.0)),
            ],
            Text(
              label,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: context.responsive(9.0, 10.0, 11.0),
                fontWeight: FontWeight.w600,
                color: state.textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _getSongQuality(Song song) {
    if (song.isDsd) return 'HQ';
    final fileType = song.fileType.toUpperCase();
    const lossless = {'FLAC', 'WAV', 'ALAC', 'AIFF', 'APE', 'WV'};
    if (lossless.contains(fileType)) return 'HQ';
    if ((song.bitDepth ?? 0) >= 24) return 'HQ';
    if ((song.sampleRate ?? 0) >= 88200) return 'HQ';
    final res = song.resolution?.toLowerCase() ?? '';
    final m = RegExp(r'(\d+)\s*kbps').firstMatch(res);
    if (m != null && (int.tryParse(m.group(1)!) ?? 0) >= 320) return 'HQ';
    return 'SD';
  }

  static _IndicatorState _resolveState(
    AudioOutputDiagnostics? diagnostics, {
    bool suppressVerified = false,
  }) {
    final isVerified =
        diagnostics?.capabilityFlags.supportsVerifiedBitPerfect == true &&
        diagnostics?.resamplerActive != true;

    final isLocked =
        diagnostics != null &&
        diagnostics.capabilityFlags.supportsVerifiedBitPerfect == true &&
        diagnostics.resamplerActive == true;

    if (isVerified && !suppressVerified) {
      return _IndicatorState.verified();
    }
    if (isVerified && suppressVerified) {
      return _IndicatorState.standard();
    }
    if (isLocked) {
      return _IndicatorState.locked();
    }
    return _IndicatorState.standard();
  }

  /// Opens a sleek bottom sheet with full audio diagnostics.
  static void showInfoSheet(
    BuildContext context, {
    required Song song,
    required AudioOutputDiagnostics? diagnostics,
    required Uac2DeviceStatus? deviceStatus,
    required PlayerService playerService,
  }) {
    final isVerified =
        diagnostics?.capabilityFlags.supportsVerifiedBitPerfect == true &&
        diagnostics?.resamplerActive != true;
    final isDirectUsb =
        diagnostics?.pathManagement ==
        AudioPathManagement.directUsbExperimental;

    showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _AudioInfoBottomSheet(
        song: song,
        diagnostics: diagnostics,
        deviceStatus: deviceStatus,
        playerService: playerService,
        isVerified: isVerified,
        isDirectUsb: isDirectUsb,
      ),
    );
  }
}

class _IndicatorState {
  final Color bgColor;
  final Color textColor;
  final Color? borderColor;
  final Color? glowColor;
  final IconData? icon;

  const _IndicatorState({
    required this.bgColor,
    required this.textColor,
    this.borderColor,
    this.glowColor,
    this.icon,
  });

  factory _IndicatorState.verified() => _IndicatorState(
    bgColor: Colors.green.withValues(alpha: 0.22),
    textColor: Colors.green.shade400,
    borderColor: Colors.green.withValues(alpha: 0.5),
    glowColor: Colors.green.withValues(alpha: 0.12),
    icon: Icons.verified_rounded,
  );

  factory _IndicatorState.locked() => _IndicatorState(
    bgColor: Colors.amber.withValues(alpha: 0.18),
    textColor: Colors.amber.shade400,
    borderColor: Colors.amber.withValues(alpha: 0.4),
    glowColor: Colors.amber.withValues(alpha: 0.08),
    icon: Icons.lock_rounded,
  );

  factory _IndicatorState.standard() => _IndicatorState(
    bgColor: Colors.white.withValues(alpha: 0.2),
    textColor: Colors.white,
  );
}

class _AudioInfoBottomSheet extends ConsumerStatefulWidget {
  final Song song;
  final AudioOutputDiagnostics? diagnostics;
  final Uac2DeviceStatus? deviceStatus;
  final PlayerService playerService;
  final bool isVerified;
  final bool isDirectUsb;

  const _AudioInfoBottomSheet({
    required this.song,
    required this.diagnostics,
    required this.deviceStatus,
    required this.playerService,
    required this.isVerified,
    required this.isDirectUsb,
  });

  @override
  ConsumerState<_AudioInfoBottomSheet> createState() =>
      _AudioInfoBottomSheetState();
}

class _AudioInfoBottomSheetState extends ConsumerState<_AudioInfoBottomSheet> {
  late final PageController _pageController;
  int _currentPage = 0;
  bool _isExpanded = false;

  static const double _collapsedHeight = 100.0;

  bool get _showPageView => widget.isVerified;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _pageController.addListener(() {
      final page = _pageController.page?.round() ?? 0;
      if (page != _currentPage) {
        setState(() => _currentPage = page);
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() => _isExpanded = !_isExpanded);
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPreferencesProvider);
    final colorMode = ref.watch(albumColorModeProvider);
    final dominantColor = ref.watch(albumDominantColorSyncProvider);
    final Color? albumColor =
        (colorMode != AlbumColorMode.off && dominantColor != null)
            ? dominantColor
            : null;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: AppColors.glassBorder),
          left: BorderSide(color: AppColors.glassBorder),
          right: BorderSide(color: AppColors.glassBorder),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle (always visible).
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: _buildDragHandle(),
            ),
            // Header crossfade: full header in collapsed, compact bar in expanded.
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 350),
              sizeCurve: Curves.easeInOutCubic,
              firstCurve: Curves.easeInOutCubic,
              secondCurve: Curves.easeInOutCubic,
              crossFadeState: _isExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: _buildHeader(context),
              ),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: _buildExpandedTopBar(context),
              ),
            ),
            // Info rows: collapse to 0 height when expanded.
            AnimatedSize(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: _isExpanded
                  ? const SizedBox(width: double.infinity, height: 0)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: _buildInfoRows(context),
                    ),
            ),
            // Page view: animated height + decoration.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOutCubic,
                height: _isExpanded ? 480 : _collapsedHeight,
                decoration: BoxDecoration(
                  color: AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _buildPageView(
                        context,
                        albumColor: albumColor,
                        prefs: prefs,
                        expanded: _isExpanded,
                      ),
                    ),
                    Positioned(
                      top: 6,
                      left: 6,
                      child: _buildPageLabelBadge(context),
                    ),
                    if (_showPageView)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: _toggleExpanded,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: AppColors.background.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              transitionBuilder: (child, anim) => FadeTransition(
                                opacity: anim,
                                child: ScaleTransition(scale: anim, child: child),
                              ),
                              child: Icon(
                                _isExpanded
                                    ? Icons.close_fullscreen_rounded
                                    : Icons.open_in_full_rounded,
                                key: ValueKey(_isExpanded),
                                size: 14,
                                color: context.adaptiveTextSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Page dots: only when bit-perfect AND collapsed.
            AnimatedSize(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              child: _showPageView && !_isExpanded
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: _buildPageDots(context),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
            // Bottom padding.
            AnimatedSize(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              child: SizedBox(height: _isExpanded ? 16 : 24),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact top bar shown when expanded: drag-handle region + Bit-perfect chip + close.
  Widget _buildExpandedTopBar(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_rounded, size: 12, color: Colors.green.shade400),
                const SizedBox(width: 4),
                Text(
                  'Bit-perfect',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Shared widgets ----

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.textTertiary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.isVerified
                ? Colors.green.withValues(alpha: 0.15)
                : widget.isDirectUsb
                    ? Colors.blue.withValues(alpha: 0.15)
                    : AppColors.glassBackgroundStrong,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            widget.isVerified ? LucideIcons.badgeCheck : LucideIcons.audioWaveform,
            size: 20,
            color: widget.isVerified
                ? Colors.green.shade400
                : widget.isDirectUsb
                    ? Colors.blue.shade400
                    : context.adaptiveTextPrimary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Audio Signal Path',
                style: TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: context.adaptiveTextPrimary,
                ),
              ),
              if (widget.isVerified)
                Text(
                  'Bit-perfect verified',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 12,
                    color: Colors.green.shade400,
                    fontWeight: FontWeight.w500,
                  ),
                )
              else if (widget.isDirectUsb)
                Text(
                  'Direct USB experimental',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 12,
                    color: Colors.blue.shade400,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
        if (widget.isVerified)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.verified_rounded,
                  size: 12,
                  color: Colors.green.shade400,
                ),
                const SizedBox(width: 4),
                Text(
                  'BP',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade400,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildInfoRows(BuildContext context) {
    final rows = <Widget>[];
    final d = widget.diagnostics;

    rows.add(
      _buildRow(
        context,
        label: 'Format',
        value: widget.song.isDsd
            ? '${widget.song.fileType.toUpperCase()} (${widget.song.dsdRateLabel})'
            : widget.song.fileType.toUpperCase(),
      ),
    );

    if (widget.song.resolution != null && !widget.song.isDsd) {
      rows.add(
        _buildRow(context, label: 'Resolution', value: widget.song.resolution!),
      );
    }

    if (widget.song.sampleRate != null) {
      rows.add(
        _buildRow(
          context,
          label: 'Source rate',
          value: _formatHz(widget.song.sampleRate!),
        ),
      );
    }

    final outRate =
        d?.reportedOutputSampleRate ??
        d?.requestedOutputSampleRate ??
        widget.deviceStatus?.currentFormat?.sampleRate;
    if (outRate != null) {
      // DSD transports report a divided rate (native ÷8, DoP ÷16, wire ÷32).
      // Show the DSD bit rate like the DAP does; any valid domain matches.
      int displayRate = outRate;
      var matches = false;
      final dsdBitRate = widget.song.isDsd ? widget.song.sampleRate : null;
      if (dsdBitRate != null) {
        if (outRate == dsdBitRate) {
          displayRate = dsdBitRate;
          matches = true;
        } else if (outRate * 8 == dsdBitRate ||
            outRate * 16 == dsdBitRate ||
            outRate * 32 == dsdBitRate) {
          displayRate = dsdBitRate;
          matches = true;
        }
      } else {
        final sourceRate = widget.song.sampleRate;
        matches = sourceRate != null && sourceRate == outRate;
      }
      rows.add(
        _buildRow(
          context,
          label: 'Output rate',
          value: _formatHz(displayRate),
          trailing: matches
              ? Icon(Icons.check_circle_rounded, size: 14, color: Colors.green.shade400)
              : Icon(Icons.warning_amber_rounded, size: 14, color: Colors.amber.shade400),
        ),
      );
    }

    final bitDepth = widget.deviceStatus?.currentFormat?.bitDepth ?? widget.song.bitDepth;
    if (bitDepth != null) {
      rows.add(_buildRow(context, label: 'Bit depth', value: '$bitDepth-bit'));
    }

    final channels = widget.deviceStatus?.currentFormat?.channels;
    if (channels != null) {
      rows.add(
        _buildRow(
          context,
          label: 'Channels',
          value: channels == 1 ? 'Mono' : channels == 2 ? 'Stereo' : '$channels ch',
        ),
      );
    }

    final backendDesc = d?.backendDescription;
    if (backendDesc != null && backendDesc.isNotEmpty) {
      rows.add(_buildRow(context, label: 'Engine', value: backendDesc));
    }

    final strategy = d?.outputStrategyLabel;
    if (strategy != null && strategy.isNotEmpty) {
      rows.add(_buildRow(context, label: 'Strategy', value: strategy));
    }

    final deviceLabel =
        widget.deviceStatus?.device.productName ??
        d?.outputDeviceLabel ??
        d?.detectedDapBrand;
    if (deviceLabel != null && deviceLabel.isNotEmpty) {
      rows.add(_buildRow(context, label: 'Device', value: deviceLabel));
    }

    final volMode = widget.deviceStatus?.volumeMode;
    if (volMode != null && volMode != Uac2VolumeMode.unavailable) {
      rows.add(_buildRow(context, label: 'Volume', value: _formatVolumeMode(volMode)));
    }

    final routeLabel = d?.routeLabel;
    if (routeLabel != null && routeLabel.isNotEmpty) {
      rows.add(
        _buildRow(
          context,
          label: 'Route',
          value: routeLabel,
          trailing: widget.isDirectUsb
              ? _buildTinyBadge('Direct', Colors.blue)
              : (d?.isMixerManaged ?? false)
                  ? _buildTinyBadge('Mixer', Colors.grey)
                  : null,
        ),
      );
    }

    if (d != null) {
      rows.add(
        _buildRow(
          context,
          label: 'Resampler',
          value: d.resamplerActive ? 'Active' : 'Inactive',
          trailing: d.resamplerActive
              ? Icon(Icons.warning_amber_rounded, size: 14, color: Colors.amber.shade400)
              : Icon(Icons.check_circle_rounded, size: 14, color: Colors.green.shade400),
        ),
      );
    }

    if (d != null) {
      rows.add(
        _buildRow(
          context,
          label: 'Passthrough',
          value: d.passthroughAllowed ? 'Allowed' : 'Blocked',
          trailing: d.passthroughAllowed
              ? Icon(Icons.check_circle_rounded, size: 14, color: Colors.green.shade400)
              : Icon(Icons.block_rounded, size: 14, color: Colors.red.shade400),
        ),
      );
    }

    if (d?.directUsbRegistered == true) {
      final usbParts = <String>[
        if (d!.usbInterfaceClaimed) 'Interface claimed',
        if (d.usbStreamStable) 'Stream stable',
      ];
      if (usbParts.isNotEmpty) {
        rows.add(_buildRow(context, label: 'USB', value: usbParts.join(' · ')));
      }
    }

    final verification = d?.verificationReason;
    final fallback = d?.fallbackReason;
    if (verification != null && verification.isNotEmpty) {
      rows.add(_buildRow(context, label: 'Verified', value: verification));
    } else if (fallback != null && fallback.isNotEmpty) {
      rows.add(_buildRow(context, label: 'Fallback', value: fallback));
    }

    final isDop = widget.deviceStatus?.currentFormat?.isDop ?? false;
    final isNativeDsd = widget.deviceStatus?.currentFormat?.isNativeDsd ?? false;
    if (isDop || isNativeDsd || widget.song.isDsd) {
      final dsdLabel = isNativeDsd ? 'Native DSD' : isDop ? 'DoP' : 'DSD';
      rows.add(_buildRow(context, label: 'DSD mode', value: dsdLabel));
    }

    if (widget.song.filePath != null) {
      rows.add(
        _buildRow(context, label: 'Source', value: _truncatePath(widget.song.filePath!)),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required String label,
    required String value,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.adaptiveTextSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 13,
                color: context.adaptiveTextPrimary,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 4), trailing],
        ],
      ),
    );
  }

  Widget _buildTinyBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'ProductSans',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  // ---- PageView area ----

  Widget _buildPageLabelBadge(BuildContext context) {
    final label = _showPageView ? _pageLabel(_currentPage) : 'Visualizer';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'ProductSans',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: context.adaptiveTextSecondary,
        ),
      ),
    );
  }

  Widget _buildPageDots(BuildContext context) {
    const pageCount = 4;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(pageCount, (i) {
        final active = i == _currentPage;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 16 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active
                ? Colors.green.shade400
                : AppColors.textTertiary.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  Widget _buildPageView(
    BuildContext context, {
    required Color? albumColor,
    required AppPreferences prefs,
    required bool expanded,
  }) {
    if (!_showPageView) {
      return AudioVisualizer(
        playerService: widget.playerService,
        animationStyle: prefs.visualizerAnimationStyle,
        frequencyMode: prefs.visualizerFrequencyMode,
        movementMode: prefs.visualizerMovementMode,
        albumColor: albumColor,
        enabled: prefs.visualizerEnabled,
      );
    }

    return PageView(
      controller: _pageController,
      children: [
        _buildVisualizerPage(albumColor, prefs),
        _buildSourceFlowPage(context, expanded),
        _buildUrbFlowPage(context, expanded),
        _buildRecordedFlowPage(context, expanded),
      ],
    );
  }

  String _pageLabel(int page) {
    switch (page) {
      case 0:
        return 'Visualizer';
      case 1:
        return 'Source';
      case 2:
        return 'URB Transfer';
      case 3:
        return 'Recorded';
      default:
        return '';
    }
  }

  // ---- Flow diagram pages ----

  Widget _buildVisualizerPage(Color? albumColor, AppPreferences prefs) {
    return AudioVisualizer(
      playerService: widget.playerService,
      animationStyle: prefs.visualizerAnimationStyle,
      frequencyMode: prefs.visualizerFrequencyMode,
      movementMode: prefs.visualizerMovementMode,
      albumColor: albumColor,
      enabled: prefs.visualizerEnabled,
    );
  }

  Widget _buildSourceFlowPage(BuildContext context, bool expanded) {
    final song = widget.song;
    final fmt = song.isDsd
        ? '${song.fileType.toUpperCase()} ${song.dsdRateLabel}'
        : song.fileType.toUpperCase();
    final rate = song.sampleRate != null ? _formatHz(song.sampleRate!) : null;
    final bd = song.bitDepth;
    final ch = widget.deviceStatus?.currentFormat?.channels;

    // Pseudo audio header bytes from file path seed (deterministic).
    final bytes = _seededBytes(song.filePath ?? song.id, 16);

    const stageColors = [
      Color(0xFFFF9100), // File — vibrant orange
      Color(0xFFEA80FC), // Decode — vibrant purple
      Color(0xFF00E5FF), // Format — vibrant cyan
    ];

    final stages = <_FlowStageData>[
      _FlowStageData(
        icon: Icons.insert_drive_file_outlined,
        title: 'File',
        subtitle: fmt,
        detail: song.resolution ?? song.filePath?.split('.').last.toUpperCase(),
        visual: _FlowVisual.bytes(bytes, stageIndex: 0),
        color: stageColors[0],
      ),
      _FlowStageData(
        icon: Icons.transform_rounded,
        title: 'Decode',
        subtitle: song.isDsd ? 'DSD stream' : '→ Raw PCM',
        detail: song.isDsd ? '1-bit' : 'Linear',
        visual: _FlowVisual.bytes(
          bytes.map((b) => (b * 3) & 0xFF).toList(),
          stageIndex: 1,
        ),
        color: stageColors[1],
      ),
      _FlowStageData(
        icon: Icons.multiline_chart_rounded,
        title: 'Format',
        subtitle: rate ?? '-',
        detail: [
          if (bd != null) '$bd-bit',
          if (ch != null) (ch == 2 ? 'Stereo' : '$ch ch'),
        ].join(' · '),
        visual: _FlowVisual.buffer(
          bd != null ? bd / 32.0 : 0.5,
          stageIndex: 2,
        ),
        color: stageColors[2],
      ),
    ];

    return _FlowDiagram(
      stages: stages,
      expanded: expanded,
      accentColor: const Color(0xFF00E676),
    );
  }

  /// Deterministic pseudo bytes from a seed string.
  static List<int> _seededBytes(String seed, int count) {
    var h = 0x811c9dc5;
    for (var i = 0; i < seed.length; i++) {
      h ^= seed.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return List<int>.generate(count, (i) {
      h = (h * 0x01000193 + i) & 0xFFFFFFFF;
      return (h ^ (h >> 16)) & 0xFF;
    });
  }

  Widget _buildUrbFlowPage(BuildContext context, bool expanded) {
    final urb = widget.diagnostics?.urbTransport;
    if (urb == null) {
      return _emptyFlowPage(context, 'No URB data');
    }

    final fillRatio = (urb.bufferFillMs != null && urb.bufferTargetMs != null)
        ? (urb.bufferFillMs! / urb.bufferTargetMs!).clamp(0.0, 1.0)
        : 0.5;
    final packetCount = (urb.activeMaxPacketBytes != null
            ? (urb.activeMaxPacketBytes! / 64).clamp(2, 8)
            : 4)
        .toInt();

    const stageColors = [
      Color(0xFF69F0AE), // PCM Frames — vibrant mint
      Color(0xFF40C4FF), // Endpoint — vibrant sky blue
      Color(0xFF7C4DFF), // URB Packet — vibrant violet
      Color(0xFFFFD740), // Buffer — vibrant amber
      Color(0xFF64FFDA), // Stream — vibrant teal
    ];

    final stages = <_FlowStageData>[
      _FlowStageData(
        icon: Icons.grid_on_rounded,
        title: 'PCM Frames',
        subtitle: urb.framesPerPacket != null ? '${urb.framesPerPacket} fr/pkt' : '-',
        detail: urb.transportFormat,
        visual: _FlowVisual.bytes(
          _seededBytes('pcm-${widget.song.id}', 12),
          stageIndex: 0,
        ),
        color: stageColors[0],
      ),
      _FlowStageData(
        icon: Icons.usb_rounded,
        title: 'Endpoint',
        subtitle: urb.activeEndpointAddress != null
            ? 'EP ${urb.activeEndpointAddress}'
            : '-',
        detail: [
          if (urb.activeAltSetting != null) 'Alt ${urb.activeAltSetting}',
          if (urb.activeSyncType != null) urb.activeSyncType,
        ].join(' · '),
        color: stageColors[1],
      ),
      _FlowStageData(
        icon: Icons.send_rounded,
        title: 'URB Packet',
        subtitle: urb.activeMaxPacketBytes != null
            ? 'Max ${urb.activeMaxPacketBytes} B'
            : '-',
        detail: [
          if (urb.activeUsageType != null) urb.activeUsageType,
          if (urb.activeServiceIntervalUs != null)
            '${urb.activeServiceIntervalUs} µs',
        ].join(' · '),
        visual: _FlowVisual.packets(packetCount, stageIndex: 2),
        color: stageColors[2],
      ),
      _FlowStageData(
        icon: Icons.storage_rounded,
        title: 'Buffer',
        subtitle: urb.bufferFillMs != null ? '${urb.bufferFillMs} ms' : '-',
        detail: [
          if (urb.bufferCapacityMs != null) 'cap ${urb.bufferCapacityMs} ms',
          if (urb.bufferTargetMs != null) 'target ${urb.bufferTargetMs} ms',
        ].join(' · '),
        visual: _FlowVisual.buffer(fillRatio, stageIndex: 3),
        color: stageColors[3],
      ),
      _FlowStageData(
        icon: Icons.stream_rounded,
        title: 'Stream',
        subtitle: urb.underrunCount != null
            ? '${urb.underrunCount} underruns'
            : '-',
        detail: urb.driftMsFromTarget != null
            ? 'Drift ${urb.driftMsFromTarget} ms'
            : null,
        visual: _FlowVisual.check(
          (urb.underrunCount ?? 0) == 0,
          pending: urb.underrunCount == null,
          stageIndex: 4,
        ),
        color: stageColors[4],
      ),
    ];

    return _FlowDiagram(
      stages: stages,
      expanded: expanded,
      accentColor: const Color(0xFF00B0FF),
    );
  }

  Widget _buildRecordedFlowPage(BuildContext context, bool expanded) {
    final song = widget.song;
    final hasRipData = song.ripper != null || song.readMode != null;

    if (!hasRipData) {
      return _emptyFlowPage(context, 'No rip data');
    }

    final crcOk = _crcMatch(song);

    const stageColors = [
      Color(0xFFFFD600), // Rip Source — vibrant amber
      Color(0xFFFFAB00), // Read Mode — vibrant orange
      Color(0xFFFF6D00), // CRC — vibrant deep orange
      Color(0xFFFFD600), // AccurateRip — vibrant amber
    ];

    final stages = <_FlowStageData>[
      _FlowStageData(
        icon: Icons.disc_full_rounded,
        title: 'Rip Source',
        subtitle: song.ripper ?? '-',
        detail: null,
        visual: _FlowVisual.check(song.ripper != null, stageIndex: 0),
        color: stageColors[0],
      ),
      _FlowStageData(
        icon: Icons.playlist_add_check_rounded,
        title: 'Read Mode',
        subtitle: song.readMode ?? '-',
        detail: null,
        visual: _FlowVisual.check(song.readMode != null, stageIndex: 1),
        color: stageColors[1],
      ),
      _FlowStageData(
        icon: Icons.compare_arrows_rounded,
        title: 'CRC',
        subtitle: song.copyCrc ?? '-',
        detail: song.testCrc != null ? 'Test: ${song.testCrc}' : null,
        visual: _FlowVisual.check(crcOk, pending: !crcOk, stageIndex: 2),
        color: stageColors[2],
      ),
      _FlowStageData(
        icon: Icons.verified_rounded,
        title: 'AccurateRip',
        subtitle: song.accurateRip == true ? 'Verified' : 'Not verified',
        detail: null,
        visual: _FlowVisual.check(
          song.accurateRip == true,
          pending: song.accurateRip == null,
          stageIndex: 3,
        ),
        color: stageColors[3],
      ),
    ];

    return _FlowDiagram(
      stages: stages,
      expanded: expanded,
      accentColor: const Color(0xFFFFD600),
    );
  }

  bool _crcMatch(Song song) =>
      song.testCrc != null && song.copyCrc != null && song.testCrc == song.copyCrc;

  Widget _emptyFlowPage(BuildContext context, String message) {
    return Center(
      child: Text(
        message,
        style: TextStyle(
          fontFamily: 'ProductSans',
          fontSize: 12,
          color: context.adaptiveTextSecondary,
        ),
      ),
    );
  }

  // ---- Helpers ----

  static String _formatHz(int rate) {
    if (rate >= 1000000) {
      return '${(rate / 1000000).toStringAsFixed(2)} MHz';
    } else if (rate >= 1000) {
      return '${(rate / 1000).toStringAsFixed(1)} kHz';
    }
    return '$rate Hz';
  }

  static String _formatVolumeMode(Uac2VolumeMode mode) {
    switch (mode) {
      case Uac2VolumeMode.system:
        return 'System (Android mixer)';
      case Uac2VolumeMode.hardware:
        return 'Hardware (USB DAC)';
      case Uac2VolumeMode.software:
        return 'Software (App-controlled)';
      case Uac2VolumeMode.unavailable:
        return 'Unavailable';
    }
  }

  static String _truncatePath(String path, {int max = 48}) {
    if (path.length <= max) return path;
    return '...${path.substring(path.length - max + 3)}';
  }
}

/// Data for one stage in a flow diagram.
class _FlowStageData {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? detail;
  final _FlowVisual? visual;
  final Color? color;

  const _FlowStageData({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.detail,
    this.visual,
    this.color,
  });
}

/// Optional visual payload rendered inside a stage card.
class _FlowVisual {
  final _FlowVisualKind kind;
  final List<int>? bytes;
  final int? packetCount;
  final double? fillRatio;
  final bool? verified;
  final bool? pending;
  final int? stageIndex;

  const _FlowVisual.bytes(this.bytes, {this.stageIndex})
      : kind = _FlowVisualKind.bytes,
        packetCount = null,
        fillRatio = null,
        verified = null,
        pending = null;

  const _FlowVisual.packets(this.packetCount, {this.stageIndex})
      : kind = _FlowVisualKind.packets,
        bytes = null,
        fillRatio = null,
        verified = null,
        pending = null;

  const _FlowVisual.buffer(this.fillRatio, {this.stageIndex})
      : kind = _FlowVisualKind.buffer,
        bytes = null,
        packetCount = null,
        verified = null,
        pending = null;

  const _FlowVisual.check(this.verified, {this.pending = false, this.stageIndex})
      : kind = _FlowVisualKind.check,
        bytes = null,
        packetCount = null,
        fillRatio = null;
}

enum _FlowVisualKind { bytes, packets, buffer, check }

/// Vertical flow diagram: stages connected by animated arrows + flowing particles.
class _FlowDiagram extends StatelessWidget {
  final List<_FlowStageData> stages;
  final bool expanded;
  final Color accentColor;

  const _FlowDiagram({
    required this.stages,
    required this.expanded,
    required this.accentColor,
  });

  List<Color> get _stageColors =>
      stages.map((s) => s.color ?? accentColor).toList();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        if (!expanded && h <= 120) {
          return _buildHorizontalFlow(context);
        }
        return _buildVerticalFlow(context);
      },
    );
  }

  Widget _buildHorizontalFlow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: _buildCompactStageWidgets(),
      ),
    );
  }

  List<Widget> _buildCompactStageWidgets() {
    final list = <Widget>[];
    for (int i = 0; i < stages.length; i++) {
      list.add(
        Expanded(
          child: _FlowStageCompact(
            data: stages[i],
            accentColor: accentColor,
            index: i,
          ),
        ),
      );
      if (i < stages.length - 1) {
        list.add(
          SizedBox(
            width: 14,
            child: _CompactFlowArrow(
              fromColor: _stageColors[i],
              toColor: _stageColors[i + 1],
            ),
          ),
        );
      }
    }
    return list;
  }

  Widget _buildVerticalFlow(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      physics: const BouncingScrollPhysics(),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            children: stages.asMap().entries.expand((entry) {
              final i = entry.key;
              final s = entry.value;
              return [
                _FlowStageCard(
                  data: s,
                  accentColor: accentColor,
                  index: i,
                  total: stages.length,
                ),
                if (i < stages.length - 1)
                  _FlowConnector(
                    fromColor: _stageColors[i],
                    toColor: _stageColors[i + 1],
                    active: i < 2,
                  ),
              ];
            }).toList(),
          ),
        ),
      ),
    );
  }
}

/// Vertical connector with animated flowing dots and a glowing arrowhead.
class _FlowConnector extends StatefulWidget {
  final Color fromColor;
  final Color toColor;
  final bool active;
  const _FlowConnector({
    required this.fromColor,
    required this.toColor,
    this.active = true,
  });

  @override
  State<_FlowConnector> createState() => _FlowConnectorState();
}

class _FlowConnectorState extends State<_FlowConnector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.active) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _FlowConnector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 32,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _ConnectorPainter(
              progress: _controller.value,
              fromColor: widget.fromColor,
              toColor: widget.toColor,
            ),
          );
        },
      ),
    );
  }
}

class _ConnectorPainter extends CustomPainter {
  final double progress;
  final Color fromColor;
  final Color toColor;
  const _ConnectorPainter({
    required this.progress,
    required this.fromColor,
    required this.toColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final lineTop = 4.0;
    final lineBottom = h - 8.0;
    final midColor = Color.lerp(fromColor, toColor, 0.5)!;

    // Main vertical line with gradient (faded at ends).
    final linePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          fromColor.withValues(alpha: 0.15),
          midColor.withValues(alpha: 0.55),
          toColor.withValues(alpha: 0.15),
        ],
      ).createShader(Rect.fromLTWH(cx - 0.75, lineTop, 1.5, lineBottom - lineTop));
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - 0.75, lineTop, 1.5, lineBottom - lineTop),
      const Radius.circular(0.75),
    );
    canvas.drawRRect(rrect, linePaint);

    // Flowing particles (3 dots cascading down).
    for (int i = 0; i < 3; i++) {
      final offset = (progress + i / 3.0) % 1.0;
      final y = lineTop + offset * (lineBottom - lineTop);
      final alpha = (1.0 - (offset - 0.5).abs() * 2.0).clamp(0.0, 1.0);
      final particleColor = Color.lerp(fromColor, toColor, offset)!;
      final glow = Paint()
        ..color = particleColor.withValues(alpha: 0.35 * alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(Offset(cx, y), 3.0, glow);
      final dot = Paint()..color = particleColor.withValues(alpha: 0.85 * alpha);
      canvas.drawCircle(Offset(cx, y), 1.8, dot);
    }

    // Arrowhead at bottom.
    final arrowPath = Path()
      ..moveTo(cx - 5, lineBottom - 1)
      ..lineTo(cx + 5, lineBottom - 1)
      ..lineTo(cx, lineBottom + 5)
      ..close();
    final arrowPaint = Paint()..color = toColor.withValues(alpha: 0.7);
    canvas.drawPath(arrowPath, arrowPaint);
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      old.progress != progress ||
      old.fromColor != fromColor ||
      old.toColor != toColor;
}

/// Compact horizontal arrow with small flow pulse.
class _CompactFlowArrow extends StatefulWidget {
  final Color fromColor;
  final Color toColor;
  const _CompactFlowArrow({
    required this.fromColor,
    required this.toColor,
  });

  @override
  State<_CompactFlowArrow> createState() => _CompactFlowArrowState();
}

class _CompactFlowArrowState extends State<_CompactFlowArrow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _CompactArrowPainter(
              progress: _controller.value,
              fromColor: widget.fromColor,
              toColor: widget.toColor,
            ),
          );
        },
      ),
    );
  }
}

class _CompactArrowPainter extends CustomPainter {
  final double progress;
  final Color fromColor;
  final Color toColor;
  const _CompactArrowPainter({
    required this.progress,
    required this.fromColor,
    required this.toColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w < 6) return;
    final cy = h / 2;

    // Faint gradient line.
    final linePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          fromColor.withValues(alpha: 0.35),
          toColor.withValues(alpha: 0.35),
        ],
      ).createShader(Rect.fromLTWH(2, cy, w - 6, 1))
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(2, cy), Offset(w - 4, cy), linePaint);

    // Flowing dot.
    final dx = 2.0 + progress * (w - 6);
    final dotColor = Color.lerp(fromColor, toColor, progress)!;
    final glow = Paint()
      ..color = dotColor.withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    canvas.drawCircle(Offset(dx, cy), 2.5, glow);
    final dot = Paint()..color = dotColor.withValues(alpha: 0.9);
    canvas.drawCircle(Offset(dx, cy), 1.3, dot);

    // Arrowhead (scaled to width).
    final headW = (w * 0.4).clamp(3.0, 5.0);
    final headH = (w * 0.3).clamp(2.5, 4.0);
    final head = Path()
      ..moveTo(w - headW - 1, cy - headH)
      ..lineTo(w - 1, cy)
      ..lineTo(w - headW - 1, cy + headH)
      ..close();
    final headPaint = Paint()..color = toColor.withValues(alpha: 0.75);
    canvas.drawPath(head, headPaint);
  }

  @override
  bool shouldRepaint(_CompactArrowPainter old) =>
      old.progress != progress ||
      old.fromColor != fromColor ||
      old.toColor != toColor;
}

/// Compact horizontal stage pill (for collapsed view).
class _FlowStageCompact extends StatelessWidget {
  final _FlowStageData data;
  final Color accentColor;
  final int index;

  const _FlowStageCompact({
    required this.data,
    required this.accentColor,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final color = data.color ?? accentColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 0.8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(data.icon, size: 12, color: color),
          const SizedBox(height: 1),
          Text(
            data.title,
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 8.5,
              fontWeight: FontWeight.w600,
              color: color.withValues(alpha: 0.95),
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          Text(
            data.subtitle,
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 7.5,
              color: context.adaptiveTextSecondary,
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Full card for one flow stage (expanded view) with optional inline visual.
class _FlowStageCard extends StatelessWidget {
  final _FlowStageData data;
  final Color accentColor;
  final int index;
  final int total;

  const _FlowStageCard({
    required this.data,
    required this.accentColor,
    required this.index,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final color = data.color ?? accentColor;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.glassBackgroundStrong,
            AppColors.glassBackground,
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.08),
            blurRadius: 12,
            spreadRadius: -2,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _StageIcon(icon: data.icon, color: color, index: index),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StageIndexBadge(index: index, total: total, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        data.title,
                        style: TextStyle(
                          fontFamily: 'ProductSans',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.adaptiveTextPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  data.subtitle,
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 13,
                    color: context.adaptiveTextSecondary,
                  ),
                ),
                if (data.detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    data.detail!,
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      fontSize: 11,
                      color: context.adaptiveTextSecondary.withValues(alpha: 0.65),
                    ),
                  ),
                ],
                if (data.visual != null) ...[
                  const SizedBox(height: 10),
                  _FlowVisualRenderer(visual: data.visual!, color: color),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small circular icon container with gradient.
class _StageIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int index;
  const _StageIcon({required this.icon, required this.color, required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.25),
            color.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Icon(icon, size: 22, color: color),
    );
  }
}

/// Tiny "01 / 05" style index badge inside stage card.
class _StageIndexBadge extends StatelessWidget {
  final int index;
  final int total;
  final Color color;
  const _StageIndexBadge({
    required this.index,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final label = '${(index + 1).toString().padLeft(2, '0')}/${total.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color.withValues(alpha: 0.9),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Renders the optional visual payload inside a stage card.
class _FlowVisualRenderer extends StatelessWidget {
  final _FlowVisual visual;
  final Color color;
  const _FlowVisualRenderer({required this.visual, required this.color});

  @override
  Widget build(BuildContext context) {
    switch (visual.kind) {
      case _FlowVisualKind.bytes:
        return _HexByteStrip(
          bytes: visual.bytes ?? const [],
          color: color,
        );
      case _FlowVisualKind.packets:
        return _PacketStream(
          count: visual.packetCount ?? 4,
          color: color,
        );
      case _FlowVisualKind.buffer:
        return _BufferBar(
          fillRatio: (visual.fillRatio ?? 0.5).clamp(0.0, 1.0),
          color: color,
        );
      case _FlowVisualKind.check:
        return _VerificationCheck(
          verified: visual.verified ?? false,
          pending: visual.pending ?? false,
          color: color,
        );
    }
  }
}

/// Animated hex byte strip for Source page.
class _HexByteStrip extends StatefulWidget {
  final List<int> bytes;
  final Color color;
  const _HexByteStrip({required this.bytes, required this.color});

  @override
  State<_HexByteStrip> createState() => _HexByteStripState();
}

class _HexByteStripState extends State<_HexByteStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.bytes.isNotEmpty
        ? widget.bytes
        : List<int>.generate(16, (i) => (i * 31 + 0xA5) & 0xFF);
    return SizedBox(
      height: 28,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _HexStripPainter(
              bytes: data,
              progress: _controller.value,
              color: widget.color,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _HexStripPainter extends CustomPainter {
  final List<int> bytes;
  final double progress;
  final Color color;
  const _HexStripPainter({
    required this.bytes,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final count = bytes.length;
    if (count == 0) return;
    final cellW = size.width / count;

    // Scrolling highlight band.
    final bandX = -cellW * 4 + progress * (size.width + cellW * 8);

    for (int i = 0; i < count; i++) {
      final x = i * cellW;
      final b = bytes[i];
      // Pulse per cell.
      final t = ((progress + i / count) % 1.0);
      final intensity = 0.3 + 0.7 * (1.0 - (t - 0.5).abs() * 2.0).clamp(0.0, 1.0);
      // Highlight band.
      final inBand = (x - bandX).abs() < cellW * 1.5;
      final alpha = inBand ? 1.0 : intensity * 0.6;

      final paint = Paint()
        ..color = color.withValues(alpha: alpha * 0.9);
      final cellRect = Rect.fromLTWH(
        x + 1,
        size.height * 0.2,
        cellW - 2,
        size.height * 0.6,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(cellRect, const Radius.circular(1.5)),
        paint,
      );

      // Byte value text.
      final tp = TextPainter(
        text: TextSpan(
          text: b.toRadixString(16).toUpperCase().padLeft(2, '0'),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 8,
            fontWeight: FontWeight.w600,
            color: Color.lerp(AppColors.background, Colors.white, alpha)!,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout(maxWidth: cellW);
      tp.paint(
        canvas,
        Offset(
          x + (cellW - tp.width) / 2,
          size.height * 0.85,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_HexStripPainter old) =>
      old.progress != progress || old.color != color || old.bytes != bytes;
}

/// Animated packet stream for URB page.
class _PacketStream extends StatefulWidget {
  final int count;
  final Color color;
  const _PacketStream({required this.count, required this.color});

  @override
  State<_PacketStream> createState() => _PacketStreamState();
}

class _PacketStreamState extends State<_PacketStream>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _PacketStreamPainter(
              count: widget.count,
              progress: _controller.value,
              color: widget.color,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _PacketStreamPainter extends CustomPainter {
  final int count;
  final double progress;
  final Color color;
  const _PacketStreamPainter({
    required this.count,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final packetW = (w / count).clamp(8.0, 24.0);
    final gap = (w - packetW * count) / (count + 1);
    final startX = gap;

    for (int i = 0; i < count; i++) {
      final baseX = startX + i * (packetW + gap);
      // Each packet has a phase offset.
      final phase = (progress + i * 0.13) % 1.0;
      final alpha = (1.0 - phase).clamp(0.0, 1.0);
      final yOffset = phase * (h * 0.5);

      // Glow.
      final glow = Paint()
        ..color = color.withValues(alpha: 0.4 * alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(baseX, h * 0.3 + yOffset - 2, packetW, h * 0.5),
          const Radius.circular(2),
        ),
        glow,
      );
      // Body.
      final body = Paint()..color = color.withValues(alpha: 0.85 * alpha);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(baseX, h * 0.3 + yOffset, packetW, h * 0.4),
          const Radius.circular(2),
        ),
        body,
      );
    }

    // Trailing line.
    final trailPaint = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, h * 0.5), Offset(w, h * 0.5), trailPaint);
  }

  @override
  bool shouldRepaint(_PacketStreamPainter old) =>
      old.progress != progress || old.color != color || old.count != count;
}

/// Buffer level bar with animated fill.
class _BufferBar extends StatefulWidget {
  final double fillRatio;
  final Color color;
  const _BufferBar({required this.fillRatio, required this.color});

  @override
  State<_BufferBar> createState() => _BufferBarState();
}

class _BufferBarState extends State<_BufferBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _BufferBarPainter(
              fillRatio: widget.fillRatio,
              progress: _controller.value,
              color: widget.color,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _BufferBarPainter extends CustomPainter {
  final double fillRatio;
  final double progress;
  final Color color;
  const _BufferBarPainter({
    required this.fillRatio,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final barH = h * 0.5;
    final y = (h - barH) / 2;

    // Track.
    final track = Paint()
      ..color = color.withValues(alpha: 0.12);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, y, w, barH),
        const Radius.circular(4),
      ),
      track,
    );

    // Fill.
    final fillW = w * fillRatio;
    final fill = Paint()
      ..shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0.5),
          color.withValues(alpha: 0.85),
        ],
      ).createShader(Rect.fromLTWH(0, y, fillW, barH));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, y, fillW, barH),
        const Radius.circular(4),
      ),
      fill,
    );

    // Sweeping highlight.
    final sweepX = progress * w;
    final sweep = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(Offset(sweepX, y + barH / 2), barH * 0.8, sweep);
  }

  @override
  bool shouldRepaint(_BufferBarPainter old) =>
      old.progress != progress ||
      old.fillRatio != fillRatio ||
      old.color != color;
}

/// Verification check with animated ✓ / pending.
class _VerificationCheck extends StatefulWidget {
  final bool verified;
  final bool pending;
  final Color color;
  const _VerificationCheck({
    required this.verified,
    required this.pending,
    required this.color,
  });

  @override
  State<_VerificationCheck> createState() => _VerificationCheckState();
}

class _VerificationCheckState extends State<_VerificationCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.pending) {
      _controller.repeat();
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _CheckPainter(
              progress: _controller.value,
              verified: widget.verified,
              pending: widget.pending,
              color: widget.color,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  final double progress;
  final bool verified;
  final bool pending;
  final Color color;
  const _CheckPainter({
    required this.progress,
    required this.verified,
    required this.pending,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final boxSize = size.height * 0.6;
    final boxY = (size.height - boxSize) / 2;
    final boxX = 0.0;

    // Box.
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(boxX, boxY, boxSize, boxSize),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = color.withValues(alpha: 0.15),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    if (verified) {
      // Checkmark, drawn in.
      final path = Path();
      final tip = Offset(boxX + boxSize * 0.72, boxY + boxSize * 0.5);
      final mid = Offset(boxX + boxSize * 0.4, boxY + boxSize * 0.68);
      final start = Offset(boxX + boxSize * 0.22, boxY + boxSize * 0.42);
      final p = progress.clamp(0.0, 1.0);
      if (p < 0.5) {
        final t = p * 2;
        path.moveTo(start.dx, start.dy);
        path.lineTo(
          start.dx + (mid.dx - start.dx) * t,
          start.dy + (mid.dy - start.dy) * t,
        );
      } else {
        final t = (p - 0.5) * 2;
        path.moveTo(start.dx, start.dy);
        path.lineTo(mid.dx, mid.dy);
        path.lineTo(
          mid.dx + (tip.dx - mid.dx) * t,
          mid.dy + (tip.dy - mid.dy) * t,
        );
      }
      final checkPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, checkPaint);
    } else if (pending) {
      // Pulsing dot.
      final r = boxSize * 0.18 * (0.6 + 0.4 * progress);
      final glow = Paint()
        ..color = color.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawCircle(
        Offset(boxX + boxSize / 2, cy),
        r * 1.5,
        glow,
      );
      canvas.drawCircle(
        Offset(boxX + boxSize / 2, cy),
        r,
        Paint()..color = color,
      );
    } else {
      // X mark.
      final p = progress.clamp(0.0, 1.0);
      final p1 = Offset(boxX + boxSize * 0.28, boxY + boxSize * 0.28);
      final p2 = Offset(boxX + boxSize * 0.72, boxY + boxSize * 0.72);
      final p3 = Offset(boxX + boxSize * 0.28, boxY + boxSize * 0.72);
      final p4 = Offset(boxX + boxSize * 0.72, boxY + boxSize * 0.28);
      final xPaint = Paint()
        ..color = Colors.red.shade400
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      if (p >= 0.5) {
        canvas.drawLine(p1, p2, xPaint);
        canvas.drawLine(p3, p4, xPaint);
      } else {
        final t = p * 2;
        canvas.drawLine(
          Offset(p1.dx, p1.dy + (p2.dy - p1.dy) * t),
          Offset(p1.dx + (p2.dx - p1.dx) * t, p1.dy),
          xPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.progress != progress ||
      old.verified != verified ||
      old.pending != pending ||
      old.color != color;
}
