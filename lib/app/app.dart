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
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/widgets/navigation/flick_nav_bar.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

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
    with SingleTickerProviderStateMixin {
  // Animation controller for smoother nav bar transitions
  late final AnimationController _navBarAnimationController;
  late final Animation<Offset> _navBarSlideAnimation;

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _navBarAnimationController.dispose();
    super.dispose();
  }

  void _onNavBarVisibilityChanged(bool isVisible) {
    if (isVisible) {
      _navBarAnimationController.reverse();
    } else {
      _navBarAnimationController.forward();
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      final direction = notification.direction;
      final currentVisibility = ref.read(navBarVisibleProvider);

      if (direction == ScrollDirection.forward && currentVisibility) {
        ref.read(navBarVisibleProvider.notifier).setVisible(false);
      } else if (direction == ScrollDirection.reverse && !currentVisibility) {
        ref.read(navBarVisibleProvider.notifier).setVisible(true);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(navigationIndexProvider);
    final backgroundColor = ref.watch(backgroundColorProvider);

    // Listen to nav bar visibility changes and animate
    ref.listen<bool>(navBarVisibleProvider, (previous, next) {
      _onNavBarVisibilityChanged(next);
    });

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
                    final currentSong = ref.watch(currentSongProvider);
                    return AmbientBackground(song: currentSong);
                  },
                ),
              ),

              // Main content area with IndexedStack for faster tab switching
              IndexedStack(
                index: currentIndex,
                children: [
                  MenuScreen(
                    key: const ValueKey('menu'),
                    onNavigateToTab: (index) {
                      ref
                          .read(navigationIndexProvider.notifier)
                          .setIndex(index);
                    },
                  ),
                  SongsScreen(
                    key: const ValueKey('songs'),
                    onNavigationRequested: (index) {
                      ref
                          .read(navigationIndexProvider.notifier)
                          .setIndex(index);
                    },
                  ),
                  const SettingsScreen(key: ValueKey('settings')),
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
        final result = await Navigator.of(context).push<int>(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                const FullPlayerScreen(heroTag: 'mini_player_art'),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  const begin = Offset(0.0, 1.0);
                  const end = Offset.zero;
                  const curve = Curves.easeOutCubic;

                  var tween = Tween(
                    begin: begin,
                    end: end,
                  ).chain(CurveTween(curve: curve));

                  return SlideTransition(
                    position: animation.drive(tween),
                    child: child,
                  );
                },
            transitionDuration: const Duration(milliseconds: 300),
            opaque: false,
            barrierColor: Colors.black,
          ),
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
          color: AppColors.glassBackground.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.glassBorder.withValues(alpha: 0.2),
          ),
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
                          style: const TextStyle(
                            fontFamily: 'ProductSans',
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          currentSong.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 12,
                            color: AppColors.textTertiary,
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
                          color: AppColors.textPrimary,
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
