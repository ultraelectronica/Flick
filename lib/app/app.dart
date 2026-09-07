import 'dart:async';

import 'package:flick/widgets/common/flick_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/features/songs/screens/songs_screen.dart';
import 'package:flick/features/menu/screens/menu_screen.dart';
import 'package:flick/features/settings/screens/settings_screen.dart';
import 'package:flick/features/settings/screens/bottom_bar_settings_screen.dart';
import 'package:flick/features/settings/screens/support_flick_screen.dart';
import 'package:flick/features/albums/screens/albums_screen.dart';
import 'package:flick/features/artists/screens/artists_screen.dart';
import 'package:flick/features/folders/screens/folders_screen.dart';
import 'package:flick/features/playlists/screens/playlists_screen.dart';
import 'package:flick/features/favorites/screens/favorites_screen.dart';
import 'package:flick/features/search/screens/search_screen.dart';
import 'package:flick/core/navigation/root_navigator.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/features/player/widgets/audio_visualizer.dart';
import 'package:flick/widgets/navigation/flick_nav_bar.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/features/onboarding/screens/onboarding_screen.dart';
import 'package:flick/features/onboarding/tutorial_targets.dart';
import 'package:flick/features/onboarding/widgets/tutorial_overlay.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';
import 'package:flick/widgets/common/floating_mini_player.dart';
import 'package:flick/widgets/common/floating_scan_progress.dart';
import 'package:flick/widgets/uac2/usb_bit_perfect_prompt.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/library_scanner_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/app_preferences_service.dart';
import 'package:flick/services/milestone_service.dart';
import 'package:flick/services/widget_sync_service.dart';
import 'package:flick/services/widget_intent_handler.dart';
import 'package:flick/models/nav_bar_config.dart';
import 'package:flick/features/milestone/widgets/milestone_card.dart';
import 'package:flick/features/milestone/widgets/streak_popup.dart';
import 'package:flick/features/whats_new/widgets/whats_new_bottom_sheet.dart';
import 'package:flick/core/utils/dev_log.dart';

/// Main application widget for Flick Player.
class FlickPlayerApp extends StatelessWidget {
  const FlickPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Set system UI overlay style for immersive experience
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    return MaterialApp(
      title: 'Flick Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      navigatorKey: rootNavigatorKey,
      home: const _RootRouter(),
    );
  }
}

