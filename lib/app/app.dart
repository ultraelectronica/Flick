import 'dart:async';

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
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/widgets/navigation/flick_nav_bar.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/models/song.dart';

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
      home: const MainShell(),
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

  // Track previous song to detect changes
  Song? _previousSong;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Seed _previousSong from the already-restored state so the auto-navigate
    // listener doesn't treat the restored song as "new" on cold start.
    _previousSong = ref.read(currentSongProvider);
    final initialIndex = ref.read(navigationIndexProvider);
    _pageController = PageController(initialPage: initialIndex);
    _navBarAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _navBarSlideAnimation =
        Tween<Offset>(begin: Offset.zero, end: const Offset(0, 1.15)).animate(
          CurvedAnimation(
            parent: _navBarAnimationController,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeOutCubic,
          ),
        );

    _navBarVisibilitySubscription = ref.listenManual<bool>(
      navBarVisibleProvider,
      (previous, next) {
        _onNavBarVisibilityChanged(next);
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
          _previousSong != null &&          // must have had a song before
          _previousSong!.id != nextSong.id; // and it must have changed

      if (songChanged && context.mounted) {
        final isPlaying = ref.read(isPlayingProvider);
        if (!isPlaying) {
          // Song changed but not playing yet — don't auto-navigate.
          _previousSong = nextSong;
          return;
        }
        if (NavigationHelper.isFullPlayerOpen) {
          _previousSong = nextSong;
          return;
        }
        final song = nextSong;
        Future.delayed(const Duration(milliseconds: 100), () {
          if (context.mounted) {
            NavigationHelper.navigateToFullPlayer(
              context,
              heroTag: 'auto_nav_${song.id}',
            );
          }
        });
      }
      _previousSong = nextSong;
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

          final currentPage =
              (_pageController.page ?? _pageController.initialPage.toDouble())
                  .round();
          if (currentPage == next) {
            return;
          }

          _pageController.animateToPage(
            next,
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
          );
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _navBarVisibilitySubscription.close();
    _navBarAlwaysVisibleSubscription.close();
    _currentSongSubscription.close();
    _navigationIndexSubscription.close();
    _pageController.dispose();
    _navBarAnimationController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(playerServiceProvider).persistLastPlayed());

      // Attempt to scrobble the current track before the app suspends.
      // Only fire if playback is not active — audio apps often keep playing
      // in the background, so treat this as a true "end" only when paused.
      final playerState = ref.read(playerProvider);
      final song = playerState.currentSong;
      if (song != null && !playerState.isPlaying) {
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
      }
    }
    if (state == AppLifecycleState.resumed) {
      ref.read(lastFmScrobbleQueueProvider).flush().catchError((e) {
        debugPrint('[LastFm] queue flush on resume failed: $e');
      });
    }
  }

  void _onNavBarVisibilityChanged(bool isVisible) {
    if (isVisible) {
      _navBarAnimationController.reverse();
    } else {
      _navBarAnimationController.forward();
    }
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

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(navigationIndexProvider);
    final backgroundColor = ref.watch(backgroundColorProvider);

    return AdaptiveColorProvider(
      backgroundColor: backgroundColor,
      child: Scaffold(
        backgroundColor: AppColors.background,
        extendBody: true,
        body: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: Stack(
            children: [
              // Base Gradient
              Container(
                decoration: const BoxDecoration(
                  gradient: AppColors.backgroundGradient,
                ),
              ),

              // Persistent Background - uses Riverpod
              Positioned.fill(
                child: Consumer(
                  builder: (context, ref, _) {
                    final ambientBackgroundEnabled = ref.watch(
                      ambientBackgroundEnabledProvider,
                    );
                    final currentSong = ref.watch(currentSongProvider);
                    return ambientBackgroundEnabled
                        ? AmbientBackground(song: currentSong)
                        : const SizedBox.shrink();
                  },
                ),
              ),

              // Main content area with swipeable page navigation.
              PageView(
                controller: _pageController,
                physics: const ClampingScrollPhysics(),
                onPageChanged: (index) {
                  if (ref.read(navigationIndexProvider) != index) {
                    ref.read(navigationIndexProvider.notifier).setIndex(index);
                  }
                },
                children: [
                  _buildTab(
                    tabIndex: 0,
                    currentIndex: currentIndex,
                    child: MenuScreen(
                      key: const ValueKey('menu'),
                      onNavigateToTab: (index) {
                        ref
                            .read(navigationIndexProvider.notifier)
                            .setIndex(index);
                      },
                    ),
                  ),
                  _buildTab(
                    tabIndex: 1,
                    currentIndex: currentIndex,
                    child: SongsScreen(
                      key: const ValueKey('songs'),
                      onNavigationRequested: (index) {
                        ref
                            .read(navigationIndexProvider.notifier)
                            .setIndex(index);
                      },
                    ),
                  ),
                  _buildTab(
                    tabIndex: 2,
                    currentIndex: currentIndex,
                    child: const SettingsScreen(key: ValueKey('settings')),
                  ),
                ],
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTab({
    required int tabIndex,
    required int currentIndex,
    required Widget child,
  }) {
    return RepaintBoundary(
      child: TickerMode(enabled: currentIndex == tabIndex, child: child),
    );
  }

  Widget _buildUnifiedBottomBar() {
    final currentIndex = ref.watch(navigationIndexProvider);

    return FlickNavBar(
      currentIndex: currentIndex,
      onTap: (index) {
        if (ref.read(navigationIndexProvider) != index) {
          ref.read(navigationIndexProvider.notifier).setIndex(index);
        }
      },
      showMiniPlayer: true,
      miniPlayerWidget: const _EmbeddedMiniPlayer(),
    );
  }
}

/// Embedded mini player widget that uses Riverpod for state.
class _EmbeddedMiniPlayer extends ConsumerWidget {
  const _EmbeddedMiniPlayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentSong = ref.watch(currentSongProvider);

    if (currentSong == null) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        final result = await NavigationHelper.navigateToFullPlayer(
          context,
          heroTag: 'mini_player_art',
        );
        // Navigate to the returned tab index if provided
        if (result != null && context.mounted) {
          ref.read(navigationIndexProvider.notifier).setIndex(result);
        }
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
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

              Row(
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
                                fit: BoxFit.cover,
                                useThumbnail: true,
                                thumbnailWidth: 128,
                                thumbnailHeight: 128,
                              )
                            : const Icon(
                                LucideIcons.music,
                                size: 22,
                                color: AppColors.textTertiary,
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
            ],
          ),
        ),
      ),
    );
  }
}
