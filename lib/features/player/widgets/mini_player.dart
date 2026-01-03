import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  final PlayerService _playerService = PlayerService();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Song?>(
      valueListenable: _playerService.currentSongNotifier,
      builder: (context, song, child) {
        if (song == null) {
          return const SizedBox.shrink();
        }

        return GestureDetector(
          onTap: () {
            Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    FullPlayerScreen(heroTag: 'song_art_${song.id}'),
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
                opaque: false, // Important for Hero
                barrierColor: Colors.black, // Or transparent
              ),
            );
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong, // Darker glass
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.glassBorder.withValues(alpha: 0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  // Progress Bar at bottom (optional, or background fill?)
                  // Let's keep it simple for now, maybe add a thin line at bottom later.
                  ValueListenableBuilder<Duration>(
                    valueListenable: _playerService.positionNotifier,
                    builder: (context, position, _) {
                      final duration = _playerService.durationNotifier.value;
                      if (duration.inMilliseconds == 0) {
                        return const SizedBox.shrink();
                      }
                      final progress =
                          position.inMilliseconds / duration.inMilliseconds;

                      return Align(
                        alignment: Alignment.bottomLeft,
                        child: FractionallySizedBox(
                          widthFactor: progress.clamp(0.0, 1.0),
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
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                            image: song.albumArt != null
                                ? DecorationImage(
                                    image: FileImage(File(song.albumArt!)),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: song.albumArt == null
                              ? const Icon(
                                  LucideIcons.music,
                                  size: 24,
                                  color: AppColors.textTertiary,
                                )
                              : null,
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
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'ProductSans',
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'ProductSans',
                                fontSize: 13,
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Controls
                      ValueListenableBuilder<bool>(
                        valueListenable: _playerService.isPlayingNotifier,
                        builder: (context, isPlaying, _) {
                          return IconButton(
                            onPressed: () => _playerService.togglePlayPause(),
                            icon: Icon(
                              isPlaying ? LucideIcons.pause : LucideIcons.play,
                              color: AppColors.textPrimary,
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
