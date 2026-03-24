import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/auto_library_sync_service.dart';

/// Provider for the auto library sync service.
final autoLibrarySyncServiceProvider = Provider<AutoLibrarySyncService>((ref) {
  final service = AutoLibrarySyncService();
  
  // Clean up when provider is disposed
  ref.onDispose(() {
    service.stop();
  });
  
  return service;
});

/// Notifier for auto sync enabled state.
class AutoSyncEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void set(bool value) => state = value;
}

/// Notifier for auto sync interval in minutes.
class AutoSyncIntervalNotifier extends Notifier<int> {
  @override
  int build() => 5;

  void setInterval(int minutes) => state = minutes;
}

/// Provider for auto sync enabled state.
final autoSyncEnabledProvider = NotifierProvider<AutoSyncEnabledNotifier, bool>(
  AutoSyncEnabledNotifier.new,
);

/// Provider for auto sync interval in minutes.
final autoSyncIntervalProvider = NotifierProvider<AutoSyncIntervalNotifier, int>(
  AutoSyncIntervalNotifier.new,
);