/// Main shell widget that contains navigation and screens.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Animation controller for smoother nav bar transitions
  late final AnimationController _navBarAnimationController;
  late final Animation<Offset> _navBarSlideAnimation;
  late final PageController _pageController;
  late final ProviderSubscription<bool> _navBarVisibilitySubscription;
  late final ProviderSubscription<bool> _navBarAlwaysVisibleSubscription;
  late final ProviderSubscription<Song?> _currentSongSubscription;
  late final ProviderSubscription<int> _navigationIndexSubscription;
  late final ProviderSubscription<PlayerState> _widgetSyncSubscription;
  late final ProviderSubscription<AppPreferences>? _appPreferencesSubscription;
  late final WidgetIntentHandler _widgetIntentHandler;

  // Track previous song to detect changes
  Song? _previousSong;
  // Track the PageView position being animated to programmatically.
  // When non-null, onPageChanged will allow navigation to this position
  // even if it's beyond enabledCount (disabled essential pages).
  // Cleared once the target position is reached.
  int? _programmaticPageTarget;

  int _lastHapticPage = -1;
  late final PlayerService _playerService;

  DateTime? _lastBackPressTime;

  Timer? _idleTimer;
  bool _isBottomBarCollapsed = false;

  static const double _kNestedBarClearance = 150.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Seed _previousSong from the already-restored state so the auto-navigate
    // listener doesn't treat the restored song as "new" on cold start.
    _previousSong = ref.read(currentSongProvider);
    _playerService = ref.read(playerServiceProvider);
    ref.read(equalizerProvider);
    ref.read(updateCheckProvider.notifier);
    final initialConfig = ref.read(navBarConfigProvider);
    final defaultPage =
        initialConfig.orderedButtons.contains(NavBarButton.songs)
        ? NavBarButton.songs.pageIndex
        : NavBarButton.menu.pageIndex;
    ref.read(navigationIndexProvider.notifier).setIndex(defaultPage);
    final initialIndex = ref.read(navigationIndexProvider);
    final initialOrder = _getPageOrder(initialConfig);
    final initialPosition = initialOrder.indexWhere(
      (b) => b.pageIndex == initialIndex,
    );
    _pageController = PageController(
      initialPage: initialPosition >= 0 ? initialPosition : 0,
    );
    _lastHapticPage = initialPosition >= 0 ? initialPosition : 0;
    _pageController.addListener(_onPageScroll);
    _navBarAnimationController = AnimationController(
      vsync: this,
      duration: AppConstants.animationNormal,
    );
    _navBarSlideAnimation =
        Tween<Offset>(begin: Offset.zero, end: const Offset(0, 1.15)).animate(
          CurvedAnimation(
            parent: _navBarAnimationController,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeOutCubic,
          ),
        );

    // Home-screen widget integration: keep widgets in sync with player and
    // route widget click intents back into the app.
    _widgetSyncSubscription = installWidgetSync(ref);
    _widgetIntentHandler = WidgetIntentHandler(
      ref,
      onOpenQueue: () => NavigationHelper.navigateToQueue(context),
    );
    unawaited(_widgetIntentHandler.attach());

    _navBarVisibilitySubscription = ref.listenManual<bool>(
      navBarVisibleProvider,
      (previous, next) {
        _onNavBarVisibilityChanged(next);
        if (next) {
          _startIdleTimer();
        } else {
          _cancelIdleTimer();
          if (_isBottomBarCollapsed) {
            setState(() {
              _isBottomBarCollapsed = false;
            });
          }
        }
      },
    );

    _navBarAlwaysVisibleSubscription = ref.listenManual<bool>(
      navBarAlwaysVisibleProvider,
      (previous, next) {
        if (next) {
          ref.read(navBarVisibleProvider.notifier).setVisible(true);
        }
      },
    );

    _currentSongSubscription = ref.listenManual<Song?>(currentSongProvider, (
      previousSong,
      nextSong,
    ) {
      // Only auto-navigate to the full player when a *different* song starts
      // playing while the player is active. A cold-start restore always starts
      // in a paused state, so we check isPlaying to avoid popping the full
      // player screen on every app launch.
      final songChanged =
          nextSong != null &&
          _previousSong != null &&
          _previousSong!.id != nextSong.id;

      if (!songChanged && nextSong?.isExternal == true) {
        _maybeOpenExternalPlayer(nextSong);
      }

      _previousSong = nextSong;
    });

    _playerService.pendingMilestoneNotifier.addListener(_handleMilestone);
    _playerService.streakPopupNotifier.addListener(_handleStreakPopup);

    ref.listenManual<NavBarConfig>(navBarConfigProvider, (previous, next) {
      if (previous == null || !mounted) return;
      final currentPageIndex = ref.read(navigationIndexProvider);
      final oldOrder = _getPageOrder(previous);
      final newOrder = _getPageOrder(next);
      final oldPosition = oldOrder.indexWhere(
        (b) => b.pageIndex == currentPageIndex,
      );
      final newPosition = newOrder.indexWhere(
        (b) => b.pageIndex == currentPageIndex,
      );

      if (newPosition < 0) {
        // Current page was removed, jump to first page in new order
        if (_pageController.hasClients && newOrder.isNotEmpty) {
          _lastHapticPage = 0;
          _pageController.jumpToPage(0);
          ref
              .read(navigationIndexProvider.notifier)
              .setIndex(newOrder[0].pageIndex);
        }
        return;
      }

      if (oldPosition != newPosition && _pageController.hasClients) {
        _lastHapticPage = newPosition;
        _pageController.jumpToPage(newPosition);
        ref.read(navigationIndexProvider.notifier).setIndex(currentPageIndex);
      }
    });

    _navigationIndexSubscription = ref.listenManual<int>(
      navigationIndexProvider,
      (previous, next) {
        if (!mounted) {
          return;
        }

        void animateToTab() {
          if (!_pageController.hasClients) {
            return;
          }

          final config = ref.read(navBarConfigProvider);
          final pageOrder = _getPageOrder(config);
          final position = pageOrder.indexWhere((b) => b.pageIndex == next);
          if (position == -1) return;

          final currentPage =
              (_pageController.page ?? _pageController.initialPage.toDouble())
                  .round();
          if (currentPage == position) {
            return;
          }

          _programmaticPageTarget = position;
          _lastHapticPage = position;
          if (AppConstants.animationNormal == Duration.zero) {
            _pageController.jumpToPage(position);
          } else {
            _pageController.animateToPage(
              position,
              duration: AppConstants.animationNormal,
              curve: Curves.easeOutCubic,
            );
          }
        }

        if (_pageController.hasClients) {
          animateToTab();
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              animateToTab();
            }
          });
        }
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _maybeOpenExternalPlayer(ref.read(currentSongProvider));
      _refreshLibraryDeletions();
      ref.read(updateCheckProvider.notifier).refreshIfOnline();
      ref.read(autoLibrarySyncServiceProvider);

      final tutorialState = ref.read(tutorialProvider);
      if (tutorialState.autoStartPending && !tutorialState.active) {
        ref.read(tutorialProvider.notifier).start();
      }

      _maybeShowWhatsNew();
      unawaited(_playerService.recordActivityDayAndCheckMilestones());
    });

    _playerService.playbackDesyncedNotifier.addListener(
      _onPlaybackDesyncChanged,
    );

    ref.listenManual<AsyncValue<int>>(
      libraryWarmupProvider,
      _onWarmupChanged,
    );

    ref.listenManual<AppPreferences>(appPreferencesProvider, (previous, next) {
      if (!mounted) return;
      // Restart idle timer whenever preferences change so that enabling
      // auto-collapse or changing the timeout takes effect immediately.
      _startIdleTimer();
    });

    _startIdleTimer();
  }

  void _refreshLibraryDeletions() {
    unawaited(_refreshLibraryDeletionsAsync());
  }

  Future<void> _refreshLibraryDeletionsAsync() async {
    try {
      final scannerService = LibraryScannerService();
      await scannerService.refreshDeletions();
      if (mounted) {
        ref.invalidate(songsProvider);
        ref.invalidate(musicFoldersProvider);
      }
    } catch (e) {
      devLog('Library deletion refresh failed: $e');
    }
  }

  void _handleMilestone() {
    final milestone = _playerService.pendingMilestoneNotifier.value;
    if (milestone == null || !mounted) return;

    _playerService.pendingMilestoneNotifier.value = null;
    final milestoneService = MilestoneService();
    unawaited(_showMilestoneDialog(milestone, milestoneService));
  }

  Future<void> _showMilestoneDialog(
    MilestoneType milestone,
    MilestoneService service,
  ) async {
    final next = await service.getNextMilestone();
    if (!mounted) return;

    await showFlickDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Milestone',
      builder: (context) => MilestoneCard(
        milestone: milestone,
        nextMilestone: next.next,
        nextRemaining: next.next == null ? null : next.remaining,
        onSupportTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SupportFlickScreen()),
          );
        },
      ),
    );
  }

  void _handleStreakPopup() {
    final streak = _playerService.streakPopupNotifier.value;
    if (streak == null || streak < 1 || !mounted) return;
    _playerService.streakPopupNotifier.value = null;
    showFlickDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Day streak',
      builder: (context) => StreakPopup(
        streak: streak,
        onSnooze: () => MilestoneService().snoozeStreakPopup(),
      ),
    );
  }

  void _maybeShowWhatsNew() {
    if (!mounted) return;
    if (!ref.read(onboardingCompletedProvider)) {
      return;
    }

    // Wait for the AppPreferencesNotifier to publish its loaded state. The
    // listener fires when the real SharedPreferences values replace the
    // default values, which is the moment we can decide whether a "What's
    // New" sheet should appear.
    _appPreferencesSubscription = ref.listenManual<AppPreferences>(
      appPreferencesProvider,
      (previous, next) {
        if (!mounted) return;
        final notifier = ref.read(whatsNewProvider.notifier);
        notifier.evaluate();
        final pending = ref.read(whatsNewProvider).pendingEntry;
        if (pending == null) {
          return;
        }

        // Persist the dismissal before showing so a force-quit between now
        // and the user actually tapping "Got it" doesn't re-trigger on the
        // next launch.
        unawaited(notifier.markCurrentVersionSeen());
        unawaited(WhatsNewBottomSheet.show(context, entry: pending));
      },
    );
  }

  void _onPlaybackDesyncChanged() {
    if (!mounted) return;
    final desynced = _playerService.playbackDesyncedNotifier.value;
    if (!desynced) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      return;
    }

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Playback desynced'),
        duration: const Duration(days: 1),
        action: SnackBarAction(
          label: 'Sync',
          onPressed: () {
            _playerService.syncNow();
          },
        ),
      ),
    );
  }

  void _onWarmupChanged(AsyncValue<int>? previous, AsyncValue<int> next) {
    if (!mounted) return;
    final count = next.value ?? 0;
    final prevCount = previous?.value ?? 0;
    if (count == prevCount) return;

    final messenger = ScaffoldMessenger.of(context);
    if (count <= 0) {
      if (prevCount > 0) {
        messenger.clearSnackBars();
      }
      return;
    }

    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Finishing metadata for $count song${count == 1 ? '' : 's'}…',
        ),
        duration: const Duration(days: 1),
        action: SnackBarAction(
          label: 'Speed up',
          onPressed: () {
            final bg = ref.read(backgroundMetadataServiceProvider);
            unawaited(bg?.extractPendingMetadata());
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cancelIdleTimer();
    _playerService.playbackDesyncedNotifier.removeListener(
      _onPlaybackDesyncChanged,
    );
    _playerService.pendingMilestoneNotifier.removeListener(_handleMilestone);
    _playerService.streakPopupNotifier.removeListener(_handleStreakPopup);
    WidgetsBinding.instance.removeObserver(this);
    _navBarVisibilitySubscription.close();
    _navBarAlwaysVisibleSubscription.close();
    _currentSongSubscription.close();
    _navigationIndexSubscription.close();
    _widgetSyncSubscription.close();
    _appPreferencesSubscription?.close();
    unawaited(_widgetIntentHandler.detach());
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    _navBarAnimationController.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    if (_programmaticPageTarget != null || !_pageController.hasClients) return;
    final page = _pageController.page;
    if (page == null) return;
    final rounded = page.round();
    if (rounded != _lastHapticPage && (page - rounded).abs() <= 0.35) {
      _lastHapticPage = rounded;
      AppHaptics.selection();
    }
  }

  void _startIdleTimer() {
    _cancelIdleTimer();
    final appPreferences = ref.read(appPreferencesProvider);
    if (!appPreferences.bottomBarAutoCollapseEnabled) return;
    if (!ref.read(navBarVisibleProvider)) return;

    _idleTimer = Timer(
      Duration(seconds: appPreferences.bottomBarAutoCollapseSeconds),
      () {
        if (mounted) {
          setState(() {
            _isBottomBarCollapsed = true;
          });
        }
      },
    );
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _onUserInteraction() {
    if (_isBottomBarCollapsed) {
      setState(() {
        _isBottomBarCollapsed = false;
      });
    }
    _startIdleTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _cancelIdleTimer();
      unawaited(ref.read(playerServiceProvider).persistLastPlayed());
      unawaited(WidgetSyncService.instance.pushKilled());
      unawaited(ref.read(playerServiceProvider).onAppResumed());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _cancelIdleTimer();
      ref.read(autoLibrarySyncServiceProvider).notifyPaused();
      unawaited(ref.read(playerServiceProvider).persistLastPlayed());
      unawaited(WidgetSyncService.instance.pushPaused());
      unawaited(ref.read(playerServiceProvider).onAppPaused());

      // Attempt to scrobble the current track before the app suspends.
      // Only fire if playback is not active — audio apps often keep playing
      // in the background, so treat this as a true "end" only when paused.
      final playerState = ref.read(playerProvider);
      final song = playerState.currentSong;
      if (song != null && !song.isExternal && !playerState.isPlaying) {
        final notifier = ref.read(playerProvider.notifier);
        ref
            .read(lastFmScrobbleProvider.notifier)
            .onTrackEnded(
              artist: song.artist,
              track: song.title,
              album: song.album,
              albumArtist: null,
              listenedSeconds: notifier.accumulatedListenSeconds,
              trackDurationSeconds: playerState.duration.inSeconds,
            );
        ref
            .read(listenBrainzScrobbleProvider.notifier)
            .onTrackEnded(
              artist: song.artist,
              track: song.title,
              album: song.album,
              albumArtist: null,
              listenedSeconds: notifier.accumulatedListenSeconds,
              trackDurationSeconds: playerState.duration.inSeconds,
            );
      }
    }
    if (state == AppLifecycleState.resumed) {
      _startIdleTimer();
      unawaited(ref.read(playerServiceProvider).onAppResumed());
      ref.read(updateCheckProvider.notifier).refreshIfOnline();
      ref.read(lastFmScrobbleQueueProvider).flush().catchError((e) {
        devLog('[LastFm] queue flush on resume failed: $e');
      });
      ref.read(listenbrainzScrobbleQueueProvider).flush().catchError((e) {
        devLog('[ListenBrainz] queue flush on resume failed: $e');
      });
      ref.read(autoLibrarySyncServiceProvider).notifyResumed();
    }
  }

  void _onNavBarVisibilityChanged(bool isVisible) {
    final separated = ref.read(appPreferencesProvider).separateMiniPlayerFromNavBar;
    if (separated) {
      if (_navBarAnimationController.isAnimating ||
          _navBarAnimationController.value != 0) {
        _navBarAnimationController.reverse();
      }
      return;
    }
    if (isVisible) {
      _navBarAnimationController.reverse();
    } else {
      _navBarAnimationController.forward();
    }
  }

  void _maybeOpenExternalPlayer(Song? song) {
    if (song?.isExternal != true) {
      return;
    }
    if (!ref.read(isPlayingProvider) || NavigationHelper.isFullPlayerOpen) {
      return;
    }

    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted || NavigationHelper.isFullPlayerOpen || song == null) {
        return;
      }
      NavigationHelper.navigateToFullPlayer(
        context,
        heroTag: 'external_${song.id}',
      );
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final alwaysVisible = ref.read(navBarAlwaysVisibleProvider);
    if (alwaysVisible) {
      if (!ref.read(navBarVisibleProvider)) {
        ref.read(navBarVisibleProvider.notifier).setVisible(true);
      }
      return false;
    }

    if (notification is UserScrollNotification) {
      final direction = notification.direction;
      final currentVisibility = ref.read(navBarVisibleProvider);

      if (direction == ScrollDirection.reverse && currentVisibility) {
        ref.read(navBarVisibleProvider.notifier).setVisible(false);
      } else if (direction == ScrollDirection.forward && !currentVisibility) {
        ref.read(navBarVisibleProvider.notifier).setVisible(true);
      }
    }
    return false;
  }

  void _handleBackPress(bool didPop, dynamic result) {
    if (didPop) return;

    // Back events only reach the root navigator; detail screens pushed on
    // the nested tab navigator must be popped here manually.
    final nested = nestedNavigatorKey.currentState;
    if (nested != null && nested.canPop()) {
      nested.pop();
      return;
    }

    final now = DateTime.now();
    if (_lastBackPressTime == null ||
        now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Press back again to exit'),
            duration: Duration(seconds: 2),
          ),
        );
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = ref.watch(backgroundColorProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handleBackPress,
      child: AdaptiveColorProvider(
        backgroundColor: backgroundColor,
        child: Scaffold(
          backgroundColor: AppColors.background,
          extendBody: true,
          body: NotificationListener<ScrollNotification>(
            onNotification: _handleScrollNotification,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _onUserInteraction(),
              onPointerMove: (_) => _onUserInteraction(),
              child: Stack(
                children: [
                // Base Gradient
                Container(
                  decoration: const BoxDecoration(
                    gradient: AppColors.backgroundGradient,
                  ),
                ),

                // Persistent Background - always on for all bottom-bar screens
                Positioned.fill(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final currentSong = ref.watch(currentSongProvider);
                      return AmbientBackground(song: currentSong);
                    },
                  ),
                ),

                // Nested navigator: tabs + detail screens below the bar.
                Positioned.fill(
                  child: Builder(
                    builder: (nestedContext) {
                      final mq = MediaQuery.of(nestedContext);
                      final inflated = mq.copyWith(
                        padding: mq.padding.copyWith(
                          bottom: mq.padding.bottom + _kNestedBarClearance,
                        ),
                        viewPadding: mq.viewPadding.copyWith(
                          bottom:
                              mq.viewPadding.bottom + _kNestedBarClearance,
                        ),
                      );
                      return MediaQuery(
                        data: inflated,
                        child: Navigator(
                          key: nestedNavigatorKey,
                          initialRoute: '/',
                          onGenerateRoute: (settings) {
                            if (settings.name == '/') {
                              return PageRouteBuilder<void>(
                                settings: settings,
                                pageBuilder: (routeContext, _, __) =>
                                    MediaQuery.removePadding(
                                  context: routeContext,
                                  removeBottom: true,
                                  child: Consumer(
                                    builder: (context, ref, _) {
                                      final currentIdx =
                                          ref.watch(navigationIndexProvider);
                                      final cfg =
                                          ref.watch(navBarConfigProvider);
                                      final order = _getPageOrder(cfg);
                                      return PageView(
                                        controller: _pageController,
                                        physics:
                                            const ClampingScrollPhysics(),
                                        onPageChanged: (position) {
                                          final currentConfig = ref.read(
                                              navBarConfigProvider);
                                          final currentOrder =
                                              _getPageOrder(currentConfig);
                                          if (position < 0 ||
                                              position >=
                                                  currentOrder.length) {
                                            return;
                                          }
                                          if (_programmaticPageTarget == null &&
                                              position != _lastHapticPage) {
                                            AppHaptics.selection();
                                          }
                                          _lastHapticPage = position;
                                          final enabledCount = currentConfig
                                              .orderedButtons.length;
                                          if (position >= enabledCount) {
                                            if (_programmaticPageTarget ==
                                                position) {
                                              _programmaticPageTarget = null;
                                              final pageIndex =
                                                  currentOrder[position]
                                                      .pageIndex;
                                              if (ref.read(
                                                      navigationIndexProvider) !=
                                                  pageIndex) {
                                                ref
                                                    .read(
                                                        navigationIndexProvider
                                                            .notifier)
                                                    .setIndex(pageIndex);
                                              }
                                              return;
                                            }
                                            if (_programmaticPageTarget !=
                                                null) {
                                              return;
                                            }
                                            final pageIndex =
                                                currentOrder[position].pageIndex;
                                            if (ref.read(
                                                    navigationIndexProvider) !=
                                                pageIndex) {
                                              ref
                                                  .read(navigationIndexProvider
                                                      .notifier)
                                                  .setIndex(pageIndex);
                                            }
                                            return;
                                          }
                                          if (_programmaticPageTarget ==
                                              position) {
                                            _programmaticPageTarget = null;
                                          }
                                          final pageIndex =
                                              currentOrder[position].pageIndex;
                                          if (ref.read(
                                                  navigationIndexProvider) !=
                                              pageIndex) {
                                            ref
                                                .read(navigationIndexProvider
                                                    .notifier)
                                                .setIndex(pageIndex);
                                          }
                                        },
                                        children: order.map((button) {
                                          return _buildTab(
                                            tabIndex: button.pageIndex,
                                            currentIndex: currentIdx,
                                            child: _buildScreen(button),
                                          );
                                        }).toList(),
                                      );
                                    },
                                  ),
                                ),
                                transitionDuration: Duration.zero,
                              );
                            }
                            return null;
                          },
                        ),
                      );
                    },
                  ),
                ),

                // Unified Bottom Bar (Mini Player + Navigation)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: RepaintBoundary(
                    child: SlideTransition(
                      position: _navBarSlideAnimation,
                      child: _buildUnifiedBottomBar(),
                    ),
                  ),
                ),

                // Floating island mini-player (draggable pill)
                const FloatingMiniPlayer(),

                // Floating scan/preload progress pill (overlay minimized)
                const Positioned(
                  left: AppConstants.spacingMd,
                  right: AppConstants.spacingMd,
                  bottom: 104,
                  child: FloatingScanProgress(),
                ),

                // Interactive tutorial overlay
                const Positioned.fill(child: TutorialOverlay()),

                // USB DAC attach → bit-perfect switch prompt
                const UsbBitPerfectPrompt(),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }

  List<NavBarButton> _getPageOrder(NavBarConfig config) {
    final disabledEssentials = [
      NavBarButton.menu,
      NavBarButton.songs,
      NavBarButton.settings,
    ].where((b) => !config.orderedButtons.contains(b));
    return [...config.orderedButtons, ...disabledEssentials];
  }

  Widget _buildScreen(NavBarButton button) {
    return switch (button) {
      NavBarButton.menu => MenuScreen(
        key: const ValueKey('menu'),
        onNavigateToTab: (index) {
          ref.read(navigationIndexProvider.notifier).setIndex(index);
        },
      ),
      NavBarButton.songs => SongsScreen(
        key: const ValueKey('songs'),
        onNavigationRequested: (index) {
          ref.read(navigationIndexProvider.notifier).setIndex(index);
        },
      ),
      NavBarButton.settings => const SettingsScreen(key: ValueKey('settings')),
      NavBarButton.albums => const AlbumsScreen(key: ValueKey('albums')),
      NavBarButton.artists => const ArtistsScreen(key: ValueKey('artists')),
      NavBarButton.folders => const FoldersScreen(key: ValueKey('folders')),
      NavBarButton.playlists => const PlaylistsScreen(
        key: ValueKey('playlists'),
      ),
      NavBarButton.favorites => const FavoritesScreen(
        key: ValueKey('favorites'),
      ),
      NavBarButton.search => const SearchScreen(key: ValueKey('search')),
    };
  }

  Widget _buildTab({
    required int tabIndex,
    required int currentIndex,
    required Widget child,
  }) {
    return RepaintBoundary(
      child: AmbientBackgroundScope(
        child: TickerMode(enabled: currentIndex == tabIndex, child: child),
      ),
    );
  }

  Widget _buildUnifiedBottomBar() {
    final currentIndex = ref.watch(navigationIndexProvider);
    final navBarConfig = ref.watch(navBarConfigProvider);
    final appPrefs = ref.watch(appPreferencesProvider);
    final separated = appPrefs.separateMiniPlayerFromNavBar;
    final alwaysVisible = ref.watch(navBarAlwaysVisibleProvider);
    final navBarVisible = ref.watch(navBarVisibleProvider);
    final scrollHidden = separated && !alwaysVisible && !navBarVisible;
    final collapsed = _isBottomBarCollapsed || scrollHidden;

    return TutorialTargetAnchor(
      target: TutorialTarget.navBar,
      child: FlickNavBar(
        currentIndex: currentIndex,
        config: navBarConfig,
        collapsed: collapsed,
        onTap: (index) {
          final nested = nestedNavigatorKey.currentState;
          if (nested != null && nested.canPop()) {
            nested.popUntil((route) => route.isFirst);
          }
          if (ref.read(navigationIndexProvider) != index) {
            ref.read(navigationIndexProvider.notifier).setIndex(index);
          } else if (nested != null && nested.canPop()) {
            nested.popUntil((route) => route.isFirst);
          }
        },
        onBottomBarSettings: () {
          NavigationHelper.pushOnRoot(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const BottomBarSettingsScreen(),
            ),
          );
        },
        showMiniPlayer: true,
        separateMiniPlayer: separated,
        miniPlayerWidget: TutorialTargetAnchor(
          target: TutorialTarget.miniPlayer,
          child: _EmbeddedMiniPlayer(
            collapsed: collapsed,
            matchNavBarWidth: separated && !collapsed,
          ),
        ),
      ),
    );
  }
}

