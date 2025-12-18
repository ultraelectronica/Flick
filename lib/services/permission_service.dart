import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for handling Android storage permissions and folder selection.
///
/// Uses Scoped Storage (ACTION_OPEN_DOCUMENT_TREE) for Android 10+
/// and falls back to READ_EXTERNAL_STORAGE for Android 9-.
class PermissionService {
  static const _channel = MethodChannel('com.ultraelectronica.flick/storage');

  /// Request storage permission based on Android version.
  /// Returns true if permission is granted.
  Future<bool> requestStoragePermission() async {
    if (Platform.isAndroid) {
      // For Android 13+, we need READ_MEDIA_AUDIO
      // For Android 10-12, we use Scoped Storage (no permission needed for SAF)
      // For Android 9-, we need READ_EXTERNAL_STORAGE
      final status = await Permission.audio.request();
      if (status.isGranted) {
        return true;
      }

      // Fallback to storage permission for older Android
      final storageStatus = await Permission.storage.request();
      return storageStatus.isGranted;
    }
    return true;
  }

  /// Check if storage permission is already granted.
  Future<bool> hasStoragePermission() async {
    if (Platform.isAndroid) {
      final audioGranted = await Permission.audio.isGranted;
      final storageGranted = await Permission.storage.isGranted;
      return audioGranted || storageGranted;
    }
    return true;
  }

  /// Open the system folder picker (ACTION_OPEN_DOCUMENT_TREE).
  /// Returns the selected folder URI as a string, or null if cancelled.
  Future<String?> openFolderPicker() async {
    try {
      final result = await _channel.invokeMethod<String>('openDocumentTree');
      return result;
    } on PlatformException catch (e) {
      throw StorageException('Failed to open folder picker: ${e.message}');
    }
  }

  /// Take persistable URI permission for a folder.
  /// This allows the app to access the folder after reboot.
  Future<bool> takePersistablePermission(String uri) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'takePersistableUriPermission',
        {'uri': uri},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      throw StorageException('Failed to persist permission: ${e.message}');
    }
  }

  /// Release persistable URI permission for a folder.
  Future<void> releasePersistablePermission(String uri) async {
    try {
      await _channel.invokeMethod<void>('releasePersistableUriPermission', {
        'uri': uri,
      });
    } on PlatformException catch (e) {
      throw StorageException('Failed to release permission: ${e.message}');
    }
  }

  /// Get list of all persisted folder URIs.
  Future<List<String>> getPersistedFolderUris() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'getPersistedUriPermissions',
      );
      return result?.cast<String>() ?? [];
    } on PlatformException catch (e) {
      throw StorageException('Failed to get persisted URIs: ${e.message}');
    }
  }
}

/// Exception for storage-related errors.
class StorageException implements Exception {
  final String message;
  StorageException(this.message);

  @override
  String toString() => 'StorageException: $message';
}
