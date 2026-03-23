import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/providers/lastfm_provider.dart';

/// Self-contained Last.fm connect/disconnect tile.
class LastFmSettingsTile extends ConsumerStatefulWidget {
  const LastFmSettingsTile({super.key});

  @override
  ConsumerState<LastFmSettingsTile> createState() => _LastFmSettingsTileState();
}

class _LastFmSettingsTileState extends ConsumerState<LastFmSettingsTile>
    with WidgetsBindingObserver {
  bool _awaitingCallback = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[LastFm] App lifecycle changed: $state, _awaitingCallback=$_awaitingCallback');
    if (state == AppLifecycleState.resumed && _awaitingCallback) {
      debugPrint('[LastFm] App resumed after auth, completing authentication');
      _awaitingCallback = false;
      _completeAuth();
    }
  }

  Future<void> _startAuth() async {
    debugPrint('[LastFm] _startAuth: Starting authentication flow');
    final auth = ref.read(lastFmAuthServiceProvider);

    // Check if API credentials are configured
    debugPrint('[LastFm] _startAuth: Checking API credentials');
    final hasCredentials = await auth.hasValidApiCredentials();
    debugPrint('[LastFm] _startAuth: Has valid credentials: $hasCredentials');
    
    if (!hasCredentials) {
      debugPrint('[LastFm] _startAuth: Missing credentials, showing error');
      _showError(
        'Please configure your Last.fm API key and shared secret first.',
      );
      return;
    }

    try {
      debugPrint('[LastFm] _startAuth: Calling getTokenAndLaunchAuth');
      await auth.getTokenAndLaunchAuth();
      debugPrint('[LastFm] _startAuth: Successfully launched auth, mounted=$mounted');
      
      if (mounted) {
        setState(() => _awaitingCallback = true);
        debugPrint('[LastFm] _startAuth: Set _awaitingCallback=true');
      }
    } catch (e, stackTrace) {
      debugPrint('[LastFm] _startAuth: ERROR - $e');
      debugPrint('[LastFm] _startAuth: Stack trace: $stackTrace');
      
      if (mounted) {
        // Provide more specific error message for network issues
        final errorMessage = e.toString().contains('SocketException') ||
                e.toString().contains('Failed host lookup')
            ? 'No internet connection. Please check your network and try again.'
            : 'Could not connect to Last.fm. Check your API credentials and try again.';
        
        _showError(errorMessage);
      } else {
        debugPrint('[LastFm] _startAuth: Widget not mounted, skipping error display');
      }
    }
  }

  Future<void> _completeAuth() async {
    debugPrint('[LastFm] _completeAuth: Starting token exchange');
    final auth = ref.read(lastFmAuthServiceProvider);
    try {
      await auth.exchangeTokenForSession();
      debugPrint('[LastFm] _completeAuth: Token exchange successful');
      ref.invalidate(lastFmSessionProvider);
      _showSuccess('Last.fm connected!');
    } catch (e, stackTrace) {
      debugPrint('[LastFm] _completeAuth: ERROR - $e');
      debugPrint('[LastFm] _completeAuth: Stack trace: $stackTrace');
      _showError(
        'Authorization failed. Make sure you approved access on Last.fm.',
      );
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppConstants.radiusLg),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: context.adaptiveTextTertiary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.warning_rounded,
                      color: Colors.red,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Disconnect Last.fm?',
                          style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                            color: context.adaptiveTextPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 24),

            // Content
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackgroundStrong,
                      borderRadius: BorderRadius.circular(
                        AppConstants.radiusMd,
                      ),
                      border: Border.all(
                        color: context.adaptiveTextTertiary.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: context.adaptiveTextSecondary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Your scrobbling history will remain on Last.fm, but Flick will stop sending scrobbles.',
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                              color: context.adaptiveTextSecondary,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            side: BorderSide(
                              color: context.adaptiveTextTertiary.withValues(alpha: 
                                0.3,
                              ),
                            ),
                            foregroundColor: context.adaptiveTextPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppConstants.radiusMd,
                              ),
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppConstants.radiusMd,
                              ),
                            ),
                          ),
                          child: const Text(
                            'Disconnect',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      return;
    }

    final auth = ref.read(lastFmAuthServiceProvider);
    await auth.disconnect();
    ref.invalidate(lastFmSessionProvider);
  }

  Future<void> _showApiKeyDialog({bool autoConnectAfterSave = false}) async {
    final auth = ref.read(lastFmAuthServiceProvider);
    final creds = await auth.getApiCredentials();

    final apiKeyController = TextEditingController(text: creds.apiKey ?? '');
    final sharedSecretController = TextEditingController(
      text: creds.sharedSecret ?? '',
    );
    bool obscureSecret = true;

    if (!mounted) return;

    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(ctx).scaffoldBackgroundColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppConstants.radiusLg),
                  ),
                ),
                child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: context.adaptiveTextTertiary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD51007).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.music_note,
                          color: Color(0xFFD51007),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Last.fm Configuration',
                              style: Theme.of(ctx).textTheme.titleLarge
                                  ?.copyWith(
                                    color: context.adaptiveTextPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Connect to scrobble your music',
                              style: Theme.of(ctx).textTheme.bodySmall
                                  ?.copyWith(
                                    color: context.adaptiveTextSecondary,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const Divider(height: 24),

                // Content
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Info section
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.glassBackgroundStrong,
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusMd,
                          ),
                          border: Border.all(
                            color: context.adaptiveTextTertiary.withValues(alpha:
                              0.1,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: context.adaptiveTextSecondary,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Get your API credentials',
                                    style: Theme.of(ctx).textTheme.bodyMedium
                                        ?.copyWith(
                                          color: context.adaptiveTextPrimary,
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  GestureDetector(
                                    onTap: () {
                                      launchUrl(
                                        Uri.parse(
                                          'https://www.last.fm/api/account/create',
                                        ),
                                        mode: LaunchMode.externalApplication,
                                      );
                                    },
                                    child: Text(
                                      'last.fm/api/account/create',
                                      style: TextStyle(
                                        color: context.adaptiveTextPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.open_in_new,
                              color: context.adaptiveTextTertiary,
                              size: 18,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // API Key field
                      Text(
                        'API Key',
                        style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                          color: context.adaptiveTextPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: apiKeyController,
                        style: TextStyle(color: context.adaptiveTextPrimary),
                        decoration: InputDecoration(
                          hintText: 'Enter your API key',
                          hintStyle: TextStyle(
                            color: context.adaptiveTextTertiary,
                          ),
                          filled: true,
                          fillColor: AppColors.glassBackgroundStrong,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppConstants.radiusMd,
                            ),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppConstants.radiusMd,
                            ),
                            borderSide: BorderSide(
                              color: context.adaptiveTextTertiary.withValues(alpha:
                                0.1,
                              ),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppConstants.radiusMd,
                            ),
                            borderSide: const BorderSide(
                              color: Color(0xFFD51007),
                              width: 2,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Shared Secret field
                      Text(
                        'Shared Secret',
                        style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                          color: context.adaptiveTextPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: sharedSecretController,
                        obscureText: obscureSecret,
                        style: TextStyle(color: context.adaptiveTextPrimary),
                        decoration: InputDecoration(
                          hintText: 'Enter your shared secret',
                          hintStyle: TextStyle(
                            color: context.adaptiveTextTertiary,
                          ),
                          filled: true,
                          fillColor: AppColors.glassBackgroundStrong,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppConstants.radiusMd,
                            ),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppConstants.radiusMd,
                            ),
                            borderSide: BorderSide(
                              color: context.adaptiveTextTertiary.withValues(alpha:
                                0.1,
                              ),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppConstants.radiusMd,
                            ),
                            borderSide: const BorderSide(
                              color: Color(0xFFD51007),
                              width: 2,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscureSecret
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              color: context.adaptiveTextSecondary,
                            ),
                            onPressed: () {
                              setState(
                                () => obscureSecret = !obscureSecret,
                              );
                            },
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Action buttons
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(ctx),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                side: BorderSide(
                                  color: context.adaptiveTextTertiary
                                      .withValues(alpha: 0.3),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppConstants.radiusMd,
                                  ),
                                ),
                              ),
                              child: Text(
                                'Cancel',
                                style: TextStyle(
                                  color: context.adaptiveTextSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: () async {
                                debugPrint('[LastFm] Save & Connect button pressed');
                                
                                if (apiKeyController.text.isEmpty ||
                                    sharedSecretController.text.isEmpty) {
                                  debugPrint('[LastFm] Empty credentials provided');
                                  _showError(
                                    'Please enter both API key and shared secret',
                                  );
                                  return;
                                }
                                
                                debugPrint('[LastFm] Saving credentials...');
                                await auth.setApiCredentials(
                                  apiKeyController.text,
                                  sharedSecretController.text,
                                );
                                debugPrint('[LastFm] Credentials saved, mounted=$mounted');
                                
                                if (mounted) {
                                  Navigator.pop(ctx);
                                  debugPrint('[LastFm] Dialog closed');
                                  
                                  _showSuccess(
                                    'Credentials saved successfully!',
                                  );
                                  
                                  if (autoConnectAfterSave && mounted) {
                                    debugPrint('[LastFm] Auto-connect enabled, waiting 300ms...');
                                    // Small delay to ensure dialog is fully closed
                                    await Future.delayed(
                                      const Duration(milliseconds: 300),
                                    );
                                    debugPrint('[LastFm] Delay complete, mounted=$mounted');
                                    
                                    if (mounted) {
                                      debugPrint('[LastFm] Calling _startAuth()');
                                      await _startAuth();
                                    } else {
                                      debugPrint('[LastFm] Widget unmounted, skipping auth');
                                    }
                                  }
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFD51007),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppConstants.radiusMd,
                                  ),
                                ),
                              ),
                              child: const Text(
                                'Save & Connect',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ],
            ),
          ),
            );
          },
        ),
      );
    } finally {
      apiKeyController.dispose();
      sharedSecretController.dispose();
    }
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showSuccess(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(lastFmSessionProvider);

    return sessionAsync.when(
      loading: () => _buildLoadingTile(context),
      error: (error, stackTrace) => _buildErrorTile(context),
      data: (session) {
        if (session != null) {
          return _buildConnectedTile(context, username: session.username);
        }
        return _buildDisconnectedTile(context);
      },
    );
  }

  Widget _buildLoadingTile(BuildContext context) {
    return _buildTileContainer(
      context,
      child: Row(
        children: [
          _buildLeadingIcon(context, Icons.radio_button_unchecked),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Last.fm',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Loading session...',
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

  Widget _buildErrorTile(BuildContext context) {
    return _buildTapTile(
      context,
      icon: Icons.error_outline,
      title: 'Last.fm',
      subtitle: 'Could not load session',
      onTap: _startAuth,
      trailing: Icon(
        Icons.chevron_right,
        color: context.adaptiveTextTertiary,
        size: 20,
      ),
    );
  }

  Widget _buildConnectedTile(BuildContext context, {required String username}) {
    return _buildTapTile(
      context,
      icon: Icons.radio_button_checked,
      title: 'Last.fm',
      subtitle: 'Connected as $username',
      onTap: () => _showConnectedBottomSheet(username),
      trailing: Icon(
        Icons.check_circle,
        color: const Color(0xFF4CAF50),
        size: 20,
      ),
    );
  }

  Future<void> _showConnectedBottomSheet(String username) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppConstants.radiusLg),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: context.adaptiveTextTertiary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.check_circle,
                      color: Color(0xFF4CAF50),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Last.fm Connected',
                          style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                            color: context.adaptiveTextPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Your music is being scrobbled',
                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            color: context.adaptiveTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 24),

            // Content
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  // Account info
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackgroundStrong,
                      borderRadius: BorderRadius.circular(
                        AppConstants.radiusMd,
                      ),
                      border: Border.all(
                        color: context.adaptiveTextTertiary.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD51007).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.person,
                            color: Color(0xFFD51007),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Connected Account',
                                style: Theme.of(ctx).textTheme.bodySmall
                                    ?.copyWith(
                                      color: context.adaptiveTextSecondary,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                username,
                                style: Theme.of(ctx).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: context.adaptiveTextPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Action buttons
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showApiKeyDialog();
                      },
                      icon: const Icon(Icons.edit, size: 18),
                      label: const Text('Edit Credentials'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: context.adaptiveTextTertiary.withValues(alpha: 0.3),
                        ),
                        foregroundColor: context.adaptiveTextPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusMd,
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _disconnect();
                      },
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Disconnect'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.withValues(alpha: 0.1),
                        foregroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusMd,
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisconnectedTile(BuildContext context) {
    return _buildTapTile(
      context,
      icon: Icons.radio_button_unchecked,
      title: 'Last.fm',
      subtitle: _awaitingCallback
          ? 'Waiting for browser authorization...'
          : 'Connect to scrobble your listening history',
      onTap: _awaitingCallback
          ? null
          : () {
              _showApiKeyDialog(autoConnectAfterSave: true);
            },
      trailing: _awaitingCallback
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  context.adaptiveTextTertiary,
                ),
              ),
            )
          : Icon(
              Icons.chevron_right,
              color: context.adaptiveTextTertiary,
              size: 20,
            ),
    );
  }

  Widget _buildTapTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    required Widget trailing,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: _buildTileContainer(
          context,
          child: Row(
            children: [
              _buildLeadingIcon(context, icon),
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
              trailing,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTileContainer(BuildContext context, {required Widget child}) {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: child,
    );
  }

  Widget _buildLeadingIcon(BuildContext context, IconData icon) {
    return Container(
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
    );
  }
}