/// Embedded mini player widget that uses Riverpod for state.
class _EmbeddedMiniPlayer extends ConsumerStatefulWidget {
  final bool collapsed;
  final bool matchNavBarWidth;

  const _EmbeddedMiniPlayer({
    this.collapsed = false,
    this.matchNavBarWidth = false,
  });

  @override
  ConsumerState<_EmbeddedMiniPlayer> createState() =>
      _EmbeddedMiniPlayerState();
}

class _EmbeddedMiniPlayerState extends ConsumerState<_EmbeddedMiniPlayer> {
  bool _showVisualizer = false;
  int _songChangeDirection = 0; // 1=next, -1=previous, 0=none
  String? _currentSongId;

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() <= 300) return;

    final swipeAction = ref.read(appPreferencesProvider).miniPlayerSwipeAction;
    if (swipeAction == 'switchSongs') {
      if (velocity < 0) {
        _songChangeDirection = -1;
        ref.read(playerProvider.notifier).next();
      } else {
        _songChangeDirection = 1;
        ref.read(playerProvider.notifier).previous(allowRestart: false);
      }
    } else {
      setState(() {
        _showVisualizer = !_showVisualizer;
      });
    }
  }

  Widget _buildSongInfo(Song currentSong) {
    final previousSongId = _currentSongId;
    final newSongId = currentSong.id;
    _currentSongId = newSongId;

    final songDirection = _songChangeDirection;
    _songChangeDirection = 0;

    return AnimatedSwitcher(
      key: const ValueKey('mini_player_song_info'),
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final key = (child.key as ValueKey).value as String;
        final isNewSong = key == 'mini_player_song_$newSongId';
        final isOldSong =
            previousSongId != null && key == 'mini_player_song_$previousSongId';

        if (!isNewSong && !isOldSong) {
          return FadeTransition(opacity: animation, child: child);
        }

        final isNext = songDirection == 1;
        final isPrevious = songDirection == -1;

        final slideBegin = Offset(
          isNext
              ? (isNewSong ? 0.5 : -0.5)
              : isPrevious
                  ? (isNewSong ? -0.5 : 0.5)
                  : 0,
          0,
        );

        return SlideTransition(
          position: Tween<Offset>(begin: slideBegin, end: Offset.zero)
              .animate(animation),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(animation),
            child: FadeTransition(
              opacity: Tween<double>(begin: 0.0, end: 1.0).animate(animation),
              child: child,
            ),
          ),
        );
      },
      child: Row(
        key: ValueKey('mini_player_song_$newSongId'),
        mainAxisSize: MainAxisSize.max,
        children: [
            // Album Art
            Hero(
              tag: 'mini_player_art',
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                  ),
                  child: currentSong.albumArt != null
                      ? CachedImageWidget(
                          imagePath: currentSong.albumArt!,
                          audioSourcePath: currentSong.filePath,
                          fit: BoxFit.cover,
                          useThumbnail: true,
                          thumbnailWidth: 128,
                          thumbnailHeight: 128,
                          placeholder: const ColoredBox(
                            color: AppColors.surface,
                            child: FlickArtworkPlaceholder(size: 26, opacity: 0.9),
                          ),
                          errorWidget: const ColoredBox(
                            color: AppColors.surface,
                            child: FlickArtworkPlaceholder(size: 26, opacity: 0.9),
                          ),
                        )
                      : const ColoredBox(
                          color: AppColors.surface,
                          child: FlickArtworkPlaceholder(size: 26, opacity: 0.9),
                        ),
                ),
              ),
            ),

            const SizedBox(width: 12),

            // Song Info
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    currentSong.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: context.adaptiveTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currentSong.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      fontSize: 12,
                      color: context.adaptiveTextSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            // Play/Pause Button
            Consumer(
              builder: (context, ref, _) {
                final isPlaying = ref.watch(isPlayingProvider);
                return IconButton(
                  onPressed: () =>
                      ref.read(playerProvider.notifier).togglePlayPause(),
                  icon: Icon(
                    isPlaying ? LucideIcons.pause : LucideIcons.play,
                    color: context.adaptiveTextPrimary,
                    size: 20,
                  ),
                );
              },
            ),
            const SizedBox(width: 4),
          ],
        ),
      );
  }

  Widget _buildVisualizer() {
    final appPrefs = ref.watch(appPreferencesProvider);
    final albumColor = ref.watch(albumDominantColorSyncProvider);
    final playerService = ref.read(playerServiceProvider);
    final reducedMotion = MediaQuery.of(context).disableAnimations;

    return SizedBox.expand(
      key: const ValueKey('mini_player_visualizer'),
      child: AudioVisualizer(
        playerService: playerService,
        animationStyle: appPrefs.visualizerAnimationStyle,
        frequencyMode: appPrefs.visualizerFrequencyMode,
        movementMode: appPrefs.visualizerMovementMode,
        albumColor: albumColor,
        enabled: appPrefs.visualizerEnabled && !reducedMotion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentSong = ref.watch(currentSongProvider);

    if (currentSong == null) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        FocusScope.of(context).unfocus();
        final result = await NavigationHelper.navigateToFullPlayer(
          context,
          heroTag: 'mini_player_art',
        );
        if (result != null && context.mounted) {
          ref.read(navigationIndexProvider.notifier).setIndex(result);
        }
      },
      onHorizontalDragStart: (_) {},
      onHorizontalDragUpdate: (_) {},
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: AnimatedContainer(
        duration: AppConstants.animationNormal,
        margin: EdgeInsets.fromLTRB(
          widget.matchNavBarWidth
              ? context.scaleSize(AppConstants.spacingLg)
              : 12,
          12,
          widget.matchNavBarWidth
              ? context.scaleSize(AppConstants.spacingLg)
              : 12,
          widget.collapsed ? 12 : 8,
        ),
        height: 56,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfaceLight.withValues(alpha: 0.86),
              AppColors.surface.withValues(alpha: 0.94),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color.fromARGB(
              108,
              255,
              255,
              255,
            ).withValues(alpha: 0.45),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              // Progress Bar at bottom
              Consumer(
                builder: (context, ref, _) {
                  final progress = ref.watch(progressProvider);
                  if (progress == 0) return const SizedBox.shrink();

                  return Align(
                    alignment: Alignment.bottomLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress,
                      child: Container(height: 2, color: AppColors.accent),
                    ),
                  );
                },
              ),

              // Song info or visualizer
              AnimatedSwitcher(
                duration: AppConstants.animationNormal,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                transitionBuilder: (child, animation) {
                  final isEntering = child.key == const ValueKey('mini_player_visualizer');
                  final offset = isEntering
                      ? const Offset(0.3, 0)
                      : const Offset(-0.3, 0);
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: offset,
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    )),
                    child: FadeTransition(
                      opacity: animation,
                      child: child,
                    ),
                  );
                },
                child: _showVisualizer
                    ? _buildVisualizer()
                    : _buildSongInfo(currentSong),
              ),

            ],
          ),
        ),
      ),
    );
  }
}

class _RootRouter extends ConsumerWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboardingComplete = ref.watch(onboardingCompletedProvider);
    final appPreferences = ref.watch(appPreferencesProvider);

    // Apply animation and haptic preferences globally.
    // When the OS requests reduced motion (e.g. Accessibility "remove
    // animations"), that flag wins over the in-app preference so the app
    // settles into a static state like native Android apps do.
    final systemReducedMotion = MediaQuery.of(context).disableAnimations;
    final animationsEnabled =
        appPreferences.animationsEnabled && !systemReducedMotion;
    AppConstants.setAnimationsEnabled(animationsEnabled);
    AppHaptics.setEnabled(appPreferences.hapticsEnabled);

    final child = onboardingComplete
        ? const MainShell()
        : const OnboardingScreen();

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: !animationsEnabled),
      child: child,
    );
  }
}
