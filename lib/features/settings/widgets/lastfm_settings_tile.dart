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
    if (state == AppLifecycleState.resumed && _awaitingCallback) {
      _awaitingCallback = false;
      _completeAuth();
    }
  }

  Future<void> _startAuth() async {
    final auth = ref.read(lastFmAuthServiceProvider);

    // Check if API credentials are configured
    final hasCredentials = await auth.hasValidApiCredentials();
    if (!hasCredentials) {
      _showError(
        'Please configure your Last.fm API key and shared secret first.',
      );
      return;
    }

    try {
      await auth.getTokenAndLaunchAuth();
      if (mounted) {
        setState(() => _awaitingCallback = true);
      }
    } catch (e) {
      _showError(
        'Could not open Last.fm. Check your API credentials and internet connection.',
      );
    }
  }

  Future<void> _completeAuth() async {
    final auth = ref.read(lastFmAuthServiceProvider);
    try {
      await auth.exchangeTokenForSession();
      ref.invalidate(lastFmSessionProvider);
      _showSuccess('Last.fm connected!');
    } catch (_) {
      _showError(
        'Authorization failed. Make sure you approved access on Last.fm.',
      );
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Last.fm?'),
        content: const Text(
          'Your scrobbling history will remain on Last.fm, '
          'but Flick will stop sending scrobbles.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect'),
          ),
        ],
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

    if (!mounted) return;

    try {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Configure Last.fm Credentials'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Get your API key and shared secret from:',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () {
                    launchUrl(
                      Uri.parse('https://www.last.fm/api/account/create'),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  child: Text(
                    'https://www.last.fm/api/account/create',
                    style: TextStyle(
                      color: Theme.of(context).primaryColor,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: apiKeyController,
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: sharedSecretController,
                  decoration: const InputDecoration(
                    labelText: 'Shared Secret',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  obscureText: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                if (apiKeyController.text.isEmpty ||
                    sharedSecretController.text.isEmpty) {
                  _showError('Please enter both API key and shared secret');
                  return;
                }
                await auth.setApiCredentials(
                  apiKeyController.text,
                  sharedSecretController.text,
                );
                if (mounted) {
                  Navigator.pop(ctx);
                  _showSuccess('Credentials saved successfully!');
                  if (autoConnectAfterSave && mounted) {
                    await _startAuth();
                  }
                }
              },
              child: const Text('Save & Connect'),
            ),
          ],
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
      onTap: () async {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Last.fm Account'),
            content: Text('Connected as: $username'),
            actions: [
              TextButton(
                child: const Text('Edit Credentials'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _showApiKeyDialog();
                },
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
      trailing: TextButton(
        onPressed: _disconnect,
        child: const Text('Disconnect'),
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
          ? TextButton(
              onPressed: _completeAuth,
              child: const Text("I've authorized"),
            )
          : TextButton(
              onPressed: () => _showApiKeyDialog(autoConnectAfterSave: true),
              child: const Text('Configure'),
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
