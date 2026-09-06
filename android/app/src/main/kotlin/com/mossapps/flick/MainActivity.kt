package com.mossapps.flick

// Audio capability mapping:
//   Kotlin "usbDac"      → Rust AudioCapability::UsbDac      / BackendType::UsbDirect
//   Kotlin "hiResInternal" → Rust AudioCapability::HiResInternal / BackendType::DapNative or MixerBitPerfect
//   Kotlin "standard"    → Rust AudioCapability::Standard     / BackendType::ResampledFallback
//
// Route type mapping:
//   Kotlin "usb"       → USB DAC/AMP (direct or Android-managed)
//   Kotlin "internal"  → Built-in audio (could be DAP internal DAC or phone)
//   Kotlin "wired"     → Wired headphones/line out
//   Kotlin "bluetooth" → Bluetooth audio
//   Kotlin "dock"      → Dock audio
//   Kotlin "unknown"   → Unidentified route
//
// DAP brand detection happens in Rust (audio/device.rs DAP_REGISTRY) and Dart
// (android_audio_device_service.dart isLikelyDap). Kotlin does NOT detect DAP brands.

import android.Manifest
import android.app.PendingIntent
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.media.AudioDeviceInfo
import android.media.AudioDeviceCallback
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.media.audiofx.Visualizer
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.os.PowerManager
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import androidx.documentfile.provider.DocumentFile
import com.mossapps.flick.audiofx.JustAudioProcessingController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.roundToInt
import kotlin.math.min

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.mossapps.flick/storage"
    private val PLAYER_CHANNEL = "com.mossapps.flick/player"
    private val INTEGRATION_CHANNEL = "com.mossapps.flick/integration"
    private val UAC2_CHANNEL = "com.mossapps.flick/uac2"
    private val AUDIO_DEVICE_CHANNEL = "com.mossapps.flick/audio_device"
    private val EQUALIZER_CHANNEL = "com.mossapps.flick/equalizer"
    private val VISUALIZER_METHOD_CHANNEL = "com.mossapps.flick/visualizer"
    private val VISUALIZER_EVENT_CHANNEL = "com.mossapps.flick/visualizer_events"
    private val WIDGET_CHANNEL = "com.mossapps.flick/widget"
    private val OVERLAY_CHANNEL = "com.mossapps.flick/overlay"
    private val BLUETOOTH_CHANNEL = "com.mossapps.flick/bluetooth"
    private val BLUETOOTH_EVENT_CHANNEL = "com.mossapps.flick/bluetooth_events"
    private val CAST_CHANNEL = "com.mossapps.flick/cast"
    private val CAST_EVENT_CHANNEL = "com.mossapps.flick/cast_events"
    private val LOCKER_PACKAGE = "com.mossapps.locker"
    private val LOCKER_RETURN_URI = "locker://return?source=flick"
    // private val CONVERTER_CHANNEL = "com.mossapps.flick/converter"
    private val REQUEST_OPEN_DOCUMENT_TREE = 1001
    private val REQUEST_OPEN_DOCUMENT = 1003
    private val REQUEST_CREATE_DOCUMENT = 1004
    private val REQUEST_USB_PERMISSION = 1002
    private val REQUEST_OVERLAY_PERMISSION = 1005

    private var pendingDocumentTreeResult: MethodChannel.Result? = null
    private var pendingOpenDocumentResult: MethodChannel.Result? = null
    private var pendingCreateDocumentResult: MethodChannel.Result? = null
    private var pendingUac2PermissionResult: MethodChannel.Result? = null
    private var pendingUac2PermissionCallback: ((Boolean) -> Unit)? = null
    private var pendingOverlayPermissionResult: MethodChannel.Result? = null
    private var usbPermissionReceiver: BroadcastReceiver? = null
    private var usbHotplugReceiver: BroadcastReceiver? = null
    private val promptedUsbPermissionDeviceNames = mutableSetOf<String>()
    private var uac2DeviceCache: List<Map<String, Any?>>? = null
    private var uac2Channel: MethodChannel? = null
    private var audioDeviceChannel: MethodChannel? = null
    private val directUsbConnections = mutableMapOf<String, UsbDeviceConnection>()
    private var activeDirectUsbDeviceName: String? = null
    private var exclusiveDacModeEnabled = false
    private var directUsbPlaybackActive = false
    private var killIsochronousUsbOnQuit = true
    private var directUsbFocusGain: Int? = null
    private var directUsbAudioFocusRequest: AudioFocusRequest? = null
    private val directUsbAudioFocusChangeListener =
        AudioManager.OnAudioFocusChangeListener { focusChange ->
            Log.i("UAC2", "Direct USB audio focus changed: $focusChange")
        }
    private var cachedMusicVolumeBeforeMute: Int? = null
    private val justAudioProcessingController = JustAudioProcessingController()
    private var integrationChannel: MethodChannel? = null
    private var pendingExternalPlaybackPayload: Map<String, Any?>? = null
    private var volumeContentObserver: ContentObserver? = null
    private var mediaStoreContentObserver: ContentObserver? = null
    private var mediaFilesContentObserver: ContentObserver? = null
    private var mediaStoreEventSink: EventChannel.EventSink? = null
    private val volumeObserverHandler = Handler(Looper.getMainLooper())
    private var volumeObserverDebounceRunnable: Runnable? = null
    private var suppressVolumeObserver = false
    private var suppressVolumeObserverRunnable: Runnable? = null
    private var lastObservedVolume: Int = -1
    private var lastObservedMuted: Boolean = false
    /** Direct USB + UAC2 hardware volume: last native snapshot (not STREAM_MUSIC). */
    private var lastObservedHardwareVolume: Double = Double.NaN
    /** Matches nativeGetRustDirectUsbHardwareMute: -1 unknown, 0/1; Int.MIN_VALUE = unset. */
    private var lastObservedHardwareMute: Int = Int.MIN_VALUE
    private val priorityAnchorService by lazy { PriorityAnchorService(applicationContext) }
    private var audioDeviceCallback: AudioDeviceCallback? = null
    // private var audioConverter: AudioConverter? = null
    // Coroutine scope for background tasks
    private val mainScope = CoroutineScope(Dispatchers.Main)
    private var visualizer: Visualizer? = null
    private var visualizerEventSink: EventChannel.EventSink? = null
    private var widgetChannel: MethodChannel? = null
    private val HOME_WIDGET_LAUNCH_ACTION = "com.mossapps.flick.WIDGET_LAUNCH"
    private var a2dpProxy: BluetoothA2dp? = null
    private var developerMode: Boolean = false
    private var bluetoothEventSink: EventChannel.EventSink? = null
    private var aclReceiver: BroadcastReceiver? = null
    private var castController: CastController? = null
    private var castEventSink: EventChannel.EventSink? = null

    // Load the Rust shared library before calling into native startup hooks.
    init {
        System.loadLibrary("rust_lib_flick_player")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        super.onCreate(savedInstanceState)

        if (!nativeInitRustAndroidContext(applicationContext)) {
            Log.e("Flick", "Failed to initialize Rust Android audio context")
        } else {
            Log.i("Flick", "Rust Android audio context initialized")
        }

        handleExternalPlaybackIntent(intent)
        handleUsbAttachIntent(intent)
        maybeRequestPermissionForConnectedUsbAudioDevices(reason = "activity create")
        registerBluetoothAclReceiver()
        registerAudioDeviceCallback()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        dispatchWidgetIntent(intent)
        handleExternalPlaybackIntent(intent)
        handleUsbAttachIntent(intent)
        maybeRequestPermissionForConnectedUsbAudioDevices(reason = "new intent")
    }

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        var engine = FlutterEngineCache.getInstance().get("main_engine")
        if (engine == null) {
            engine = FlutterEngine(context.applicationContext)
            ensurePluginsRegistered(engine)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
            FlutterEngineCache.getInstance().put("main_engine", engine)
        }
        return engine
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Idempotent: cached engines skip duplicate GeneratedPluginRegistrant.
        ensurePluginsRegistered(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openDocumentTree" -> {
                    pendingDocumentTreeResult = result
                    openDocumentTree()
                }
                "openDocument" -> {
                    @Suppress("UNCHECKED_CAST")
                    val mimeTypes = (call.argument<List<String>>("mimeTypes") ?: listOf(
                        "audio/x-mpegurl",
                        "application/vnd.apple.mpegurl",
                        "application/x-mpegurl",
                        "audio/mpegurl",
                        "text/plain"
                    )) as List<String>
                    if (pendingOpenDocumentResult != null) {
                        result.error(
                            "OPERATION_IN_PROGRESS",
                            "Another document picker request is already in progress",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    pendingOpenDocumentResult = result
                    openDocument(mimeTypes)
                }
                "createDocument" -> {
                    val fileName = call.argument<String>("fileName")
                    val mimeType = call.argument<String>("mimeType") ?: "audio/x-mpegurl"
                    if (fileName != null && fileName.isNotBlank()) {
                        pendingCreateDocumentResult = result
                        createDocument(fileName, mimeType)
                    } else {
                        result.error("INVALID_ARGUMENT", "fileName is required", null)
                    }
                }
                "takePersistableUriPermission" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        val success = takePersistableUriPermission(uri)
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "releasePersistableUriPermission" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        releasePersistableUriPermission(uri)
                        result.success(null)
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "getPersistedUriPermissions" -> {
                    val uris = getPersistedUriPermissions()
                    result.success(uris)
                }
                "saveImageToGallery" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val fileName = call.argument<String>("fileName") ?: "flick_recap.png"
                    val albumName = call.argument<String>("albumName") ?: "Flick"
                    if (bytes == null || bytes.isEmpty()) {
                        result.error("INVALID_ARGUMENT", "bytes are required", null)
                    } else {
                        val imageBytes = bytes
                        mainScope.launch {
                            try {
                                val savedUri = withContext(Dispatchers.IO) {
                                    saveImageToGallery(imageBytes, fileName, albumName)
                                }
                                result.success(savedUri)
                            } catch (e: SecurityException) {
                                result.error(
                                    "STORAGE_PERMISSION_REQUIRED",
                                    "Storage permission is required to save images on this Android version.",
                                    null
                                )
                            } catch (e: Exception) {
                                result.error("SAVE_IMAGE_ERROR", "Failed to save image: ${e.message}", null)
                            }
                        }
                    }
                }
                "listAudioFiles" -> {
                    val uri = call.argument<String>("uri")
                    val filterNonMusicFilesAndFolders =
                        call.argument<Boolean>("filterNonMusicFilesAndFolders") ?: true
                    if (uri != null) {
                        // Launch in background to avoid blocking UI
                        mainScope.launch {
                            try {
                                val files = withContext(Dispatchers.IO) {
                                    fastScanAudioFiles(uri, filterNonMusicFilesAndFolders)
                                }
                                result.success(files)
                            } catch (e: Exception) {
                                result.error("SCAN_ERROR", "Failed to scan folder: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "listPlaylistFiles" -> {
                    val uri = call.argument<String>("uri")
                    val filterNonMusicFilesAndFolders =
                        call.argument<Boolean>("filterNonMusicFilesAndFolders") ?: true
                    if (uri != null) {
                        mainScope.launch {
                            try {
                                val files = withContext(Dispatchers.IO) {
                                    scanPlaylistFiles(uri, filterNonMusicFilesAndFolders)
                                }
                                result.success(files)
                            } catch (e: Exception) {
                                result.error("SCAN_ERROR", "Failed to scan folder: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "fetchAudioMetadata" -> {
                    val uris = call.argument<List<String>>("uris")
                    if (uris != null) {
                        mainScope.launch {
                            try {
                                val metadata = withContext(Dispatchers.IO) {
                                    extractMetadataForFiles(uris)
                                }
                                result.success(metadata)
                            } catch (e: Exception) {
                                result.error("METADATA_ERROR", "Failed to fetch metadata: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URIs list is required", null)
                    }
                }
                "fetchEmbeddedArtwork" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        mainScope.launch {
                            try {
                                val artwork = withContext(Dispatchers.IO) {
                                    extractEmbeddedArtwork(uri)
                                }
                                result.success(artwork)
                            } catch (e: Exception) {
                                result.error("ARTWORK_ERROR", "Failed to fetch embedded artwork: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "cacheUriForPlayback" -> {
                    val uri = call.argument<String>("uri")
                    val extensionHint = call.argument<String>("extensionHint")
                    val maxSizeBytes = call.argument<Long>("maxSizeBytes")
                    if (uri != null) {
                        mainScope.launch {
                            try {
                                val stagedPath = withContext(Dispatchers.IO) {
                                    cacheUriForPlayback(uri, extensionHint, maxSizeBytes)
                                }
                                result.success(stagedPath)
                            } catch (e: Exception) {
                                result.error("CACHE_URI_ERROR", "Failed to stage audio URI: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "readSiblingLyrics" -> {
                    val audioUri = call.argument<String>("audioUri")
                    if (audioUri != null) {
                        mainScope.launch {
                            try {
                                val lyrics = withContext(Dispatchers.IO) {
                                    readSiblingLyrics(audioUri)
                                }
                                result.success(lyrics)
                            } catch (e: Exception) {
                                result.error("LYRICS_READ_ERROR", "Failed to read lyrics: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "audioUri is required", null)
                    }
                }
                "readEmbeddedLyrics" -> {
                    val audioUri = call.argument<String>("audioUri")
                    if (audioUri != null) {
                        mainScope.launch {
                            try {
                                val lyrics = withContext(Dispatchers.IO) {
                                    readEmbeddedLyrics(audioUri)
                                }
                                result.success(lyrics)
                            } catch (e: Exception) {
                                result.error("LYRICS_EMBEDDED_ERROR", "Failed to read embedded lyrics: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "audioUri is required", null)
                    }
                }
                "getDocumentDisplayName" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        val displayName = getDocumentDisplayName(uri)
                        result.success(displayName)
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "resolveTreeUriToPath" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        result.success(resolveTreeUriToPath(uri))
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "resolveStorageInfo" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        result.success(resolveStorageInfo(uri))
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "hasAllFilesAccess" -> {
                    result.success(hasAllFilesAccess())
                }
                "requestAllFilesAccess" -> {
                    result.success(openAllFilesAccessSettings())
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    result.success(requestIgnoreBatteryOptimizations())
                }
                "readTextDocument" -> {
                    val uri = call.argument<String>("uri")
                    android.util.Log.d("MainActivity", "[MethodChannel] readTextDocument called with URI: $uri")
                    if (uri != null) {
                        mainScope.launch {
                            try {
                                val text = withContext(Dispatchers.IO) {
                                    readTextDocument(uri)
                                }
                                android.util.Log.d("MainActivity", "[MethodChannel] readTextDocument success, length: ${text.length}")
                                result.success(text)
                            } catch (e: Exception) {
                                android.util.Log.e("MainActivity", "[MethodChannel] readTextDocument error: ${e.message}", e)
                                result.error("READ_TEXT_ERROR", "Failed to read document: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "writeTextDocument" -> {
                    val uri = call.argument<String>("uri")
                    val content = call.argument<String>("content")
                    android.util.Log.d("MainActivity", "[MethodChannel] writeTextDocument called with URI: $uri, content length: ${content?.length}")
                    if (uri != null && content != null) {
                        mainScope.launch {
                            try {
                                val success = withContext(Dispatchers.IO) {
                                    writeTextDocument(uri, content)
                                }
                                android.util.Log.d("MainActivity", "[MethodChannel] writeTextDocument result: $success")
                                result.success(success)
                            } catch (e: Exception) {
                                android.util.Log.e("MainActivity", "[MethodChannel] writeTextDocument error: ${e.message}", e)
                                result.error("WRITE_TEXT_ERROR", "Failed to write document: ${e.message}", null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI and content are required", null)
                    }
                }
                "deleteDocument" -> {
                    val folderTreeUri = call.argument<String>("folderTreeUri")
                    val filePath = call.argument<String>("filePath")
                    if (folderTreeUri != null && filePath != null) {
                        mainScope.launch {
                            try {
                                val success = withContext(Dispatchers.IO) {
                                    deleteDocumentViaSaf(folderTreeUri, filePath)
                                }
                                result.success(success)
                            } catch (e: Exception) {
                                Log.w("MainActivity", "[MethodChannel] deleteDocument error: ${e.message}", e)
                                result.success(false)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "folderTreeUri and filePath are required", null)
                    }
                }
                "removeFromMediaStore" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        mainScope.launch {
                            try {
                                val removed = withContext(Dispatchers.IO) {
                                    removeFromMediaStore(filePath)
                                }
                                result.success(removed)
                            } catch (e: Exception) {
                                Log.w("MainActivity", "[MethodChannel] removeFromMediaStore error: ${e.message}", e)
                                result.success(false)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "filePath is required", null)
                    }
                }
                "writeFileBytesViaSaf" -> {
                    val folderTreeUri = call.argument<String>("folderTreeUri")
                    val filePath = call.argument<String>("filePath")
                    val tempFilePath = call.argument<String>("tempFilePath")
                    if (folderTreeUri != null && filePath != null && tempFilePath != null) {
                        mainScope.launch {
                            try {
                                val success = withContext(Dispatchers.IO) {
                                    writeFileBytesViaSaf(folderTreeUri, filePath, tempFilePath)
                                }
                                result.success(success)
                            } catch (e: Exception) {
                                Log.w("MainActivity", "[MethodChannel] writeFileBytesViaSaf error: ${e.message}", e)
                                result.success(false)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "folderTreeUri, filePath, and tempFilePath are required", null)
                    }
                }
                "queryMediaStoreAudio" -> {
                    val folderPaths = call.argument<List<String>>("folderPaths")
                    val volumeName = call.argument<String?>("volumeName")
                    mainScope.launch {
                        try {
                            val files = withContext(Dispatchers.IO) {
                                queryMediaStoreAudio(folderPaths ?: emptyList(), volumeName)
                            }
                            result.success(files)
                        } catch (e: Exception) {
                            result.error("MEDIASTORE_ERROR", "Failed to query MediaStore: ${e.message}", null)
                        }
                    }
                }
                "queryMediaStoreNonAudio" -> {
                    val folderPaths = call.argument<List<String>>("folderPaths")
                    val volumeName = call.argument<String?>("volumeName")
                    mainScope.launch {
                        try {
                            val files = withContext(Dispatchers.IO) {
                                queryMediaStoreNonAudio(folderPaths ?: emptyList(), volumeName)
                            }
                            result.success(files)
                        } catch (e: Exception) {
                            result.error("MEDIASTORE_ERROR", "Failed to query MediaStore non-audio: ${e.message}", null)
                        }
                    }
                }
                "queryMediaStoreDeletions" -> {
                    val filePaths = call.argument<List<String>>("filePaths")
                    val volumeName = call.argument<String?>("volumeName")
                    mainScope.launch {
                        try {
                            val deleted = withContext(Dispatchers.IO) {
                                queryMediaStoreDeletions(filePaths ?: emptyList(), volumeName)
                            }
                            result.success(deleted)
                        } catch (e: Exception) {
                            result.error("MEDIASTORE_ERROR", "Failed to check deletions: ${e.message}", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.mossapps.flick/mediastore_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    mediaStoreEventSink = events
                    registerMediaStoreObserver()
                }
                override fun onCancel(arguments: Any?) {
                    mediaStoreEventSink = null
                    unregisterMediaStoreObserver()
                }
            }
        )

        // Cache the Flutter engine for notification service to use
        // Engine is already cached in provideFlutterEngine
        
        // Player channel for notification control
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLAYER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "showNotification" -> {
                    val title = call.argument<String>("title")
                    val artist = call.argument<String>("artist")
                    val albumArtPath = call.argument<String>("albumArtPath")
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: true
                    // Handle both Integer and Long types from Flutter
                    val duration = when (val d = call.argument<Any>("duration")) {
                        is Long -> d
                        is Int -> d.toLong()
                        else -> 0L
                    }
                    val position = when (val p = call.argument<Any>("position")) {
                        is Long -> p
                        is Int -> p.toLong()
                        else -> 0L
                    }
                    val isShuffle = call.argument<Boolean>("isShuffle") ?: false
                    val isFavorite = call.argument<Boolean>("isFavorite") ?: false
                    val color = call.argument<Any>("color")?.let { c ->
                        when (c) {
                            is Int -> c
                            is Long -> c.toInt()
                            else -> null
                        }
                    }

                    val intent = Intent(this, MusicNotificationService::class.java).apply {
                        putExtra("title", title)
                        putExtra("artist", artist)
                        putExtra("albumArtPath", albumArtPath)
                        putExtra("isPlaying", isPlaying)
                        putExtra("duration", duration)
                        putExtra("position", position)
                        putExtra("isShuffle", isShuffle)
                        putExtra("isFavorite", isFavorite)
                        color?.let { putExtra("color", it) }
                    }
                    
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title")
                    val artist = call.argument<String>("artist")
                    val albumArtPath = call.argument<String>("albumArtPath")
                    val isPlaying = call.argument<Boolean>("isPlaying")
                    // Handle both Integer and Long types from Flutter
                    val duration = call.argument<Any>("duration")?.let { d ->
                        when (d) {
                            is Long -> d
                            is Int -> d.toLong()
                            else -> null
                        }
                    }
                    val position = call.argument<Any>("position")?.let { p ->
                        when (p) {
                            is Long -> p
                            is Int -> p.toLong()
                            else -> null
                        }
                    }
                    val isShuffle = call.argument<Boolean>("isShuffle")
                    val isFavorite = call.argument<Boolean>("isFavorite")
                    val color = call.argument<Any>("color")?.let { c ->
                        when (c) {
                            is Int -> c
                            is Long -> c.toInt()
                            else -> null
                        }
                    }

                    val intent = Intent(this, MusicNotificationService::class.java).apply {
                        title?.let { putExtra("title", it) }
                        artist?.let { putExtra("artist", it) }
                        putExtra("albumArtPath", albumArtPath)
                        isPlaying?.let { putExtra("isPlaying", it) }
                        duration?.let { putExtra("duration", it) }
                        position?.let { putExtra("position", it) }
                        isShuffle?.let { putExtra("isShuffle", it) }
                        isFavorite?.let { putExtra("isFavorite", it) }
                        color?.let { putExtra("color", it) }
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "hideNotification" -> {
                    stopService(Intent(this, MusicNotificationService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OVERLAY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canDrawOverlays" -> {
                    result.success(Settings.canDrawOverlays(this))
                }
                "requestOverlayPermission" -> {
                    pendingOverlayPermissionResult = result
                    try {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            android.net.Uri.parse("package:$packageName"),
                        )
                        startActivityForResult(intent, REQUEST_OVERLAY_PERMISSION)
                    } catch (e: Exception) {
                        pendingOverlayPermissionResult = null
                        result.success(false)
                    }
                }
                "showFloatingPlayer" -> {
                    val intent = Intent(this, MusicNotificationService::class.java).apply {
                        putExtra("floating", "show")
                        call.argument<String>("title")?.let { putExtra("title", it) }
                        call.argument<String>("artist")?.let { putExtra("artist", it) }
                        call.argument<String>("albumArtPath")?.let { putExtra("albumArtPath", it) }
                        call.argument<Boolean>("isPlaying")?.let { putExtra("isPlaying", it) }
                    }
                    startService(intent)
                    result.success(null)
                }
                "hideFloatingPlayer" -> {
                    startService(
                        Intent(this, MusicNotificationService::class.java)
                            .putExtra("floating", "hide")
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        integrationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INTEGRATION_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingExternalPlayback" -> {
                        result.success(pendingExternalPlaybackPayload)
                        pendingExternalPlaybackPayload = null
                    }
                    "returnToLocker" -> {
                        result.success(returnToLocker())
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // UAC 2.0 USB Host API (Android): list devices and request permission
        uac2Channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UAC2_CHANNEL)
        uac2Channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "listDevices" -> {
                    val refresh = call.argument<Boolean>("refresh") ?: false
                    val devices = listUac2Devices(refresh)
                    result.success(devices)
                }
                "requestPermission" -> {
                    val deviceName = call.argument<String>("deviceName")
                    if (deviceName != null) {
                        requestUac2Permission(deviceName, result)
                    } else {
                        result.error("INVALID_ARGUMENT", "deviceName is required", null)
                    }
                }
                "hasPermission" -> {
                    val deviceName = call.argument<String>("deviceName")
                    if (deviceName != null) {
                        val has = hasUac2Permission(deviceName)
                        result.success(has)
                    } else {
                        result.error("INVALID_ARGUMENT", "deviceName is required", null)
                    }
                }
                "getRouteStatus" -> {
                    result.success(
                        getRouteStatus(
                            preferredDeviceName = call.argument<String>("deviceName"),
                            preferredProductName = call.argument<String>("productName"),
                            preferredVendorId = call.argument<Number>("vendorId")?.toInt(),
                            preferredProductId = call.argument<Number>("productId")?.toInt(),
                            preferredSerial = call.argument<String>("serial"),
                        )
                    )
                }
                "getAudioCapabilities" -> {
                    result.success(
                        getAudioCapabilities(
                            preferredDeviceName = call.argument<String>("deviceName"),
                            preferredProductName = call.argument<String>("productName"),
                            preferredVendorId = call.argument<Number>("vendorId")?.toInt(),
                            preferredProductId = call.argument<Number>("productId")?.toInt(),
                            preferredSerial = call.argument<String>("serial"),
                        )
                    )
                }
                "getDirectUsbDiagnostics" -> {
                    result.success(getDirectUsbDiagnostics())
                }
                "setRouteVolume" -> {
                    val volume = call.argument<Double>("volume")
                    if (volume != null) {
                        result.success(setRouteVolume(volume))
                    } else {
                        result.error("INVALID_ARGUMENT", "volume is required", null)
                    }
                }
                "getRouteVolume" -> {
                    result.success(getRouteVolume())
                }
                "setRouteMuted" -> {
                    val muted = call.argument<Boolean>("muted")
                    if (muted != null) {
                        result.success(setRouteMuted(muted))
                    } else {
                        result.error("INVALID_ARGUMENT", "muted is required", null)
                    }
                }
                "getRouteMuted" -> {
                    result.success(getRouteMuted())
                }
                "verifyHardwareVolumeHealth" -> {
                    result.success(verifyHardwareVolumeHealth())
                }
                "activateDirectUsb" -> {
                    val deviceName = call.argument<String>("deviceName")
                    if (deviceName != null) {
                        result.success(activateDirectUsb(deviceName))
                    } else {
                        result.error("INVALID_ARGUMENT", "deviceName is required", null)
                    }
                }
                "setExclusiveDacMode" -> {
                    val enabled = call.argument<Boolean>("enabled")
                    if (enabled != null) {
                        result.success(setExclusiveDacMode(enabled))
                    } else {
                        result.error("INVALID_ARGUMENT", "enabled is required", null)
                    }
                }
                "setDirectUsbPlaybackActive" -> {
                    val active = call.argument<Boolean>("active")
                    if (active != null) {
                        result.success(setDirectUsbPlaybackActive(active))
                    } else {
                        result.error("INVALID_ARGUMENT", "active is required", null)
                    }
                }
                "setDirectUsbPlaybackFormat" -> {
                    val sampleRate = call.argument<Int>("sampleRate")
                    val bitDepth = call.argument<Int>("bitDepth")
                    val channels = call.argument<Int>("channels")
                    val isDop = call.argument<Boolean>("isDop") ?: false
                    val isNativeDsd = call.argument<Boolean>("isNativeDsd") ?: false
                    if (sampleRate != null && bitDepth != null && channels != null) {
                        result.success(
                            nativeSetRustDirectUsbPlaybackFormat(
                                sampleRate,
                                bitDepth,
                                channels,
                                isDop,
                                isNativeDsd,
                            )
                        )
                    } else {
                        result.error(
                            "INVALID_ARGUMENT",
                            "sampleRate, bitDepth, and channels are required",
                            null,
                        )
                    }
                }
                "clearDirectUsbPlaybackFormat" -> {
                    result.success(nativeSetRustDirectUsbPlaybackFormat(0, 0, 0, false, false))
                }
                "deactivateDirectUsb" -> {
                    result.success(deactivateDirectUsb())
                }
                "setKillIsochronousUsbOnQuit" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    killIsochronousUsbOnQuit = enabled
                    result.success(true)
                }
                "setDeveloperMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    developerMode = enabled
                    nativeSetRustDeveloperMode(enabled)
                    result.success(true)
                }
                "markDirectUsbFallback" -> {
                    val reason = call.argument<String>("reason")
                    result.success(nativeMarkRustDirectUsbFallback(reason))
                }
                "startPriorityAnchor" -> {
                    priorityAnchorService.start()
                    result.success(true)
                }
                "stopPriorityAnchor" -> {
                    priorityAnchorService.stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        audioDeviceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUDIO_DEVICE_CHANNEL,
        )
        audioDeviceChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPlaybackDeviceInfo" -> result.success(getPlaybackDeviceInfo())
                else -> result.notImplemented()
            }
        }

        ensureA2dpProxy()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLUETOOTH_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getConnectedDevices" -> result.success(getBluetoothDevices(includeBonded = false))
                "getBondedDevices" -> result.success(getBluetoothDevices(includeBonded = true))
                "getCodecStatus" -> {
                    val address = call.argument<String>("address")
                    result.success(if (address != null) getBluetoothCodecStatus(address) else null)
                }
                "setCodecConfig" -> {
                    val address = call.argument<String>("address") ?: ""
                    val codecType = call.argument<Int>("codecType") ?: 0
                    val sampleRate = call.argument<Int>("sampleRate") ?: 0
                    val bitsPerSample = call.argument<Int>("bitsPerSample") ?: 0
                    val channelMode = call.argument<Int>("channelMode") ?: 0
                    val ldacBitrate = call.argument<Int>("ldacBitrate") ?: 0
                    result.success(setBluetoothCodecConfigNative(address, codecType, sampleRate, bitsPerSample, channelMode, ldacBitrate))
                }
                "getBatteryLevel" -> {
                    val address = call.argument<String>("address") ?: ""
                    readBluetoothBatteryLevel(address, result)
                }
                "setAbsoluteVolumeEnabled" -> {
                    val address = call.argument<String>("address") ?: ""
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    result.success(setBluetoothAbsoluteVolume(address, enabled))
                }
                "openBluetoothCodecSettings" -> result.success(openDeveloperOptions())
                else -> result.notImplemented()
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, BLUETOOTH_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    bluetoothEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    bluetoothEventSink = null
                }
            }
        )

        // Chromecast: discovery via MediaRouter, control via RemoteMediaClient.
        if (castController == null) {
            castController = CastController(this)
            castController!!.start()
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAST_CHANNEL).setMethodCallHandler { call, result ->
            val cc = castController
            when (call.method) {
                "discover" -> result.success(cc?.discover())
                "connect" -> {
                    cc?.connect(call.argument<String>("id") ?: "")
                    result.success(null)
                }
                "disconnect" -> { cc?.disconnect(); result.success(null) }
                "load" -> {
                    cc?.load(
                        call.argument<String>("url") ?: "",
                        call.argument<String>("title"),
                        call.argument<String>("artist"),
                    )
                    result.success(null)
                }
                "play" -> { cc?.play(); result.success(null) }
                "pause" -> { cc?.pause(); result.success(null) }
                "stop" -> { cc?.stop(); result.success(null) }
                "seek" -> { cc?.seek((call.argument<Int>("position") ?: 0).toLong()); result.success(null) }
                "setVolume" -> { cc?.setVolume((call.argument<Double>("volume") ?: 1.0)); result.success(null) }
                "getOutputRoutes" -> result.success(cc?.getOutputRoutes())
                "selectOutputRoute" -> result.success(cc?.selectOutputRoute(call.argument<String>("id") ?: ""))
                else -> result.notImplemented()
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CAST_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    castEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    castEventSink = null
                }
            }
        )

        // Audio processing channel for Android native AudioEffect counterparts.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EQUALIZER_CHANNEL).setMethodCallHandler { call, result ->
            if (!justAudioProcessingController.handle(call, result)) {
                result.notImplemented()
            }
        }

        // Audio visualizer: attach to just_audio session for real FFT data
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, VISUALIZER_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    visualizerEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    visualizerEventSink = null
                }
            }
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VISUALIZER_METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "attachVisualizer" -> {
                    val sessionId = call.argument<Int>("sessionId") ?: 0
                    result.success(attachVisualizer(sessionId))
                }
                "detachVisualizer" -> {
                    detachVisualizer()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Audio converter channel
        // NOTE: FLAC to ALAC and M4A to MP3 conversion features are disabled for now
        /*
        audioConverter = AudioConverterFactory.create()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONVERTER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "convertToFlac" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        mainScope.launch {
                            val conversionResult = audioConverter?.convertToFlac(Uri.parse(uri), context) as? ConversionResult
                            handleConversionResult(conversionResult, result)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "convertToMp3" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        mainScope.launch {
                            val conversionResult = audioConverter?.convertToMp3(Uri.parse(uri), context) as? ConversionResult
                            handleConversionResult(conversionResult, result)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
                    }
                }
                "isSupported" -> {
                    val extension = call.argument<String>("extension")
                    if (extension != null) {
                        result.success(audioConverter?.isSupported(extension) ?: false)
                    } else {
                        result.error("INVALID_ARGUMENT", "extension is required", null)
                    }
                }
                "cancel" -> {
                    audioConverter?.cancel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        */
        
        // Register USB hot-plug receiver
        registerUsbHotplugReceiver()
        maybeRequestPermissionForConnectedUsbAudioDevices(reason = "flutter engine configured")
        // Register volume change observer
        registerVolumeContentObserver()

        widgetChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIDGET_CHANNEL)
        dispatchWidgetIntent(intent)
    }

    // private fun handleConversionResult(conversionResult: ConversionResult?, result: MethodChannel.Result) {
//         when (conversionResult) {
//             is ConversionResult.Success -> result.success(mapOf(
//                 "success" to true,
//                 "outputUri" to conversionResult.outputUri,
//                 "outputPath" to conversionResult.outputPath
//             ))
//             is ConversionResult.Error -> result.error("CONVERSION_ERROR", conversionResult.message, null)
//             else -> result.error("CONVERSION_ERROR", "Unknown error", null)
//         }
//     }

    private fun openDocumentTree() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_OPEN_DOCUMENT_TREE)
    }

    private fun openDocument(mimeTypes: List<String>) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_OPEN_DOCUMENT)
    }

    private fun createDocument(fileName: String, mimeType: String) {
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_CREATE_DOCUMENT)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQUEST_OPEN_DOCUMENT_TREE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                pendingDocumentTreeResult?.success(uri.toString())
            } else {
                pendingDocumentTreeResult?.success(null)
            }
            pendingDocumentTreeResult = null
        } else if (requestCode == REQUEST_OPEN_DOCUMENT) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                pendingOpenDocumentResult?.success(uri.toString())
            } else {
                pendingOpenDocumentResult?.success(null)
            }
            pendingOpenDocumentResult = null
        } else if (requestCode == REQUEST_CREATE_DOCUMENT) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                pendingCreateDocumentResult?.success(uri.toString())
            } else {
                pendingCreateDocumentResult?.success(null)
            }
            pendingCreateDocumentResult = null
        } else if (requestCode == REQUEST_OVERLAY_PERMISSION) {
            pendingOverlayPermissionResult?.success(Settings.canDrawOverlays(this))
            pendingOverlayPermissionResult = null
        }
    }

    private fun takePersistableUriPermission(uriString: String): Boolean {
        val uri = Uri.parse(uriString)
        // Persist read + write so metadata edits survive restarts. WRITE may not
        // be granted for older (read-only) grants, so fall back to READ only.
        return try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            true
        } catch (e: Exception) {
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    private fun releasePersistableUriPermission(uriString: String) {
        val uri = Uri.parse(uriString)
        // Release each flag independently; releasing them together fails if one
        // isn't held.
        for (flag in listOf(
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )) {
            try {
                contentResolver.releasePersistableUriPermission(uri, flag)
            } catch (e: Exception) {
                // Ignore if this flag wasn't held
            }
        }
    }

    private fun getPersistedUriPermissions(): List<String> {
        return contentResolver.persistedUriPermissions.map { it.uri.toString() }
    }

    private fun saveImageToGallery(bytes: ByteArray, fileName: String, albumName: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("WRITE_EXTERNAL_STORAGE permission is required on Android 9 and below.")
        }

        val resolver = contentResolver
        val safeFileName = if (fileName.lowercase().endsWith(".png")) {
            fileName
        } else {
            "$fileName.png"
        }
        val safeAlbumName = albumName.ifBlank { "Flick" }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, safeFileName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/$safeAlbumName")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }

        val itemUri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Unable to create a gallery entry.")

        try {
            resolver.openOutputStream(itemUri)?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: throw IllegalStateException("Unable to open an output stream.")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val publishValues = ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                }
                resolver.update(itemUri, publishValues, null, null)
            }

            return itemUri.toString()
        } catch (e: Exception) {
            resolver.delete(itemUri, null, null)
            throw e
        }
    }

    private fun dispatchWidgetIntent(intent: Intent?) {
        if (intent?.action != HOME_WIDGET_LAUNCH_ACTION) return
        val uri = intent.data?.toString() ?: return
        widgetChannel?.invokeMethod("dispatch", uri)
    }

    private fun handleExternalPlaybackIntent(intent: Intent?) {
        val payload = buildExternalPlaybackPayload(intent) ?: return
        pendingExternalPlaybackPayload = payload
        integrationChannel?.invokeMethod("externalPlaybackIntent", payload)
    }

    private fun buildExternalPlaybackPayload(intent: Intent?): Map<String, Any?>? {
        if (intent?.action != Intent.ACTION_VIEW) {
            return null
        }

        val dataUri = intent.data ?: return null
        if (dataUri.scheme != ContentResolver.SCHEME_CONTENT) {
            return null
        }

        if (!isReadableContentUri(dataUri)) {
            Log.w("Flick", "Ignoring unreadable external playback URI: $dataUri")
            return null
        }

        val sourcePackage = resolveSourcePackage(intent)
        return mapOf(
            "uri" to dataUri.toString(),
            "mimeType" to (intent.type ?: contentResolver.getType(dataUri)),
            "displayName" to getDocumentDisplayName(dataUri.toString()),
            "sourcePackage" to sourcePackage,
            "fromLocker" to (sourcePackage == LOCKER_PACKAGE),
        )
    }

    private fun isReadableContentUri(uri: Uri): Boolean {
        return try {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { true } ?: false
        } catch (e: Exception) {
            Log.w("Flick", "Failed to open external playback URI: $uri", e)
            false
        }
    }

    private fun resolveSourcePackage(intent: Intent): String? {
        val referrerUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_REFERRER, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_REFERRER)
        }

        packageNameFromReferrer(referrerUri)?.let { return it }

        val referrerName = intent.getStringExtra(Intent.EXTRA_REFERRER_NAME)
        packageNameFromReferrer(referrerName?.let(Uri::parse))?.let { return it }

        packageNameFromReferrer(referrer)?.let { return it }

        return null
    }

    private fun packageNameFromReferrer(uri: Uri?): String? {
        if (uri == null) return null
        if (uri.scheme == "android-app") {
            return uri.host?.takeIf { it.isNotBlank() }
        }
        return uri.host?.takeIf { it.isNotBlank() }
    }

    private fun returnToLocker(): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(LOCKER_RETURN_URI)).apply {
                `package` = LOCKER_PACKAGE
                addCategory(Intent.CATEGORY_BROWSABLE)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w("Flick", "Failed to return to Locker", e)
            false
        }
    }

    private fun getDocumentDisplayName(uriString: String): String? {
        android.util.Log.d("MainActivity", "[getDocumentDisplayName] Input URI: $uriString")
        return try {
            val uri = Uri.parse(uriString)
            android.util.Log.d("MainActivity", "[getDocumentDisplayName] Parsed URI: $uri")
            val fromSingle = DocumentFile.fromSingleUri(this, uri)?.name
            if (!fromSingle.isNullOrBlank()) {
                android.util.Log.d("MainActivity", "[getDocumentDisplayName] From single: $fromSingle")
                return fromSingle
            }

            val fromTree = DocumentFile.fromTreeUri(this, uri)?.name
            if (!fromTree.isNullOrBlank()) {
                android.util.Log.d("MainActivity", "[getDocumentDisplayName] From tree: $fromTree")
                return fromTree
            }

            contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    if (index >= 0) {
                        val name = cursor.getString(index)
                        android.util.Log.d("MainActivity", "[getDocumentDisplayName] From query: $name")
                        return name
                    }
                }
            }
            android.util.Log.d("MainActivity", "[getDocumentDisplayName] No name found")
            null
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "[getDocumentDisplayName] Error: ${e.message}", e)
            null
        }
    }

    private fun resolveTreeUriToPath(uriString: String): String? {
        return resolveStorageInfo(uriString)["fsPath"] as? String
    }

    // Single source of truth for filesystem path + MediaStore-volume routing, including
    // removable (USB/SD) volumes which queryMediaStoreAudio must target by their own name.
    private fun resolveStorageInfo(uriString: String): Map<String, Any?> {
        val allFiles = mapOf("allFilesAccess" to hasAllFilesAccess())
        val unknown = mapOf<String, Any?>(
            "fsPath" to null,
            "mediaStoreVolume" to null,
            "isRemovable" to false,
            "isPrimary" to false,
            "state" to "unknown",
        ) + allFiles
        return try {
            val uri = Uri.parse(uriString)
            if (uri.scheme == "file") {
                return mapOf(
                    "fsPath" to uri.path,
                    "mediaStoreVolume" to null,
                    "isRemovable" to false,
                    "isPrimary" to true,
                    "state" to "mounted",
                ) + allFiles
            }
            if (uri.scheme != "content" ||
                uri.authority != "com.android.externalstorage.documents"
            ) {
                return unknown
            }

            val documentId = DocumentsContract.getTreeDocumentId(uri)
            val decodedId = Uri.decode(documentId)
            val parts = decodedId.split(":", limit = 2)
            if (parts.isEmpty()) return unknown
            val volumeId = parts[0]
            val relativePath = parts.getOrNull(1)?.trim('/') ?: ""
            val isPrimaryDoc = volumeId.lowercase() == "primary" ||
                volumeId.lowercase() == "home"

            val sm = getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            val matched = sm?.storageVolumes?.firstOrNull { vol ->
                if (isPrimaryDoc) vol.isPrimary
                else vol.uuid?.equals(volumeId, ignoreCase = true) == true
            }

            if (matched != null) {
                val basePath = storageVolumePath(matched)
                val candidate = if (basePath == null) null
                    else if (relativePath.isEmpty()) basePath else "$basePath/$relativePath"
                val readable = candidate != null &&
                    File(candidate).let { it.exists() && it.canRead() }
                return mapOf(
                    "fsPath" to if (readable) candidate else null,
                    "mediaStoreVolume" to mediaStoreVolumeNameFor(volumeId, matched.isPrimary),
                    "isRemovable" to matched.isRemovable,
                    "isPrimary" to matched.isPrimary,
                    "state" to matched.state,
                ) + allFiles
            }

            // Legacy fallback when StorageManager didn't enumerate the volume.
            val basePath = when (volumeId.lowercase()) {
                "primary" -> Environment.getExternalStorageDirectory().absolutePath
                "home" -> Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOCUMENTS
                ).absolutePath
                else -> "/storage/$volumeId"
            }
            val candidate = if (relativePath.isEmpty()) basePath else "$basePath/$relativePath"
            val candidateFile = File(candidate)
            if (!candidateFile.exists() || !candidateFile.canRead()) return unknown

            mapOf(
                "fsPath" to candidateFile.absolutePath,
                "mediaStoreVolume" to mediaStoreVolumeNameFor(volumeId, isPrimaryDoc),
                "isRemovable" to !isPrimaryDoc,
                "isPrimary" to isPrimaryDoc,
                "state" to "mounted",
            ) + allFiles
        } catch (e: Exception) {
            Log.w("MainActivity", "resolveStorageInfo failed: ${e.message}", e)
            unknown
        }
    }

    private fun storageVolumePath(volume: StorageVolume): String? {
        // getDirectory() is API 30+; getPath() is hidden until then.
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            volume.directory?.absolutePath
        } else {
            try {
                val m = volume.javaClass.getMethod("getPath")
                m.invoke(volume) as? String
            } catch (e: Exception) {
                Log.w("MainActivity", "StorageVolume.getPath() reflection failed: ${e.message}")
                null
            }
        }
    }

    private fun mediaStoreVolumeNameFor(volumeId: String, isPrimary: Boolean): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        // Primary uses VOLUME_EXTERNAL_PRIMARY. For removable storage the
        // MediaStore volume name is the volume's FAT UUID (== volumeId here).
        // If MediaStore hasn't indexed that volume, the query yields 0 rows
        // and the caller falls back to SAF — safe degradation.
        return if (isPrimary) MediaStore.VOLUME_EXTERNAL_PRIMARY else volumeId
    }

    private fun deleteDocumentViaSaf(folderTreeUri: String, filePath: String): Boolean {
        return try {
            val fileUri = Uri.parse(filePath)

            if (fileUri.scheme == "content") {
                return try {
                    DocumentsContract.deleteDocument(contentResolver, fileUri)
                } catch (e: Exception) {
                    Log.w("MainActivity", "content URI deletion failed: ${e.message}")
                    false
                }
            }

            if (removeFromMediaStore(filePath)) return true

            try {
                val treeUri = Uri.parse(folderTreeUri)
                val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
                val decodedId = Uri.decode(treeDocId)
                val parts = decodedId.split(":", limit = 2)
                if (parts.isNotEmpty()) {
                    val volumeId = parts[0]
                    val relativeFolderPath = parts.getOrNull(1)?.trim('/') ?: ""
                    val basePath = when (volumeId.lowercase()) {
                        "primary" -> Environment.getExternalStorageDirectory().absolutePath
                        "home" -> Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOCUMENTS
                        ).absolutePath
                        else -> "/storage/$volumeId"
                    }

                    val folderBase = if (relativeFolderPath.isEmpty()) {
                        File(basePath)
                    } else {
                        File("$basePath/$relativeFolderPath")
                    }
                    val canonicalBase = folderBase.canonicalPath.trimEnd('/')
                    val canonicalFile = File(filePath).canonicalPath.trimEnd('/')

                    if (canonicalFile.startsWith("$canonicalBase/") || canonicalFile == canonicalBase) {
                        val relativePath = if (canonicalFile == canonicalBase) {
                            ""
                        } else {
                            canonicalFile.removePrefix("$canonicalBase/")
                        }

                        val childDocId = if (relativePath.isEmpty()) treeDocId else "$treeDocId/$relativePath"
                        val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childDocId)
                        if (DocumentsContract.deleteDocument(contentResolver, childUri)) return true
                    }
                }
            } catch (safEx: Exception) {
                Log.w("MainActivity", "SAF deletion failed, trying File.delete: ${safEx.message}")
            }

            try {
                val file = File(filePath)
                if (file.exists()) {
                    if (file.delete()) return true
                } else {
                    return true
                }
            } catch (fileEx: Exception) {
                Log.w("MainActivity", "File.delete failed: ${fileEx.message}")
            }

            false
        } catch (e: Exception) {
            Log.w("MainActivity", "deleteDocumentViaSaf failed: ${e.message}", e)
            false
        }
    }

    private fun removeFromMediaStore(filePath: String): Boolean {
        return try {
            val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            val rowsDeleted = contentResolver.delete(
                uri,
                "${MediaStore.Audio.Media.DATA} = ?",
                arrayOf(filePath)
            )
            rowsDeleted > 0
        } catch (e: Exception) {
            Log.w("MainActivity", "removeFromMediaStore failed: ${e.message}", e)
            false
        }
    }

    private fun writeFileBytesViaSaf(folderTreeUri: String, filePath: String, tempFilePath: String): Boolean {
        return try {
            val treeUri = Uri.parse(folderTreeUri)
            val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
            val decodedId = Uri.decode(treeDocId)
            val parts = decodedId.split(":", limit = 2)
            if (parts.isEmpty()) return false

            val volumeId = parts[0]
            val relativeFolderPath = parts.getOrNull(1)?.trim('/') ?: ""
            val basePath = when (volumeId.lowercase()) {
                "primary" -> Environment.getExternalStorageDirectory().absolutePath
                "home" -> Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOCUMENTS
                ).absolutePath
                else -> "/storage/$volumeId"
            }

            val folderBase = if (relativeFolderPath.isEmpty()) {
                File(basePath)
            } else {
                File("$basePath/$relativeFolderPath")
            }
            val canonicalBase = folderBase.canonicalPath.trimEnd('/')
            val canonicalFile = File(filePath).canonicalPath.trimEnd('/')

            if (!canonicalFile.startsWith("$canonicalBase/") && canonicalFile != canonicalBase) {
                Log.w("MainActivity", "writeFileBytesViaSaf: file $filePath is not under tree $folderTreeUri")
                return false
            }

            val relativePath = if (canonicalFile == canonicalBase) {
                ""
            } else {
                canonicalFile.removePrefix("$canonicalBase/")
            }

            val childDocId = if (relativePath.isEmpty()) treeDocId else "$treeDocId/$relativePath"
            val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childDocId)

            val tempFile = File(tempFilePath)
            if (!tempFile.exists()) {
                Log.w("MainActivity", "writeFileBytesViaSaf: temp file not found: $tempFilePath")
                return false
            }

            val bytes = tempFile.readBytes()
            contentResolver.openOutputStream(childUri, "wt")?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: run {
                Log.w("MainActivity", "writeFileBytesViaSaf: failed to open output stream for $childUri")
                return false
            }

            tempFile.delete()
            true
        } catch (e: Exception) {
            Log.w("MainActivity", "writeFileBytesViaSaf failed: ${e.message}", e)
            false
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
        return powerManager?.isIgnoringBatteryOptimizations(packageName) ?: false
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }

        try {
            val settingsIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(settingsIntent)
            return true
        } catch (e: Exception) {
            Log.w("MainActivity", "Failed to open battery optimization settings", e)
            return false
        }
    }

    // All Files Access (MANAGE_EXTERNAL_STORAGE): raw filesystem reads on every volume,
    // i.e. the UAPP/Neutron-style scanning precondition. Below Android 11 the legacy
    // storage permissions already give equivalent broad read access.
    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                Environment.isExternalStorageManager()
            } catch (e: Exception) {
                Log.w("MainActivity", "isExternalStorageManager() failed: ${e.message}")
                false
            }
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun openAllFilesAccessSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return false
        }
        return try {
            var intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            try {
                startActivity(intent)
                return true
            } catch (e: Exception) {
                Log.w("MainActivity", "App-specific all-files settings screen unavailable, trying global")
            }
            intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w("MainActivity", "Failed to open all-files-access settings", e)
            false
        }
    }

    private fun readTextDocument(uriString: String): String {
        android.util.Log.d("MainActivity", "[readTextDocument] Input URI: $uriString")
        val uri = Uri.parse(uriString)
        android.util.Log.d("MainActivity", "[readTextDocument] Parsed URI: $uri")
        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalStateException("Unable to open input stream")

        android.util.Log.d("MainActivity", "[readTextDocument] Read ${bytes.size} bytes")
        if (bytes.size >= 3 &&
            bytes[0] == 0xEF.toByte() &&
            bytes[1] == 0xBB.toByte() &&
            bytes[2] == 0xBF.toByte()
        ) {
            android.util.Log.d("MainActivity", "[readTextDocument] Detected UTF-8 BOM")
            return String(bytes.copyOfRange(3, bytes.size), Charsets.UTF_8)
        }
        return String(bytes, Charsets.UTF_8)
    }

    private fun writeTextDocument(uriString: String, content: String): Boolean {
        android.util.Log.d("MainActivity", "[writeTextDocument] Input URI: $uriString")
        android.util.Log.d("MainActivity", "[writeTextDocument] Content length: ${content.length}")
        val uri = Uri.parse(uriString)
        android.util.Log.d("MainActivity", "[writeTextDocument] Parsed URI: $uri")
        contentResolver.openOutputStream(uri, "wt")?.use { output ->
            output.write(content.toByteArray(Charsets.UTF_8))
            output.flush()
            android.util.Log.d("MainActivity", "[writeTextDocument] Write successful")
            return true
        }
        android.util.Log.e("MainActivity", "[writeTextDocument] Failed to open output stream")
        return false
    }

    // Phase 1: Fast Scan (Filesystem only)
    private data class TreeDocEntry(
        val documentId: String,
        val name: String,
        val mimeType: String?,
        val size: Long,
        val lastModified: Long,
    )

    // Walks a granted SAF tree with one contentResolver.query() per directory
    // (single IPC returning all columns) instead of per-attribute DocumentFile
    // calls. .nomedia short-circuits a subtree when [respectNomedia] is true.
    private fun listTreeDocuments(
        uriString: String,
        respectNomedia: Boolean,
    ): List<TreeDocEntry> {
        val treeUri = Uri.parse(uriString)
        val rootDocId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            return emptyList()
        }
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        val result = mutableListOf<TreeDocEntry>()
        val visited = HashSet<String>()
        var dirCount = 0

        fun scanDir(docId: String) {
            if (!visited.add(docId)) return
            dirCount++
            val childrenUri = try {
                DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            } catch (e: Exception) {
                return
            }
            val entries = mutableListOf<TreeDocEntry>()
            var hasNomedia = false
            try {
                val cursor = contentResolver.query(childrenUri, projection, null, null, null)
                if (cursor == null) {
                    Log.w("MainActivity", "SAF query null cursor: $childrenUri")
                }
                cursor?.use { c ->
                    val idIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                    val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    val mimeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    val sizeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                    val modIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                    while (c.moveToNext()) {
                        val name = if (nameIdx >= 0) c.getString(nameIdx) else null
                        if (name == null) continue
                        if (respectNomedia && name == ".nomedia") hasNomedia = true
                        val childDocId = if (idIdx >= 0) c.getString(idIdx) else null
                        if (childDocId == null) continue
                        entries.add(
                            TreeDocEntry(
                                documentId = childDocId,
                                name = name,
                                mimeType = if (mimeIdx >= 0) c.getString(mimeIdx) else null,
                                size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else 0L,
                                lastModified = if (modIdx >= 0 && !c.isNull(modIdx)) c.getLong(modIdx) else 0L,
                            ),
                        )
                    }
                }
            } catch (e: Exception) {
                Log.w("MainActivity", "listTreeDocuments query failed: ${e.message}", e)
            }
            if (hasNomedia) return
            for (e in entries) {
                if (e.mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    scanDir(e.documentId)
                } else {
                    result.add(e)
                }
            }
        }

        scanDir(rootDocId)
        Log.d("MainActivity", "SAF tree walk '$uriString' rootDocId=$rootDocId dirs=$dirCount files=${result.size}")
        return result
    }

    private fun fastScanAudioFiles(
        uriString: String,
        filterNonMusicFilesAndFolders: Boolean
    ): List<Map<String, Any?>> {
        val audioExtensions =
            setOf("mp3", "flac", "wav", "aac", "m4a", "ogg", "oga", "ogx", "opus", "wma", "alac", "aif", "aiff", "cue", "wv", "dsf", "dff")
        val treeUri = Uri.parse(uriString)

        return listTreeDocuments(uriString, filterNonMusicFilesAndFolders)
            .filter { entry ->
                !filterNonMusicFilesAndFolders ||
                    entry.name.substringAfterLast('.', "").lowercase() in audioExtensions
            }
            .map { entry ->
                val extension = entry.name.substringAfterLast('.', "").lowercase()
                mapOf(
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(treeUri, entry.documentId).toString(),
                    "name" to entry.name,
                    "size" to entry.size,
                    "lastModified" to entry.lastModified,
                    "mimeType" to entry.mimeType,
                    "extension" to extension,
                )
            }
    }

    private fun scanPlaylistFiles(
        uriString: String,
        filterNonMusicFilesAndFolders: Boolean
    ): List<Map<String, Any?>> {
        val playlistExtensions = setOf("m3u", "m3u8")
        val treeUri = Uri.parse(uriString)

        return listTreeDocuments(uriString, filterNonMusicFilesAndFolders)
            .filter { entry ->
                entry.name.substringAfterLast('.', "").lowercase() in playlistExtensions
            }
            .map { entry ->
                val extension = entry.name.substringAfterLast('.', "").lowercase()
                mapOf(
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(treeUri, entry.documentId).toString(),
                    "name" to entry.name,
                    "size" to entry.size,
                    "lastModified" to entry.lastModified,
                    "extension" to extension,
                )
            }
    }

    // Phase 2: Metadata Extraction (Targeted)
    // Uses coroutine parallelism — each chunk runs on its own MediaMetadataRetriever
    private suspend fun extractMetadataForFiles(uris: List<String>): List<Map<String, Any?>> {
        if (uris.isEmpty()) return emptyList()
        if (uris.size == 1) return listOf(extractSingleMetadata(uris[0]))

        val cores = Runtime.getRuntime().availableProcessors()
        val chunkCount = min(cores * 2, uris.size).coerceAtLeast(1)
        val chunkSize = (uris.size + chunkCount - 1) / chunkCount

        val chunks = uris.chunked(chunkSize)
        Log.d("MainActivity", "SAF metadata: files=${uris.size} parallelism=$chunkCount (cores=$cores)")

        return coroutineScope {
            chunks.map { chunk ->
                async(Dispatchers.IO) {
                    extractMetadataChunk(chunk)
                }
            }.awaitAll().flatten()
        }
    }

    private fun extractSingleMetadata(uriString: String): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, Uri.parse(uriString))
            readMetadataFields(retriever, uriString)
        } catch (e: Exception) {
            mapOf("uri" to uriString)
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    private fun extractMetadataChunk(uriStrings: List<String>): List<Map<String, Any?>> {
        val retriever = MediaMetadataRetriever()
        val results = mutableListOf<Map<String, Any?>>()
        var perFileMs = 0L

        for (uriString in uriStrings) {
            val t0 = System.currentTimeMillis()
            try {
                retriever.setDataSource(context, Uri.parse(uriString))
                results.add(readMetadataFields(retriever, uriString))
            } catch (e: Exception) {
                results.add(mapOf("uri" to uriString))
            }
            perFileMs += System.currentTimeMillis() - t0
        }

        try { retriever.release() } catch (_: Exception) {}
        if (uriStrings.isNotEmpty()) {
            Log.d("MainActivity", "SAF metadata chunk: files=${uriStrings.size} perFileAvg=${perFileMs / uriStrings.size}ms")
        }
        return results
    }

    private fun readMetadataFields(retriever: MediaMetadataRetriever, uriString: String): Map<String, Any?> {
        val metadata = mutableMapOf<String, Any?>("uri" to uriString)

        metadata["title"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
        metadata["artist"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
        metadata["album"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
        metadata["albumArtist"] = extractMetadataByKeyName(retriever, "METADATA_KEY_ALBUMARTIST")
        metadata["trackNumber"] = parseMetadataNumber(
            extractMetadataByKeyName(retriever, "METADATA_KEY_CD_TRACK_NUMBER")
        )
        metadata["discNumber"] = parseMetadataNumber(
            extractMetadataByKeyName(retriever, "METADATA_KEY_DISC_NUMBER")
        )
        metadata["bitrate"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
        metadata["mimeType"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val sampleRateStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_SAMPLERATE)
            if (sampleRateStr != null) {
                metadata["sampleRate"] = sampleRateStr.toIntOrNull()
            }

            val bitDepthStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITS_PER_SAMPLE)
            if (bitDepthStr != null) {
                metadata["bitDepth"] = bitDepthStr.toIntOrNull()
            }
        }

        val durationStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
        if (durationStr != null) {
            metadata["duration"] = durationStr.toLongOrNull()
        }

        return metadata
    }

    private fun extractEmbeddedArtwork(uriString: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, Uri.parse(uriString))
            retriever.embeddedPicture
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
                // Ignore
            }
        }
    }

    private fun extractMetadataByKeyName(
        retriever: MediaMetadataRetriever,
        keyName: String
    ): String? {
        return try {
            val key = MediaMetadataRetriever::class.java.getField(keyName).getInt(null)
            retriever.extractMetadata(key)
        } catch (_: Exception) {
            null
        }
    }

    private fun parseMetadataNumber(rawValue: String?): Int? {
        if (rawValue.isNullOrBlank()) return null
        val match = Regex("""\d+""").find(rawValue) ?: return null
        val value = match.value.toIntOrNull() ?: return null
        return if (value > 0) value else null
    }

    private fun queryMediaStoreAudio(folderPaths: List<String>, volumeName: String? = null): List<Map<String, Any?>> {
        val startedAt = System.nanoTime()
        val result = mutableListOf<Map<String, Any?>>()
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(volumeName ?: MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.ALBUM_ARTIST,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.TRACK,
            MediaStore.Audio.Media.YEAR,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATE_MODIFIED,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.COMPOSER,
        )

        val selection = if (folderPaths.isNotEmpty()) {
            folderPaths.joinToString(" OR ") { "${MediaStore.Audio.Media.DATA} LIKE ?" }
        } else null
        val selectionArgs = if (folderPaths.isNotEmpty()) {
            folderPaths.map { "$it%" }.toTypedArray()
        } else null

        val seenPaths = HashSet<String>()
        try {
            contentResolver.query(collection, projection, selection, selectionArgs, null)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
                val titleCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val albumIdCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
                val albumArtistCol = cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM_ARTIST)
                val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val trackCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TRACK)
                val yearCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.YEAR)
                val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
                val dateModCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_MODIFIED)
                val dateAddedCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED)

                while (cursor.moveToNext()) {
                    val data = cursor.getString(dataCol) ?: continue
                    seenPaths.add(data)
                    val extension = data.substringAfterLast('.', "").lowercase()

                    val id = cursor.getLong(idCol)
                    val contentUri = ContentUris.withAppendedId(
                        MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id
                    ).toString()

                    val duration = cursor.getLong(durationCol)
                    val size = cursor.getLong(sizeCol)

                    val rawTrack = cursor.getInt(trackCol)
                    val trackNumber = rawTrack % 1000
                    val discNumber = rawTrack / 1000

                    result.add(mapOf(
                        "uri" to contentUri,
                        "filePath" to data,
                        "name" to (data.substringAfterLast('/', "")),
                        "title" to (cursor.getString(titleCol) ?: ""),
                        "artist" to (cursor.getString(artistCol) ?: ""),
                        "album" to (cursor.getString(albumCol) ?: ""),
                        "albumArtist" to (if (albumArtistCol >= 0) cursor.getString(albumArtistCol) else null),
                        "duration" to duration,
                        "trackNumber" to (if (trackNumber > 0) trackNumber else null),
                        "discNumber" to (if (discNumber > 0) discNumber else null),
                        "year" to (cursor.getInt(yearCol).takeIf { it > 0 }),
                        "mimeType" to (cursor.getString(mimeCol)),
                        "extension" to extension,
                        "size" to size,
                        "lastModified" to (cursor.getLong(dateModCol) * 1000L),
                        "dateAdded" to (cursor.getLong(dateAddedCol) * 1000L),
                        "bitrate" to (if (duration > 0 && size > 0) ((size * 8) / (duration / 1000)).toString() else null),
                    ))
                }
            }

            // DSD (.dsf/.dff/.wv) is not classified as audio by some OEM
            // MediaScanners (ColorOS/Oppo/Realme, HiOS/Tecno/Infinix), so it
            // never reaches MediaStore.Audio.Media and the default scan drops
            // it. Pull these from the Files collection and merge, deduping by
            // filesystem path against the audio rows already collected.
            val dsdExtPatterns = listOf("%.dsf", "%.dff", "%.wv")
            val dsdSelection = if (folderPaths.isNotEmpty()) {
                val folderPart = folderPaths.joinToString(" OR ") {
                    "${MediaStore.Files.FileColumns.DATA} LIKE ?"
                }
                val extPart = dsdExtPatterns.joinToString(" OR ") {
                    "${MediaStore.Files.FileColumns.DATA} LIKE ?"
                }
                "($folderPart) AND ($extPart)"
            } else {
                dsdExtPatterns.joinToString(" OR ") {
                    "${MediaStore.Files.FileColumns.DATA} LIKE ?"
                }
            }
            val dsdSelectionArgs = (
                (if (folderPaths.isNotEmpty()) folderPaths.map { "$it%" } else emptyList())
                    + dsdExtPatterns
                ).toTypedArray()
            val dsdCollection =
                MediaStore.Files.getContentUri(volumeName ?: MediaStore.VOLUME_EXTERNAL)
            val dsdProjection = arrayOf(
                MediaStore.Files.FileColumns._ID,
                MediaStore.Files.FileColumns.DATA,
                MediaStore.Files.FileColumns.MIME_TYPE,
                MediaStore.Files.FileColumns.SIZE,
                MediaStore.Files.FileColumns.DATE_MODIFIED,
                MediaStore.Files.FileColumns.DATE_ADDED,
            )
            contentResolver.query(
                dsdCollection, dsdProjection, dsdSelection, dsdSelectionArgs, null
            )?.use { c ->
                val dIdCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val dDataCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATA)
                val dMimeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
                val dSizeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                val dModCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
                val dAddedCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_ADDED)
                while (c.moveToNext()) {
                    val data = c.getString(dDataCol) ?: continue
                    if (!seenPaths.add(data)) continue
                    val contentUri = ContentUris.withAppendedId(
                        dsdCollection, c.getLong(dIdCol)
                    ).toString()
                    result.add(mapOf(
                        "uri" to contentUri,
                        "filePath" to data,
                        "name" to (data.substringAfterLast('/', "")),
                        "title" to "",
                        "artist" to "",
                        "album" to "",
                        "albumArtist" to null,
                        "duration" to 0L,
                        "trackNumber" to null,
                        "discNumber" to null,
                        "year" to null,
                        "mimeType" to (if (!c.isNull(dMimeCol)) c.getString(dMimeCol) else null),
                        "extension" to data.substringAfterLast('.', "").lowercase(),
                        "size" to c.getLong(dSizeCol),
                        "lastModified" to (c.getLong(dModCol) * 1000L),
                        "dateAdded" to (c.getLong(dAddedCol) * 1000L),
                        "bitrate" to null,
                    ))
                }
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "MediaStore audio query failed: ${e.message}", e)
        }

        // Reconciliation walk: some OEM MediaScanners (MIUI/HyperOS, Vivo/
        // Funtouch, Honor) never index DSD into Audio.Media OR the Files
        // collection, so both queries above come back empty for .dsf/.dff/.wv
        // while FLAC scans fine. Stat-only raw walk recovers exactly those
        // files (readable paths only; primary always, removable under All
        // Files Access or a legacy grant) and a fire-and-forget scanFile lets
        // the indexer catch up for future scans.
        try {
            val missing = DsdReconciliation.findUnindexedDsdFiles(folderPaths, seenPaths)
            for (f in missing) {
                val data = f.absolutePath
                if (!seenPaths.add(data)) continue
                result.add(mapOf(
                    "uri" to "file://$data",
                    "filePath" to data,
                    "name" to f.name,
                    "title" to "",
                    "artist" to "",
                    "album" to "",
                    "albumArtist" to null,
                    "duration" to 0L,
                    "trackNumber" to null,
                    "discNumber" to null,
                    "year" to null,
                    "mimeType" to null,
                    "extension" to f.extension.lowercase(),
                    "size" to f.length(),
                    "lastModified" to f.lastModified(),
                    "dateAdded" to f.lastModified(),
                    "bitrate" to null,
                ))
            }
            if (missing.isNotEmpty()) {
                Log.d("MainActivity", "DSD reconciliation walk found ${missing.size} unindexed file(s)")
                healMediaStoreIndex(missing.map { it.absolutePath })
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "DSD reconciliation walk failed: ${e.message}", e)
        }

        val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000
        Log.d("MainActivity", "MediaStore audio query + DSD reconciliation returned ${result.size} rows in ${elapsedMs}ms")
        return result
    }

    /**
     * Best-effort index heal: ask MediaScanner to pick up files it missed.
     * OEMs that hard-skip DSD at the MIME layer will keep skipping — this is
     * a bonus, the reconciliation walk already covers correctness.
     */
    private fun healMediaStoreIndex(paths: List<String>) {
        if (paths.isEmpty()) return
        try {
            MediaScannerConnection.scanFile(
                applicationContext,
                paths.toTypedArray(),
                null,
                null,
            )
        } catch (e: Exception) {
            Log.w("MainActivity", "MediaScanner heal failed: ${e.message}")
        }
    }

    private fun queryMediaStoreNonAudio(folderPaths: List<String>, volumeName: String? = null): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return result
        }

        val collection = MediaStore.Files.getContentUri(volumeName ?: MediaStore.VOLUME_EXTERNAL)

        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
        )

        val nonAudioExtensions = setOf("cue", "log", "txt", "m3u", "m3u8")

        val folderConditions = folderPaths.map { "${MediaStore.Files.FileColumns.DATA} LIKE ?" }
        val extConditions = nonAudioExtensions.map { "${MediaStore.Files.FileColumns.DATA} LIKE ?" }

        val selection = buildString {
            if (folderConditions.isNotEmpty()) {
                append("(")
                append(folderConditions.joinToString(" OR "))
                append(")")
            }
            if (extConditions.isNotEmpty()) {
                if (isNotEmpty()) append(" AND ")
                append("(")
                append(extConditions.joinToString(" OR "))
                append(")")
            }
        }

        val selectionArgs = (
            folderPaths.map { "$it%" } +
            nonAudioExtensions.map { "%.$it" }
        ).toTypedArray()

        try {
            contentResolver.query(collection, projection, selection, selectionArgs, null)?.use { cursor ->
                val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATA)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                val dateModCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
                val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)

                while (cursor.moveToNext()) {
                    val data = cursor.getString(dataCol) ?: continue
                    val extension = data.substringAfterLast('.', "").lowercase()
                    if (extension !in nonAudioExtensions) continue

                    val isInFolder = folderPaths.any { data.startsWith(it) }
                    if (!isInFolder && folderPaths.isNotEmpty()) continue

                    result.add(mapOf(
                        "filePath" to data,
                        "name" to (cursor.getString(nameCol) ?: ""),
                        "extension" to extension,
                        "size" to cursor.getLong(sizeCol),
                        "lastModified" to (cursor.getLong(dateModCol) * 1000L),
                        "mimeType" to cursor.getString(mimeCol),
                    ))
                }
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "MediaStore non-audio query failed: ${e.message}", e)
        }

        return result
    }

    private fun queryMediaStoreDeletions(filePaths: List<String>, volumeName: String? = null): List<String> {
        if (filePaths.isEmpty()) return emptyList()

        val existingPaths = mutableSetOf<String>()
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(volumeName ?: MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

        val projection = arrayOf(MediaStore.Audio.Media.DATA)

        try {
            contentResolver.query(collection, projection, null, null, null)?.use { cursor ->
                val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
                while (cursor.moveToNext()) {
                    cursor.getString(dataCol)?.let { existingPaths.add(it) }
                }
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "MediaStore deletion check failed: ${e.message}", e)
            return emptyList()
        }

        val deleted = filePaths.filter { !existingPaths.contains(it) }
        // DSD isn't indexed in Audio.Media on some OEMs, so it is always absent
        // here. Confirm via the filesystem before declaring a DSD file deleted.
        val dsdExtensions = setOf("dsf", "dff", "wv")
        return deleted.filterNot { path ->
            path.substringAfterLast('.', "").lowercase() in dsdExtensions &&
                java.io.File(path).exists()
        }
    }

    private fun registerMediaStoreObserver() {
        val notify = {
            try {
                mediaStoreEventSink?.success(mapOf("type" to "changed"))
            } catch (_: Exception) {}
        }
        if (mediaStoreContentObserver == null) {
            mediaStoreContentObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) {
                    super.onChange(selfChange)
                    notify()
                }
            }
            try {
                contentResolver.registerContentObserver(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    true,
                    mediaStoreContentObserver!!
                )
            } catch (e: Exception) {
                Log.w("MainActivity", "Audio observer registration failed: ${e.message}")
                mediaStoreContentObserver = null
            }
        }
        // Some DSD lands in the Files collection (never in Audio.Media on these
        // OEMs), so watch it too for live-change nudges.
        if (mediaFilesContentObserver == null) {
            val filesUri =
                MediaStore.Files.getContentUri(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        MediaStore.VOLUME_EXTERNAL
                    } else {
                        "external"
                    }
                )
            mediaFilesContentObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) {
                    super.onChange(selfChange)
                    notify()
                }
            }
            try {
                contentResolver.registerContentObserver(filesUri, true, mediaFilesContentObserver!!)
            } catch (e: Exception) {
                Log.w("MainActivity", "Files observer registration failed: ${e.message}")
                mediaFilesContentObserver = null
            }
        }
    }

    private fun unregisterMediaStoreObserver() {
        mediaStoreContentObserver?.let {
            contentResolver.unregisterContentObserver(it)
        }
        mediaStoreContentObserver = null
        mediaFilesContentObserver?.let {
            contentResolver.unregisterContentObserver(it)
        }
        mediaFilesContentObserver = null
    }

    private fun cacheUriForPlayback(
        uriString: String,
        extensionHint: String?,
        maxSizeBytes: Long? = null,
    ): String? {
        val uri = Uri.parse(uriString)
        val normalizedExt = resolveStagedExtension(uri, extensionHint)
        val stagingDir = java.io.File(cacheDir, "playback_staging").apply { mkdirs() }
        val fileHash = md5(uriString)
        val stagedFile = java.io.File(stagingDir, "$fileHash.$normalizedExt")
        val tempFile = java.io.File(stagingDir, "$fileHash.$normalizedExt.tmp")

        try {
            // Reuse cached file only when non-empty and likely complete.
            val expectedLength = try {
                contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                    if (afd.length > 0L) afd.length else null
                }
            } catch (_: Exception) {
                null
            }
            if (stagedFile.exists() && stagedFile.length() > 0L) {
                if (expectedLength == null || stagedFile.length() == expectedLength) {
                    return stagedFile.absolutePath
                }
            }

            // Optional caller-supplied cap (metadata enrichment on huge files):
            // bail before copying when the source is larger than allowed.
            if (maxSizeBytes != null && expectedLength != null && expectedLength > maxSizeBytes) {
                return null
            }

            if (tempFile.exists()) {
                tempFile.delete()
            }

            val inputStream = contentResolver.openInputStream(uri)
            if (inputStream == null) {
                // If provider temporarily fails, keep using last known-good staged file.
                if (stagedFile.exists() && stagedFile.length() > 0L) {
                    return stagedFile.absolutePath
                }
                return null
            }

            inputStream.use { input ->
                tempFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }

            if (!tempFile.exists() || tempFile.length() <= 0L) {
                tempFile.delete()
                return null
            }

            if (stagedFile.exists()) {
                stagedFile.delete()
            }
            if (!tempFile.renameTo(stagedFile)) {
                // Fallback: explicit copy and cleanup if rename fails.
                tempFile.inputStream().use { input ->
                    stagedFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                tempFile.delete()
            }

            if (stagedFile.length() <= 0L) return null
            return stagedFile.absolutePath
        } catch (e: Exception) {
            android.util.Log.e("FlickPlayback", "cacheUriForPlayback failed for $uriString: ${e.message}", e)
            return null
        } finally {
            if (tempFile.exists()) {
                tempFile.delete()
            }
        }
    }

    private fun readSiblingLyrics(audioUriString: String): Map<String, String>? {
        return try {
            val audioUri = Uri.parse(audioUriString)
            when (audioUri.scheme) {
                "content" -> readSiblingLyricsFromContentUri(audioUri)
                "file" -> readSiblingLyricsFromFilePath(audioUri.path)
                null, "" -> readSiblingLyricsFromFilePath(audioUriString)
                else -> null
            }
        } catch (e: Exception) {
            android.util.Log.w("FlickLyrics", "readSiblingLyrics failed for $audioUriString: ${e.message}")
            null
        }
    }

    private fun readEmbeddedLyrics(audioUriString: String): Map<String, String>? {
        val retriever = MediaMetadataRetriever()
        return try {
            val uri = Uri.parse(audioUriString)

            val handledByUri = when (uri.scheme) {
                "content", "file" -> {
                    retriever.setDataSource(this, uri)
                    true
                }
                else -> false
            }

            if (!handledByUri) {
                retriever.setDataSource(audioUriString)
            }

            val lyricKey = try {
                MediaMetadataRetriever::class.java.getField("METADATA_KEY_LYRIC").getInt(null)
            } catch (_: Exception) {
                null
            }

            val lyricText = lyricKey?.let { retriever.extractMetadata(it) }
            if (lyricText.isNullOrBlank()) {
                val id3Lyrics = parseId3EmbeddedLyrics(audioUriString)
                if (!id3Lyrics.isNullOrBlank()) {
                    mapOf(
                        "content" to id3Lyrics,
                        "source" to "embedded:id3",
                    )
                    } else {
                        val flacVorbisLyrics = parseFlacVorbisLyrics(audioUriString)
                        if (!flacVorbisLyrics.isNullOrBlank()) {
                            mapOf(
                                "content" to flacVorbisLyrics,
                                "source" to "embedded:vorbis",
                            )
                        } else {
                            val mp4Lyrics = parseMp4Lyrics(audioUriString)
                            if (!mp4Lyrics.isNullOrBlank()) {
                                mapOf(
                                    "content" to mp4Lyrics,
                                    "source" to "embedded:mp4",
                                )
                            } else {
                                // ponytail: covers ID3/FLAC/MP4/Ogg; WMA and APE tags not parsed
                                val oggLyrics = parseOggLyrics(audioUriString)
                                if (!oggLyrics.isNullOrBlank()) {
                                    mapOf(
                                        "content" to oggLyrics,
                                        "source" to "embedded:ogg",
                                    )
                                } else {
                                    null
                                }
                            }
                        }
                    }
            } else {
                mapOf(
                    "content" to lyricText,
                    "source" to "embedded",
                )
            }
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun parseId3EmbeddedLyrics(audioUriString: String): String? {
        return openAudioInputStream(audioUriString)?.use { input ->
            val header = ByteArray(10)
            if (!readExact(input, header)) return@use null
            if (header[0] != 'I'.code.toByte() ||
                header[1] != 'D'.code.toByte() ||
                header[2] != '3'.code.toByte()
            ) {
                return@use null
            }

            val version = header[3].toInt() and 0xFF
            val flags = header[5].toInt() and 0xFF
            val tagSize = readSynchsafeInt(header, 6)
            if (tagSize <= 0) return@use null

            val tagBody = ByteArray(tagSize)
            if (!readExact(input, tagBody)) return@use null

            val unsyncFlagSet = (flags and 0x80) != 0
            val data = if (unsyncFlagSet) deUnsynchronize(tagBody) else tagBody

            when (version) {
                2 -> parseId3v22Lyrics(data)
                3, 4 -> parseId3v23Or24Lyrics(data, version, flags)
                else -> null
            }
        }
    }

    private fun parseId3v22Lyrics(data: ByteArray): String? {
        var pos = 0
        var bestSync: String? = null
        var bestUnsync: String? = null

        while (pos + 6 <= data.size) {
            val id = String(data, pos, 3, Charsets.ISO_8859_1)
            if (id.all { it == '\u0000' }) break

            val frameSize =
                ((data[pos + 3].toInt() and 0xFF) shl 16) or
                ((data[pos + 4].toInt() and 0xFF) shl 8) or
                (data[pos + 5].toInt() and 0xFF)
            pos += 6
            if (frameSize <= 0 || pos + frameSize > data.size) break

            val frameData = data.copyOfRange(pos, pos + frameSize)
            when (id) {
                "SLT" -> {
                    val parsed = parseSyltFrame(frameData)
                    if (!parsed.isNullOrBlank()) bestSync = parsed
                }
                "ULT" -> {
                    val parsed = parseUsltFrame(frameData)
                    if (!parsed.isNullOrBlank() && bestUnsync == null) {
                        bestUnsync = parsed
                    }
                }
            }
            pos += frameSize
        }

        return bestSync ?: bestUnsync
    }

    private fun parseId3v23Or24Lyrics(data: ByteArray, version: Int, flags: Int): String? {
        var pos = 0
        val extendedHeaderFlagSet = (flags and 0x40) != 0
        if (extendedHeaderFlagSet && data.size >= 4) {
            val extSize = if (version == 4) {
                readSynchsafeInt(data, 0)
            } else {
                readBigEndianInt(data, 0)
            }
            if (extSize > 0 && extSize < data.size) {
                pos = if (version == 3) 4 + extSize else extSize
            }
        }

        var bestSync: String? = null
        var bestUnsync: String? = null

        while (pos + 10 <= data.size) {
            val id = String(data, pos, 4, Charsets.ISO_8859_1)
            if (id.all { it == '\u0000' }) break

            val frameSize = if (version == 4) {
                readSynchsafeInt(data, pos + 4)
            } else {
                readBigEndianInt(data, pos + 4)
            }
            pos += 10
            if (frameSize <= 0 || pos + frameSize > data.size) break

            val frameData = data.copyOfRange(pos, pos + frameSize)
            when (id) {
                "SYLT" -> {
                    val parsed = parseSyltFrame(frameData)
                    if (!parsed.isNullOrBlank()) bestSync = parsed
                }
                "USLT" -> {
                    val parsed = parseUsltFrame(frameData)
                    if (!parsed.isNullOrBlank() && bestUnsync == null) {
                        bestUnsync = parsed
                    }
                }
            }
            pos += frameSize
        }

        return bestSync ?: bestUnsync
    }

    private fun parseUsltFrame(frameData: ByteArray): String? {
        if (frameData.size < 4) return null

        val encoding = frameData[0].toInt() and 0xFF
        val descriptorStart = 4 // 1-byte encoding + 3-byte language
        val termLen = nullTerminatorLength(encoding)
        val descriptorEnd = findTerminator(frameData, descriptorStart, encoding)
        val textStart = when {
            descriptorEnd >= 0 -> descriptorEnd + termLen
            else -> descriptorStart
        }
        if (textStart >= frameData.size) return null

        val raw = frameData.copyOfRange(textStart, frameData.size)
        val text = decodeId3Text(raw, encoding).trim()
        return text.ifBlank { null }
    }

    private fun parseSyltFrame(frameData: ByteArray): String? {
        if (frameData.size < 7) return null

        val encoding = frameData[0].toInt() and 0xFF
        val timestampFormat = frameData[4].toInt() and 0xFF
        val descriptorStart = 6 // + content type byte
        val termLen = nullTerminatorLength(encoding)
        val descriptorEnd = findTerminator(frameData, descriptorStart, encoding)
        var pos = if (descriptorEnd >= 0) descriptorEnd + termLen else descriptorStart
        if (pos >= frameData.size) return null

        val lines = mutableListOf<String>()
        while (pos < frameData.size) {
            val textEnd = findTerminator(frameData, pos, encoding)
            if (textEnd < 0) break

            val textBytes = frameData.copyOfRange(pos, textEnd)
            val text = decodeId3Text(textBytes, encoding).trim()
            pos = textEnd + termLen
            if (pos + 4 > frameData.size) break

            val timestamp = readBigEndianInt(frameData, pos)
            pos += 4
            if (text.isBlank()) continue

            val timeMs = when (timestampFormat) {
                1 -> timestamp // milliseconds
                else -> timestamp // fallback for MPEG frames or unknown
            }.coerceAtLeast(0)
            lines.add("${formatLrcTime(timeMs)}$text")
        }

        if (lines.isEmpty()) return null
        return lines.joinToString(separator = "\n")
    }

    private fun parseFlacVorbisLyrics(audioUriString: String): String? {
        return openAudioInputStream(audioUriString)?.use { input ->
            val signature = ByteArray(4)
            if (!readExact(input, signature)) return@use null
            if (!signature.contentEquals(byteArrayOf('f'.code.toByte(), 'L'.code.toByte(), 'a'.code.toByte(), 'C'.code.toByte()))) {
                return@use null
            }

            var isLastBlock = false
            while (!isLastBlock) {
                val header = input.read()
                if (header < 0) break

                isLastBlock = (header and 0x80) != 0
                val blockType = header and 0x7F
                val lengthBytes = ByteArray(3)
                if (!readExact(input, lengthBytes)) break
                val blockLength =
                    ((lengthBytes[0].toInt() and 0xFF) shl 16) or
                    ((lengthBytes[1].toInt() and 0xFF) shl 8) or
                    (lengthBytes[2].toInt() and 0xFF)

                if (blockLength < 0) break

                if (blockType == 4) {
                    val commentData = ByteArray(blockLength)
                    if (!readExact(input, commentData)) break
                    return@use parseVorbisCommentLyrics(commentData)
                } else {
                    if (!skipFully(input, blockLength.toLong())) break
                }
            }
            null
        }
    }

    private fun parseOggLyrics(audioUriString: String): String? {
        return openAudioInputStream(audioUriString)?.use { input ->
            val magic = ByteArray(4)
            if (!readExact(input, magic) || String(magic, Charsets.ISO_8859_1) != "OggS") {
                return@use null
            }

            var packetIndex = 0
            val packet = ByteArrayOutputStream()
            val pageHeader = ByteArray(23)
            while (true) {
                if (!readExact(input, pageHeader)) return@use null
                val segmentCount = pageHeader[22].toInt() and 0xFF
                if (segmentCount > 0) {
                    val segmentTable = ByteArray(segmentCount)
                    if (!readExact(input, segmentTable)) return@use null

                    for (i in 0 until segmentCount) {
                        val segmentLength = segmentTable[i].toInt() and 0xFF
                        val chunk = ByteArray(segmentLength)
                        if (!readExact(input, chunk)) return@use null
                        packet.write(chunk)

                        if (segmentLength < 255) {
                            // Packet 1 is the Vorbis/Opus comment header
                            if (packetIndex == 1) {
                                return@use parseVorbisCommentLyrics(packet.toByteArray())
                            }
                            packetIndex++
                            packet.reset()
                        }
                    }
                }
            }
            null
        }
    }

    private fun parseMp4Lyrics(audioUriString: String): String? {
        return openAudioInputStream(audioUriString)?.use { input ->
            val knownTopLevel = setOf("ftyp", "moov", "mdat", "free", "skip", "wide", "pnot")
            while (true) {
                val atom = readMp4AtomHeader(input) ?: return@use null
                if (!knownTopLevel.contains(atom.type)) return@use null
                if (atom.type == "moov") {
                    return@use walkMp4Container(input, atom.contentSize, setOf("udta", "meta"))
                }
                if (!skipFully(input, atom.contentSize)) return@use null
            }
            null
        }
    }

    private class Mp4Atom(val type: String, val contentSize: Long)

    private fun readMp4AtomHeader(input: InputStream): Mp4Atom? {
        val header = ByteArray(8)
        if (!readExact(input, header)) return null
        var size = readBigEndianInt(header, 0).toLong() and 0xFFFFFFFFL
        val type = String(header, 4, 4, Charsets.ISO_8859_1)

        if (size == 1L) {
            val ext = ByteArray(8)
            if (!readExact(input, ext)) return null
            var bigSize = 0L
            for (b in ext) bigSize = (bigSize shl 8) or (b.toLong() and 0xFF)
            if (bigSize < 16) return null
            size = bigSize - 16
        } else if (size == 0L) {
            // Atom extends to end of file; treat as huge
            size = Long.MAX_VALUE / 4
        } else {
            size -= 8
        }

        if (size < 0) return null
        return Mp4Atom(type, size)
    }

    // Walks an atom's children, consuming exactly containerSize bytes.
    // Returns lyrics text from a ©lyr item, or null after consuming the container.
    private fun walkMp4Container(input: InputStream, containerSize: Long, childTypes: Set<String>): String? {
        var remaining = containerSize
        while (remaining >= 8) {
            val atom = readMp4AtomHeader(input) ?: return null
            remaining -= 8
            if (atom.contentSize > remaining) return null
            remaining -= atom.contentSize

            if (atom.type == "\u00A9lyr") {
                return readMp4LyricsData(input, atom.contentSize)
            }

            if (childTypes.contains(atom.type)) {
                var payload = atom.contentSize
                if (atom.type == "meta") {
                    // meta is a FullBox: 4 version/flags bytes precede children
                    if (payload < 4) return null
                    val versionFlags = ByteArray(4)
                    if (!readExact(input, versionFlags)) return null
                    payload -= 4
                }
                val next = when (atom.type) {
                    "moov" -> setOf("udta", "meta")
                    "udta" -> setOf("meta")
                    "meta" -> setOf("ilst")
                    else -> emptySet()
                }
                val found = walkMp4Container(input, payload, next)
                if (found != null) return found
            } else {
                if (!skipFully(input, atom.contentSize)) return null
            }
        }
        if (remaining > 0) skipFully(input, remaining)
        return null
    }

    private fun readMp4LyricsData(input: InputStream, itemSize: Long): String? {
        var remaining = itemSize
        while (remaining >= 8) {
            val atom = readMp4AtomHeader(input) ?: return null
            remaining -= 8
            if (atom.contentSize > remaining) return null
            remaining -= atom.contentSize

            if (atom.type == "data" && atom.contentSize >= 8) {
                val header = ByteArray(8)
                if (!readExact(input, header)) return null
                val payloadLength = (atom.contentSize - 8).toInt()
                if (payloadLength <= 0) return null
                val payload = ByteArray(payloadLength)
                if (!readExact(input, payload)) return null

                val typeIndicator =
                    ((header[1].toInt() and 0xFF) shl 16) or
                        ((header[2].toInt() and 0xFF) shl 8) or
                        (header[3].toInt() and 0xFF)
                // ponytail: type 2 is UTF-16; UTF_16 charset honors a BOM when present
                val text = when (typeIndicator) {
                    2 -> payload.toString(Charsets.UTF_16)
                    else -> payload.toString(Charsets.UTF_8)
                }.replace("\u0000", "").trim()
                return text.ifBlank { null }
            }

            if (!skipFully(input, atom.contentSize)) return null
        }
        return null
    }

    private fun parseVorbisCommentLyrics(data: ByteArray): String? {
        if (data.size < 8) return null
        val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)

        val vendorLength = readLeIntSafe(buffer) ?: return null
        if (vendorLength < 0 || vendorLength > buffer.remaining()) return null
        buffer.position(buffer.position() + vendorLength)

        val commentCount = readLeIntSafe(buffer) ?: return null
        if (commentCount < 0) return null

        val wantedKeys = listOf(
            "LYRICS",
            "UNSYNCEDLYRICS",
            "UNSYNCED_LYRICS",
        )

        repeat(commentCount) {
            val len = readLeIntSafe(buffer) ?: return null
            if (len < 0 || len > buffer.remaining()) return null

            val bytes = ByteArray(len)
            buffer.get(bytes)
            val entry = bytes.toString(Charsets.UTF_8)
            val sep = entry.indexOf('=')
            if (sep <= 0) return@repeat

            val key = entry.substring(0, sep).uppercase()
            val value = entry.substring(sep + 1).trim()
            if (value.isBlank()) return@repeat
            if (wantedKeys.contains(key)) {
                return value
            }
        }

        return null
    }

    private fun openAudioInputStream(audioUriString: String): InputStream? {
        return try {
            val uri = Uri.parse(audioUriString)
            when (uri.scheme) {
                "content" -> contentResolver.openInputStream(uri)
                "file" -> {
                    val path = uri.path
                    if (path.isNullOrBlank()) null else FileInputStream(path)
                }
                null, "" -> FileInputStream(File(audioUriString))
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun readExact(input: InputStream, out: ByteArray): Boolean {
        var offset = 0
        while (offset < out.size) {
            val read = input.read(out, offset, out.size - offset)
            if (read <= 0) return false
            offset += read
        }
        return true
    }

    private fun skipFully(input: InputStream, bytesToSkip: Long): Boolean {
        var remaining = bytesToSkip
        while (remaining > 0) {
            val skipped = input.skip(remaining)
            if (skipped <= 0) {
                if (input.read() == -1) return false
                remaining -= 1
            } else {
                remaining -= skipped
            }
        }
        return true
    }

    private fun readSynchsafeInt(data: ByteArray, offset: Int): Int {
        if (offset + 3 >= data.size) return 0
        return ((data[offset].toInt() and 0x7F) shl 21) or
            ((data[offset + 1].toInt() and 0x7F) shl 14) or
            ((data[offset + 2].toInt() and 0x7F) shl 7) or
            (data[offset + 3].toInt() and 0x7F)
    }

    private fun readBigEndianInt(data: ByteArray, offset: Int): Int {
        if (offset + 3 >= data.size) return 0
        return ((data[offset].toInt() and 0xFF) shl 24) or
            ((data[offset + 1].toInt() and 0xFF) shl 16) or
            ((data[offset + 2].toInt() and 0xFF) shl 8) or
            (data[offset + 3].toInt() and 0xFF)
    }

    private fun readLeIntSafe(buffer: ByteBuffer): Int? {
        if (buffer.remaining() < 4) return null
        return buffer.int
    }

    private fun deUnsynchronize(data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(data.size)
        var i = 0
        while (i < data.size) {
            val current = data[i]
            if (current == 0xFF.toByte() &&
                i + 1 < data.size &&
                data[i + 1] == 0x00.toByte()
            ) {
                out.write(0xFF)
                i += 2
            } else {
                out.write(current.toInt())
                i += 1
            }
        }
        return out.toByteArray()
    }

    private fun decodeId3Text(bytes: ByteArray, encoding: Int): String {
        if (bytes.isEmpty()) return ""
        val charset = when (encoding) {
            0 -> Charsets.ISO_8859_1
            1 -> Charsets.UTF_16
            2 -> Charsets.UTF_16BE
            3 -> Charsets.UTF_8
            else -> Charsets.UTF_8
        }
        return bytes.toString(charset).replace("\u0000", "")
    }

    private fun findTerminator(data: ByteArray, start: Int, encoding: Int): Int {
        val termLen = nullTerminatorLength(encoding)
        if (termLen == 1) {
            for (i in start until data.size) {
                if (data[i] == 0.toByte()) return i
            }
            return -1
        }

        var i = start
        while (i + 1 < data.size) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) return i
            i++
        }
        return -1
    }

    private fun nullTerminatorLength(encoding: Int): Int {
        return when (encoding) {
            1, 2 -> 2
            else -> 1
        }
    }

    private fun formatLrcTime(milliseconds: Int): String {
        val clampedMs = milliseconds.coerceAtLeast(0)
        val minutes = clampedMs / 60000
        val seconds = (clampedMs % 60000) / 1000
        val hundredths = (clampedMs % 1000) / 10
        return "[${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}.${hundredths.toString().padStart(2, '0')}]"
    }

    private fun readSiblingLyricsFromContentUri(audioUri: Uri): Map<String, String>? {
        val audioName = DocumentFile.fromSingleUri(this, audioUri)?.name ?: return null
        val stem = audioName.substringBeforeLast('.', audioName)
        val candidateNames = listOf("$stem.lrc", "$stem.txt", "$stem.xml")
        val candidateSet = candidateNames.map { it.lowercase() }.toSet()

        val authority = audioUri.authority ?: return null
        val documentId = try {
            DocumentsContract.getDocumentId(audioUri)
        } catch (e: Exception) {
            return null
        }
        val slashIndex = documentId.lastIndexOf('/')
        if (slashIndex <= 0) return null
        val parentDocumentId = documentId.substring(0, slashIndex)

        // Fast path: build candidate URIs directly using parent document id.
        for (candidateName in candidateNames) {
            val candidateDocumentId = "$parentDocumentId/$candidateName"
            val directUri = DocumentsContract.buildDocumentUri(authority, candidateDocumentId)
            val directContent = readTextFromUri(directUri)
            if (!directContent.isNullOrBlank()) {
                return mapOf(
                    "content" to directContent,
                    "uri" to directUri.toString(),
                    "name" to candidateName,
                )
            }

            val treeUri = try {
                DocumentsContract.buildDocumentUriUsingTree(audioUri, candidateDocumentId)
            } catch (_: Exception) {
                null
            }
            if (treeUri != null) {
                val treeContent = readTextFromUri(treeUri)
                if (!treeContent.isNullOrBlank()) {
                    return mapOf(
                        "content" to treeContent,
                        "uri" to treeUri.toString(),
                        "name" to candidateName,
                    )
                }
            }
        }

        // Fallback: list siblings from parent and match candidate names case-insensitively.
        val childrenUri = try {
            DocumentsContract.buildChildDocumentsUri(authority, parentDocumentId)
        } catch (e: Exception) {
            return null
        }

        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            if (idIndex == -1 || nameIndex == -1) {
                return null
            }

            while (cursor.moveToNext()) {
                val displayName = cursor.getString(nameIndex) ?: continue
                if (!candidateSet.contains(displayName.lowercase())) continue

                val childDocumentId = cursor.getString(idIndex) ?: continue
                val childUri = DocumentsContract.buildDocumentUri(authority, childDocumentId)
                val content = readTextFromUri(childUri)
                if (!content.isNullOrBlank()) {
                    return mapOf(
                        "content" to content,
                        "uri" to childUri.toString(),
                        "name" to displayName,
                    )
                }
            }
        }

        return null
    }

    private fun readSiblingLyricsFromFilePath(audioPath: String?): Map<String, String>? {
        if (audioPath.isNullOrBlank()) return null

        val audioFile = java.io.File(audioPath)
        val parent = audioFile.parentFile ?: return null
        val stem = audioFile.name.substringBeforeLast('.', audioFile.name)
        val candidateNames = listOf("$stem.lrc", "$stem.txt", "$stem.xml", "$stem.LRC", "$stem.TXT", "$stem.XML")

        for (candidateName in candidateNames) {
            val candidateFile = java.io.File(parent, candidateName)
            if (!candidateFile.exists() || !candidateFile.isFile) continue

            val text = try {
                candidateFile.readText(Charsets.UTF_8)
            } catch (_: Exception) {
                try {
                    candidateFile.readText(Charsets.ISO_8859_1)
                } catch (_: Exception) {
                    null
                }
            }

            if (!text.isNullOrBlank()) {
                return mapOf(
                    "content" to text,
                    "uri" to candidateFile.absolutePath,
                    "name" to candidateFile.name,
                )
            }
        }

        return null
    }

    private fun readTextFromUri(uri: Uri): String? {
        return try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
        } catch (_: Exception) {
            null
        }
    }

    private fun normalizeAudioExtension(extensionHint: String?): String {
        val ext = extensionHint
            ?.trim()
            ?.lowercase()
            ?.removePrefix(".")
            ?.ifEmpty { null } ?: return "m4a"

        return when (ext) {
            "aif", "aiff" -> "aiff"
            "m4a", "alac" -> "m4a"
            else -> ext
        }
    }

    // The provider's display name carries the real container extension (e.g.
    // .dsf/.dff for DSD), which generic mime-derived hints (e.g. "dsd") lose.
    private fun resolveStagedExtension(uri: Uri, extensionHint: String?): String {
        val providerExt = try {
            contentResolver
                .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && cursor.moveToFirst()) {
                        cursor.getString(nameIndex)
                            ?.substringAfterLast('.', "")
                            ?.lowercase()
                            ?.ifEmpty { null }
                    } else {
                        null
                    }
                }
        } catch (_: Exception) {
            null
        }

        // Only trust the provider name when it is a plausible audio extension.
        return if (providerExt != null && providerExt.length in 2..5 && providerExt.all { it.isLetterOrDigit() }) {
            providerExt
        } else {
            normalizeAudioExtension(extensionHint)
        }
    }

    private fun md5(input: String): String {
        val digest = MessageDigest.getInstance("MD5").digest(input.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun ensurePluginsRegistered(engine: FlutterEngine) {
        synchronized(pluginRegistrationLock) {
            val engineIdentity = System.identityHashCode(engine)
            if (registeredMainEngineIdentity == engineIdentity) {
                return
            }

            GeneratedPluginRegistrant.registerWith(engine)
            registeredMainEngineIdentity = engineIdentity
        }
    }

    // ========== UAC 2.0 USB Host (Android) ==========

    private fun listUac2Devices(refresh: Boolean = false): List<Map<String, Any?>> {
        if (!refresh && uac2DeviceCache != null) {
            return uac2DeviceCache!!
        }
        
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
        if (usbManager == null) {
            android.util.Log.e("UAC2", "USB service unavailable")
            return emptyList()
        }
        
        val routeLabelHint = currentRouteLabelHint()
        val deviceList = usbManager.deviceList ?: return emptyList()
        val result = mutableListOf<Map<String, Any?>>()
        
        for (device in deviceList.values) {
            try {
                if (!isLikelyUsbAudioDevice(device, routeLabelHint)) continue

                // Extract strings (available without opening device on API 21+)
                val productName = device.productName ?: "USB Audio Device"
                val manufacturer = device.manufacturerName ?: ""
                val serial = safeUsbSerial(device) ?: device.deviceName
                
                result.add(mapOf(
                    "deviceName" to device.deviceName,
                    "vendorId" to device.vendorId,
                    "productId" to device.productId,
                    "productName" to productName,
                    "manufacturer" to manufacturer,
                    "serial" to serial,
                    "hasPermission" to usbManager.hasPermission(device),
                ))
            } catch (e: Exception) {
                android.util.Log.w("UAC2", "Failed to process device ${device.deviceName}: ${e.message}")
                // Continue with other devices
            }
        }

        if (result.isEmpty() && !routeLabelHint.isNullOrBlank()) {
            Log.i(
                "UAC2",
                "No UsbManager DAC candidates matched route \"$routeLabelHint\". Inventory: " +
                    deviceList.values.joinToString { device -> usbDeviceDebugSummary(device) },
            )
        }
        if (result.isNotEmpty()) {
            Log.i(
                "UAC2",
                "UsbManager DAC candidates: " +
                    result.joinToString { item ->
                        "${item["productName"] ?: item["deviceName"]}@${item["deviceName"]} permission=${item["hasPermission"]}"
                    },
            )
        }
        
        uac2DeviceCache = result
        return result
    }

    private fun isUac2Device(device: UsbDevice): Boolean {
        return try {
            if (device.deviceClass == UsbConstants.USB_CLASS_AUDIO) {
                return true
            }

            for (i in 0 until device.interfaceCount) {
                val iface = device.getInterface(i)
                if (iface.interfaceClass == UsbConstants.USB_CLASS_AUDIO &&
                    (iface.interfaceSubclass == 0x01 ||
                        iface.interfaceSubclass == 0x02 ||
                        iface.interfaceSubclass == 0x03)
                ) {
                    return true
                }
            }
            false
        } catch (e: Exception) {
            android.util.Log.w("UAC2", "Error checking device: ${e.message}")
            false
        }
    }

    private fun deviceHasIsochronousEndpoint(device: UsbDevice): Boolean {
        return try {
            for (i in 0 until device.interfaceCount) {
                val iface = device.getInterface(i)
                for (endpointIndex in 0 until iface.endpointCount) {
                    val endpoint = iface.getEndpoint(endpointIndex)
                    if (endpoint.type == UsbConstants.USB_ENDPOINT_XFER_ISOC) {
                        return true
                    }
                }
            }
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun normalizeUsbText(value: String?): String {
        if (value.isNullOrBlank()) return ""
        return value
            .lowercase()
            .replace(Regex("[^a-z0-9]+"), " ")
            .trim()
    }

    private fun normalizedUsbTokens(value: String?): Set<String> {
        return normalizeUsbText(value)
            .split(' ')
            .filter { it.length >= 3 }
            .toSet()
    }

    private fun routeLabelMatchesUsbDevice(routeLabelHint: String?, device: UsbDevice): Boolean {
        if (routeLabelHint.isNullOrBlank()) {
            return false
        }

        val normalizedRoute = normalizeUsbText(routeLabelHint)
        val routeTokens = normalizedUsbTokens(routeLabelHint)
        if (normalizedRoute.isBlank() || routeTokens.isEmpty()) {
            return false
        }

        val candidateTexts = listOfNotNull(
            device.productName,
            device.manufacturerName,
            "${device.manufacturerName ?: ""} ${device.productName ?: ""}",
            device.deviceName,
        )

        return candidateTexts.any { candidate ->
            val normalizedCandidate = normalizeUsbText(candidate)
            val candidateTokens = normalizedUsbTokens(candidate)
            candidateTokens.isNotEmpty() &&
                (
                    routeTokens.intersect(candidateTokens).size >= 2 ||
                        normalizedRoute.contains(normalizedCandidate) ||
                        normalizedCandidate.contains(normalizedRoute)
                )
        }
    }

    private fun looksLikeUsbAudioName(device: UsbDevice): Boolean {
        val haystack = normalizeUsbText(
            listOfNotNull(
                device.productName,
                device.manufacturerName,
            ).joinToString(" "),
        )
        if (haystack.isBlank()) {
            return false
        }

        val keywords = listOf(
            "audio",
            "usb audio",
            "dac",
            "headset",
            "headphone",
            "dongle",
            "amp",
            "hi-fi",
            "hifi",
            "sound",
            "speaker",
            "c-media",
            "realtek",
            "conexant",
            "pnp",
            "output",
            "cx",
            "cm108",
            "hs",
        )
        return keywords.any { keyword -> haystack.contains(keyword) }
    }

    private fun isLikelyUsbAudioDevice(
        device: UsbDevice,
        routeLabelHint: String? = currentRouteLabelHint(),
    ): Boolean {
        if (isUac2Device(device)) {
            return true
        }

        if (routeLabelMatchesUsbDevice(routeLabelHint, device)) {
            return true
        }

        if (deviceHasIsochronousEndpoint(device) && looksLikeUsbAudioName(device)) {
            return true
        }

        if (deviceHasIsochronousEndpoint(device) && hasUsbAudioOutputViaDeviceInfo()) {
            return true
        }

        return false
    }

    private fun hasUsbAudioOutputViaDeviceInfo(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        return audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }
    }

    private fun usbDeviceDebugSummary(device: UsbDevice): String {
        val label = listOfNotNull(device.manufacturerName, device.productName)
            .filter { it.isNotBlank() }
            .joinToString(" ")
            .ifBlank { "unknown" }
        return "$label@${device.deviceName}[${device.vendorId}:${device.productId}] " +
            "audioClass=${isUac2Device(device)} iso=${deviceHasIsochronousEndpoint(device)}"
    }

    private fun currentRouteLabelHint(): String? {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        return describeCurrentOutputRoute(audioManager)["routeLabel"] as? String
    }

    private fun hasUac2Permission(deviceName: String): Boolean {
        return try {
            val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
            val device = usbManager.deviceList?.get(deviceName) ?: return false
            usbManager.hasPermission(device)
        } catch (e: Exception) {
            android.util.Log.e("UAC2", "Error checking permission: ${e.message}")
            false
        }
    }

    private fun requestUac2Permission(deviceName: String, result: MethodChannel.Result) {
        requestUac2PermissionInternal(deviceName, result = result)
    }

    private fun requestUac2PermissionInternal(
        deviceName: String,
        result: MethodChannel.Result? = null,
        callback: ((Boolean) -> Unit)? = null,
    ) {
        try {
            val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
            if (usbManager == null) {
                promptedUsbPermissionDeviceNames.remove(deviceName)
                result?.error("UAC2_ERROR", "USB service unavailable", null)
                callback?.invoke(false)
                return
            }
            
            val device = usbManager.deviceList?.get(deviceName)
            if (device == null) {
                promptedUsbPermissionDeviceNames.remove(deviceName)
                result?.error("NOT_FOUND", "USB device not found: $deviceName", null)
                callback?.invoke(false)
                return
            }
            
            if (usbManager.hasPermission(device)) {
                result?.success(true)
                callback?.invoke(true)
                return
            }
            
            // Device might be busy if already opened elsewhere
            pendingUac2PermissionResult = result
            pendingUac2PermissionCallback = callback
            val permissionIntent = PendingIntent.getBroadcast(
                this,
                REQUEST_USB_PERMISSION,
                Intent(ACTION_USB_PERMISSION).setPackage(packageName),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            usbPermissionReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action == ACTION_USB_PERMISSION) {
                        val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                        val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                        }
                        unregisterReceiverSafely(usbPermissionReceiver)
                        usbPermissionReceiver = null
                        
                        if (granted && device != null) {
                            // Invalidate cache when permission granted
                            uac2DeviceCache = null
                            pendingUac2PermissionResult?.success(true)
                            pendingUac2PermissionCallback?.invoke(true)
                        } else {
                            pendingUac2PermissionResult?.error(
                                "PERMISSION_DENIED",
                                "Permission denied for device: ${device?.deviceName ?: deviceName}",
                                null
                            )
                            pendingUac2PermissionCallback?.invoke(false)
                        }
                        pendingUac2PermissionResult = null
                        pendingUac2PermissionCallback = null
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(usbPermissionReceiver, IntentFilter(ACTION_USB_PERMISSION), Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(usbPermissionReceiver, IntentFilter(ACTION_USB_PERMISSION))
            }
            usbManager.requestPermission(device, permissionIntent)
        } catch (e: Exception) {
            promptedUsbPermissionDeviceNames.remove(deviceName)
            android.util.Log.e("UAC2", "Error requesting permission: ${e.message}")
            result?.error("UAC2_ERROR", "Failed to request permission: ${e.message}", null)
            callback?.invoke(false)
        }
    }

    private fun activateDirectUsb(deviceName: String): Boolean {
        return try {
            val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
            val device = usbManager.deviceList?.get(deviceName) ?: return false
            if (!usbManager.hasPermission(device)) {
                Log.e("UAC2", "Cannot activate direct USB without permission for $deviceName")
                return false
            }

            val existingConnection = directUsbConnections[deviceName]
            if (activeDirectUsbDeviceName == deviceName && existingConnection != null) {
                return true
            }
            val connection = existingConnection ?: usbManager.openDevice(device)
            if (connection == null) {
                Log.e("UAC2", "Failed to open USB device for direct playback: $deviceName")
                return false
            }

            val fileDescriptor = connection.fileDescriptor
            if (fileDescriptor < 0) {
                if (existingConnection == null) {
                    connection.close()
                }
                Log.e("UAC2", "USB device returned invalid file descriptor: $deviceName")
                return false
            }

            if (!probeDirectUsbExclusiveAccess(connection, device)) {
                if (existingConnection == null) {
                    connection.close()
                } else {
                    closeDirectUsbConnection(deviceName)
                }
                Log.e(
                    "UAC2",
                    "Failed to force-claim USB audio interfaces for direct playback: $deviceName",
                )
                return false
            }

            val registered = nativeRegisterRustDirectUsbDevice(
                fileDescriptor,
                device.vendorId,
                device.productId,
                device.productName ?: "USB Audio Device",
                device.manufacturerName ?: "",
                safeUsbSerial(device),
                device.deviceName,
            )

            if (!registered) {
                if (existingConnection == null) {
                    connection.close()
                }
                Log.e("UAC2", "Rust rejected direct USB registration for $deviceName")
                return false
            }

            if (activeDirectUsbDeviceName != null && activeDirectUsbDeviceName != deviceName) {
                closeDirectUsbConnection(activeDirectUsbDeviceName)
            }

            directUsbConnections[deviceName] = connection
            activeDirectUsbDeviceName = deviceName
            if (!nativeSetRustDirectUsbLockEnabled(true)) {
                Log.w("UAC2", "Rust direct USB idle lock failed for $deviceName")
            }
            updateDirectUsbAudioFocus()
            Log.i("UAC2", "Direct USB DAC activated for $deviceName")
            true
        } catch (e: Exception) {
            Log.e("UAC2", "Failed to activate direct USB DAC: ${e.message}", e)
            false
        }
    }

    private fun probeDirectUsbExclusiveAccess(
        connection: UsbDeviceConnection,
        device: UsbDevice,
    ): Boolean {
        val audioInterfaces = directUsbAudioInterfaces(device)
        if (audioInterfaces.isEmpty()) {
            Log.w("UAC2", "No USB audio interfaces were found for ${device.deviceName}")
            return false
        }

        val controlInterface = audioInterfaces.firstOrNull { usbInterface ->
            usbInterface.interfaceSubclass == 0x01
        }
        val streamingInterfaces = audioInterfaces.filter { usbInterface ->
            usbInterface.interfaceSubclass == 0x02
        }
        if (controlInterface == null || streamingInterfaces.isEmpty()) {
            Log.w(
                "UAC2",
                "[USB] Missing required audio interfaces on ${device.deviceName}: " +
                    "control=${controlInterface?.id ?: "none"}, " +
                    "streaming=${streamingInterfaces.map { it.id }}",
            )
            return false
        }

        Log.i(
            "UAC2",
            "[USB] Audio interface check passed for ${device.deviceName}: " +
                "controlInterface=${controlInterface.id}, " +
                "streamingInterfaces=${streamingInterfaces.map { it.id }}, " +
                "fd=${connection.fileDescriptor}",
        )
        return true
    }

    private fun directUsbAudioInterfaces(device: UsbDevice): List<UsbInterface> {
        val interfaces = mutableListOf<UsbInterface>()
        for (index in 0 until device.interfaceCount) {
            val usbInterface = device.getInterface(index)
            if (usbInterface.interfaceClass == UsbConstants.USB_CLASS_AUDIO) {
                interfaces += usbInterface
            }
        }
        return interfaces
    }

    private fun describeDirectUsbInterface(usbInterface: UsbInterface): String {
        val subclass = when (usbInterface.interfaceSubclass) {
            0x01 -> "audio-control"
            0x02 -> "audio-streaming"
            0x03 -> "midi-streaming"
            else -> "subclass-${usbInterface.interfaceSubclass}"
        }
        return "class=${usbInterface.interfaceClass},subclass=$subclass,alt=${usbInterface.alternateSetting}"
    }

    private fun handleUsbAttachIntent(intent: Intent?) {
        if (intent?.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) {
            return
        }

        val attachedDevice: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
        }
        maybeRequestPermissionForAttachedDevice(attachedDevice)
    }

    private fun maybeRequestPermissionForAttachedDevice(
        device: UsbDevice?,
        reason: String = "attach broadcast",
    ) {
        if (device == null || !isLikelyUsbAudioDevice(device)) {
            return
        }

        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return
        if (usbManager.hasPermission(device)) {
            return
        }
        if (pendingUac2PermissionResult != null || pendingUac2PermissionCallback != null) {
            return
        }
        if (!promptedUsbPermissionDeviceNames.add(device.deviceName)) {
            return
        }

        Log.i(
            "UAC2",
            "Requesting USB permission for DAC candidate: " +
                "${device.productName ?: device.deviceName} ($reason)",
        )
        requestUac2PermissionInternal(
            device.deviceName,
            callback = { granted ->
                if (granted) {
                    uac2DeviceCache = null
                    uac2Channel?.invokeMethod("onDeviceAttached", null)
                    audioDeviceChannel?.invokeMethod("onPlaybackDevicesChanged", null)
                }
            },
        )
    }

    private fun maybeRequestPermissionForConnectedUsbAudioDevices(reason: String) {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return
        val routeLabelHint = currentRouteLabelHint()
        val candidates = usbManager.deviceList.values.filter { device ->
            isLikelyUsbAudioDevice(device, routeLabelHint)
        }
        if (candidates.isEmpty()) {
            return
        }

        val pendingCandidate = candidates.firstOrNull { device ->
            !usbManager.hasPermission(device) &&
                !promptedUsbPermissionDeviceNames.contains(device.deviceName)
        } ?: return

        maybeRequestPermissionForAttachedDevice(
            pendingCandidate,
            reason = reason,
        )
    }

    private fun setExclusiveDacMode(enabled: Boolean): Boolean {
        exclusiveDacModeEnabled = enabled
        val rustUpdated = if (activeDirectUsbDeviceName != null) {
            nativeSetRustDirectUsbLockEnabled(enabled)
        } else {
            true
        }
        updateDirectUsbAudioFocus()
        return rustUpdated
    }

    private fun setDirectUsbPlaybackActive(active: Boolean): Boolean {
        if (!active && !directUsbPlaybackActive) {
            return true
        }
        directUsbPlaybackActive = active
        updateDirectUsbAudioFocus()
        return true
    }

    private fun deactivateDirectUsb(): Boolean {
        return try {
            directUsbPlaybackActive = false
            nativeSetRustDirectUsbLockEnabled(false)
            nativeClearRustDirectUsbPlayback()
            val deviceName = activeDirectUsbDeviceName
            val stopped = nativeWaitRustDirectUsbSessionStopped(4_000)
            if (!stopped) {
                Log.w(
                    "UAC2",
                    "[USB] Timed out waiting for Rust direct USB shutdown for ${deviceName ?: "unknown"}; forcing connection close",
                )
            }
            closeDirectUsbConnection(deviceName)
            activeDirectUsbDeviceName = null
            updateDirectUsbAudioFocus()
            true
        } catch (e: Exception) {
            Log.e("UAC2", "Failed to deactivate direct USB DAC: ${e.message}", e)
            false
        }
    }

    private fun updateDirectUsbAudioFocus() {
        if (shouldHoldDirectUsbAudioFocus()) {
            if (directUsbFocusGain == null) {
                Log.i("UAC2", "[USB] Requesting audio focus for direct USB playback")
                requestDirectUsbAudioFocus(AudioManager.AUDIOFOCUS_GAIN)
            }
        } else {
            if (directUsbFocusGain != null || directUsbAudioFocusRequest != null) {
                Log.i("UAC2", "[USB] Releasing direct USB audio focus")
            }
            abandonDirectUsbAudioFocus()
        }
    }

    private fun shouldHoldDirectUsbAudioFocus(): Boolean {
        return activeDirectUsbDeviceName != null &&
            (directUsbPlaybackActive || nativeIsRustDirectUsbSessionActive())
    }

    private fun requestDirectUsbAudioFocus(focusGain: Int) {
        if (directUsbFocusGain == focusGain) {
            return
        }

        abandonDirectUsbAudioFocus()
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(focusGain)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setOnAudioFocusChangeListener(directUsbAudioFocusChangeListener)
                .setAcceptsDelayedFocusGain(false)
                .build()
            directUsbAudioFocusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                directUsbAudioFocusChangeListener,
                AudioManager.STREAM_MUSIC,
                focusGain,
            )
        }

        if (granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            directUsbFocusGain = focusGain
        } else {
            directUsbAudioFocusRequest = null
            directUsbFocusGain = null
            Log.w("UAC2", "Direct USB audio focus request denied (gain=$focusGain)")
        }
    }

    private fun abandonDirectUsbAudioFocus() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            directUsbAudioFocusRequest?.let { request ->
                audioManager.abandonAudioFocusRequest(request)
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(directUsbAudioFocusChangeListener)
        }

        directUsbAudioFocusRequest = null
        directUsbFocusGain = null
    }

    private fun closeDirectUsbConnection(deviceName: String?) {
        if (deviceName == null) return
        try {
            directUsbConnections.remove(deviceName)?.close()
        } catch (_: Exception) {
        }
    }

    private fun getRouteStatus(
        preferredDeviceName: String? = null,
        preferredProductName: String? = null,
        preferredVendorId: Int? = null,
        preferredProductId: Int? = null,
        preferredSerial: String? = null,
    ): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val baseRoute = describeCurrentOutputRoute(audioManager).toMutableMap()
        val preferredUsbDevice = findPreferredUsbAudioDevice(
            preferredDeviceName = preferredDeviceName,
            preferredProductName = preferredProductName,
            preferredVendorId = preferredVendorId,
            preferredProductId = preferredProductId,
            preferredSerial = preferredSerial,
        )

        val directUsbRegistered = activeDirectUsbDeviceName != null
        val hasSystemVolumeControl = audioManager != null && !audioManager.isVolumeFixed
        val hasDirectUsbHardwareVolume = hasDirectUsbHardwareVolume()
        val hasVolumeControl = if (directUsbRegistered) {
            hasDirectUsbHardwareVolume
        } else {
            hasDirectUsbHardwareVolume || hasSystemVolumeControl
        }
        val volumeControlWritable = when {
            hasDirectUsbHardwareVolume -> true
            hasVolumeControl -> true
            else -> false
        }
        baseRoute["hasVolumeControl"] = hasVolumeControl
        baseRoute["volumeControlWritable"] = volumeControlWritable
        baseRoute["volumeMode"] = when {
            hasDirectUsbHardwareVolume -> "hardware"
            hasVolumeControl -> "system"
            else -> "unavailable"
        }
        baseRoute["volume"] = if (hasVolumeControl) {
            if (hasDirectUsbHardwareVolume) {
                nativeGetRustDirectUsbHardwareVolume()
            } else {
                getRouteVolume()
            }
        } else null
        baseRoute["muted"] = when {
            hasDirectUsbHardwareVolume -> when (nativeGetRustDirectUsbHardwareMute()) {
                1 -> true
                0 -> false
                else -> null
            }
            hasVolumeControl -> getRouteMuted()
            else -> null
        }
        baseRoute["preferredUsbDeviceDetected"] = preferredUsbDevice != null
        baseRoute["preferredUsbDeviceName"] = preferredUsbDevice?.deviceName
        baseRoute["preferredUsbProductName"] = preferredUsbDevice?.productName
        baseRoute["directUsbRegistered"] = directUsbRegistered
        baseRoute["directUsbDeviceName"] = activeDirectUsbDeviceName

        return baseRoute
    }

    private fun hasDirectUsbHardwareVolume(): Boolean {
        return activeDirectUsbDeviceName != null && nativeHasRustDirectUsbHardwareVolume()
    }

    private fun isDirectUsbSessionFrozen(): Boolean {
        return activeDirectUsbDeviceName != null && shouldHoldDirectUsbAudioFocus()
    }

    private fun currentActiveDirectUsbDevice(): UsbDevice? {
        val deviceName = activeDirectUsbDeviceName ?: return null
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return null
        return usbManager.deviceList?.get(deviceName)
    }

    private fun cachedDirectUsbCapabilityRoute(): MutableMap<String, Any?> {
        val activeDevice = currentActiveDirectUsbDevice()
        return activeDevice?.let { buildUsbRouteMap(it).toMutableMap() } ?: mutableMapOf(
            "routeType" to "usb",
            "routeLabel" to (currentRouteLabelHint() ?: "USB DAC"),
            "isExternal" to true,
            "productName" to (currentRouteLabelHint() ?: "USB DAC"),
            "manufacturer" to Build.MANUFACTURER,
            "deviceName" to activeDirectUsbDeviceName,
        )
    }

    private fun findPreferredUsbAudioDevice(
        preferredDeviceName: String? = null,
        preferredProductName: String? = null,
        preferredVendorId: Int? = null,
        preferredProductId: Int? = null,
        preferredSerial: String? = null,
    ): UsbDevice? {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return null
        val routeLabelHint = preferredProductName ?: currentRouteLabelHint()
        val candidates = usbManager.deviceList.values.filter { device ->
            isLikelyUsbAudioDevice(device, routeLabelHint)
        }
        if (candidates.isEmpty()) return null

        return candidates.firstOrNull { device ->
            preferredDeviceName != null && device.deviceName == preferredDeviceName
        } ?: candidates.firstOrNull { device ->
            preferredSerial != null &&
                (safeUsbSerial(device) == preferredSerial || device.deviceName == preferredSerial)
        } ?: candidates.firstOrNull { device ->
            preferredVendorId != null &&
                preferredProductId != null &&
                device.vendorId == preferredVendorId &&
                device.productId == preferredProductId
        } ?: candidates.firstOrNull { device ->
            preferredProductName != null &&
                !device.productName.isNullOrBlank() &&
                device.productName == preferredProductName
        } ?: candidates.firstOrNull()
    }

    private fun currentBestOutputDevice(audioManager: AudioManager?): AudioDeviceInfo? {
        if (audioManager == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null
        }

        return audioManager
            .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .minByOrNull { device -> outputRoutePriority(device.type) }
    }

    private fun describeCurrentOutputRoute(audioManager: AudioManager?): Map<String, Any?> {
        val bestOutput = currentBestOutputDevice(audioManager)
        if (bestOutput != null) {
            val routeType = routeTypeForAudioDevice(bestOutput.type)
            val label = bestOutput.productName
                ?.toString()
                ?.takeIf { it.isNotBlank() }
                ?: defaultRouteLabel(routeType)
            return mutableMapOf(
                "routeType" to routeType,
                "routeLabel" to label,
                "isExternal" to isExternalRouteType(routeType),
                "productName" to defaultProductName(routeType, label),
                "manufacturer" to Build.MANUFACTURER,
            )
        }

        return mutableMapOf(
            "routeType" to "internal",
            "routeLabel" to "Built-in output",
            "isExternal" to false,
            "productName" to "Device DAC",
            "manufacturer" to Build.MANUFACTURER,
        )
    }

    private fun getPlaybackDeviceInfo(): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val outputs = if (audioManager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()
        } else {
            emptyList()
        }
        val hasUsbAudioRoute = outputs.any { device ->
            device.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                device.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }
        val route = describeCurrentOutputRoute(audioManager)
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
        val hasAttachedUac2Device = usbManager
            ?.deviceList
            ?.values
            ?.any { device -> isLikelyUsbAudioDevice(device, route["routeLabel"] as? String) }
            ?: false

        return mapOf(
            "hasUsbDac" to (hasUsbAudioRoute || hasAttachedUac2Device),
            "hasUsbAudioRoute" to hasUsbAudioRoute,
            "hasAttachedUac2Device" to hasAttachedUac2Device,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "routeType" to route["routeType"],
            "routeLabel" to route["routeLabel"],
        )
    }

    private fun buildUsbRouteMap(device: UsbDevice): Map<String, Any?> {
        val productName = device.productName?.takeIf { it.isNotBlank() } ?: "USB DAC"
        val manufacturer = device.manufacturerName?.takeIf { it.isNotBlank() } ?: "USB Audio"
        return mutableMapOf(
            "routeType" to "usb",
            "routeLabel" to productName,
            "isExternal" to true,
            "productName" to productName,
            "manufacturer" to manufacturer,
            "deviceName" to device.deviceName,
            "vendorId" to device.vendorId,
            "productId" to device.productId,
            "serial" to (safeUsbSerial(device) ?: device.deviceName),
        )
    }

    private fun getDirectUsbDiagnostics(): Map<String, Any?> {
        return mapOf(
            "activeDirectUsbDeviceName" to activeDirectUsbDeviceName,
            "directUsbRegistered" to (activeDirectUsbDeviceName != null),
            "exclusiveDacModeEnabled" to exclusiveDacModeEnabled,
            "directUsbPlaybackActive" to directUsbPlaybackActive,
            "audioFocusHeld" to (directUsbFocusGain != null),
            "audioFocusGain" to directUsbFocusGain,
            "rustAudioStateJson" to nativeGetRustAudioDebugStateJson(),
        )
    }

    private fun getAudioCapabilities(
        preferredDeviceName: String? = null,
        preferredProductName: String? = null,
        preferredVendorId: Int? = null,
        preferredProductId: Int? = null,
        preferredSerial: String? = null,
    ): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val freezeDirectUsbSession = isDirectUsbSessionFrozen()
        val routeStatus = if (freezeDirectUsbSession) {
            cachedDirectUsbCapabilityRoute().apply {
                put("directUsbRegistered", true)
                put("preferredUsbDeviceDetected", true)
            }
        } else {
            getRouteStatus(
                preferredDeviceName = preferredDeviceName,
                preferredProductName = preferredProductName,
                preferredVendorId = preferredVendorId,
                preferredProductId = preferredProductId,
                preferredSerial = preferredSerial,
            )
        }
        val routeType = if (freezeDirectUsbSession) {
            "usb"
        } else {
            routeStatus["routeType"] as? String ?: "unknown"
        }
        val preferredUsbDevice = if (freezeDirectUsbSession) {
            null
        } else {
            findPreferredUsbAudioDevice(
                preferredDeviceName = preferredDeviceName,
                preferredProductName = preferredProductName,
                preferredVendorId = preferredVendorId,
                preferredProductId = preferredProductId,
                preferredSerial = preferredSerial,
            )
        }
        val bestOutput = currentBestOutputDevice(audioManager)
        val supportedSampleRates = bestOutput
            ?.sampleRates
            ?.filter { it > 0 }
            ?.distinct()
            ?.sorted()
            ?: emptyList()
        val nativeSampleRate = audioManager
            ?.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
            ?.toIntOrNull()
        val maxSupportedSampleRate = listOfNotNull(
            supportedSampleRates.maxOrNull(),
            nativeSampleRate,
        ).maxOrNull()
        val hasProAudio = packageManager.hasSystemFeature(PackageManager.FEATURE_AUDIO_PRO)
        val hasLowLatency = packageManager.hasSystemFeature(PackageManager.FEATURE_AUDIO_LOW_LATENCY)
        val hiResInternal = (routeType == "internal" || routeType == "wired") &&
            ((maxSupportedSampleRate ?: 0) > 48_000 || (hasProAudio && (nativeSampleRate ?: 0) > 48_000))

        val capabilities = mutableListOf<String>()
        if (routeType == "usb" || preferredUsbDevice != null) {
            capabilities += "usbDac"
        }
        if (hiResInternal) {
            capabilities += "hiResInternal"
        }
        if (capabilities.isEmpty()) {
            capabilities += "standard"
        }

        return mutableMapOf(
            "capabilities" to capabilities,
            "routeType" to routeType,
            "routeLabel" to routeStatus["routeLabel"],
            "maxSupportedSampleRate" to maxSupportedSampleRate,
            "nativeSampleRate" to nativeSampleRate,
            "supportedSampleRates" to supportedSampleRates,
            "hasProAudio" to hasProAudio,
            "hasLowLatency" to hasLowLatency,
        )
    }

    private fun outputRoutePriority(type: Int): Int {
        return when (type) {
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_DOCK -> 0
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_LINE_ANALOG,
            AudioDeviceInfo.TYPE_LINE_DIGITAL,
            AudioDeviceInfo.TYPE_HDMI,
            AudioDeviceInfo.TYPE_HDMI_ARC,
            AudioDeviceInfo.TYPE_HDMI_EARC,
            AudioDeviceInfo.TYPE_AUX_LINE,
            AudioDeviceInfo.TYPE_BUS -> 1
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLE_BROADCAST -> 2
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> 3
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> 4
            else -> 4
        }
    }

    private fun routeTypeForAudioDevice(type: Int): String {
        return when (type) {
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
            AudioDeviceInfo.TYPE_DOCK -> "dock"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_LINE_ANALOG,
            AudioDeviceInfo.TYPE_LINE_DIGITAL,
            AudioDeviceInfo.TYPE_HDMI,
            AudioDeviceInfo.TYPE_HDMI_ARC,
            AudioDeviceInfo.TYPE_HDMI_EARC,
            AudioDeviceInfo.TYPE_AUX_LINE,
            AudioDeviceInfo.TYPE_BUS -> "wired"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLE_BROADCAST -> "bluetooth"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE,
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "internal"
            else -> "unknown"
        }
    }

    private fun isExternalRouteType(routeType: String): Boolean {
        return routeType == "usb" || routeType == "dock"
    }

    private fun defaultProductName(routeType: String, label: String): String {
        return when (routeType) {
            "internal" -> "Device DAC"
            "usb" -> label.ifBlank { "USB DAC" }
            "dock" -> label.ifBlank { "Dock Audio" }
            "wired" -> label.ifBlank { "Headphone Output" }
            "bluetooth" -> label.ifBlank { "Bluetooth Output" }
            else -> label.ifBlank { "Audio Output" }
        }
    }

    private fun defaultRouteLabel(routeType: String): String {
        return when (routeType) {
            "internal" -> "Built-in output"
            "usb" -> "USB DAC"
            "dock" -> "Dock audio"
            "wired" -> "Headphone output"
            "bluetooth" -> "Bluetooth output"
            else -> "Audio output"
        }
    }

    private fun safeUsbSerial(device: UsbDevice): String? {
        return try {
            device.serialNumber
        } catch (_: SecurityException) {
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun getRouteVolume(): Double? {
        if (hasDirectUsbHardwareVolume()) {
            val hardwareVolume = nativeGetRustDirectUsbHardwareVolume()
            return if (hardwareVolume.isNaN()) null else hardwareVolume.coerceIn(0.0, 1.0)
        }

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return null
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (maxVolume <= 0) return 1.0

        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return (currentVolume.toDouble() / maxVolume.toDouble()).coerceIn(0.0, 1.0)
    }

    /// Returns: 1 = healthy, 0 = mismatch (should fall back to Tier 2), -1 = error/no device
    private fun verifyHardwareVolumeHealth(): Int {
        if (!hasDirectUsbHardwareVolume()) return -1
        return nativeVerifyRustDirectUsbHardwareVolumeHealth()
    }

    private fun setRouteVolume(volume: Double): Boolean {
        if (hasDirectUsbHardwareVolume()) {
            val clamped = volume.coerceIn(0.0, 1.0)
            Log.d("VolFlow", "setRouteVolume hw: sending SET_CUR $clamped")
            val ok = nativeSetRustDirectUsbHardwareVolume(clamped)
            Log.d("VolFlow", "setRouteVolume hw: native returned $ok")
            return ok
        }

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        if (audioManager.isVolumeFixed) return false

        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (maxVolume <= 0) return false

        val clamped = volume.coerceIn(0.0, 1.0)
        val targetVolume = (clamped * maxVolume.toDouble()).roundToInt().coerceIn(0, maxVolume)
        if (targetVolume > 0) {
            cachedMusicVolumeBeforeMute = targetVolume
        }
        suppressVolumeObserverBriefly()
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, targetVolume, 0)
        return true
    }

    private fun getRouteMuted(): Boolean {
        if (hasDirectUsbHardwareVolume()) {
            return nativeGetRustDirectUsbHardwareMute() == 1
        }

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.isStreamMute(AudioManager.STREAM_MUSIC) || currentVolume == 0
        } else {
            currentVolume == 0
        }
    }

    private fun setRouteMuted(muted: Boolean): Boolean {
        if (hasDirectUsbHardwareVolume()) {
            return nativeSetRustDirectUsbHardwareMute(muted)
        }

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        if (audioManager.isVolumeFixed) return false

        val streamType = AudioManager.STREAM_MUSIC
        suppressVolumeObserverBriefly()
        if (muted) {
            val currentVolume = audioManager.getStreamVolume(streamType)
            if (currentVolume > 0) {
                cachedMusicVolumeBeforeMute = currentVolume
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                audioManager.adjustStreamVolume(streamType, AudioManager.ADJUST_MUTE, 0)
            }
            audioManager.setStreamVolume(streamType, 0, 0)
            return true
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.adjustStreamVolume(streamType, AudioManager.ADJUST_UNMUTE, 0)
        }
        // Read actual OS volume — it may have been changed via hardware buttons while muted
        val currentAfterUnmute = audioManager.getStreamVolume(streamType)
        if (currentAfterUnmute == 0) {
            val maxVolume = audioManager.getStreamMaxVolume(streamType).coerceAtLeast(1)
            val restoreVolume = (cachedMusicVolumeBeforeMute ?: (maxVolume / 2).coerceAtLeast(1))
                .coerceIn(1, maxVolume)
            audioManager.setStreamVolume(streamType, restoreVolume, 0)
        }
        return true
    }

    private fun unregisterReceiverSafely(receiver: BroadcastReceiver?) {
        if (receiver == null) return
        try {
            unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
        } catch (_: Exception) {
        }
    }

    private fun suppressVolumeObserverBriefly() {
        suppressVolumeObserverRunnable?.let { volumeObserverHandler.removeCallbacks(it) }
        suppressVolumeObserver = true
        suppressVolumeObserverRunnable = Runnable { suppressVolumeObserver = false }
        volumeObserverHandler.postDelayed(suppressVolumeObserverRunnable!!, 200)
    }

    private fun registerVolumeContentObserver() {
        // Seed cached values so the first real change is detected
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        if (hasDirectUsbHardwareVolume()) {
            lastObservedHardwareVolume = nativeGetRustDirectUsbHardwareVolume()
            lastObservedHardwareMute = nativeGetRustDirectUsbHardwareMute()
        } else {
            val seedVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            lastObservedVolume = seedVolume
            lastObservedMuted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                seedVolume == 0 || audioManager.isStreamMute(AudioManager.STREAM_MUSIC)
            } else {
                seedVolume == 0
            }
        }

        volumeContentObserver = object : ContentObserver(volumeObserverHandler) {
            override fun onChange(selfChange: Boolean) {
                if (suppressVolumeObserver) return
                // Debounce: cancel pending, schedule new
                volumeObserverDebounceRunnable?.let { volumeObserverHandler.removeCallbacks(it) }
                volumeObserverDebounceRunnable = Runnable {
                    val volume = getRouteVolume()
                    val muted = getRouteMuted()
                    if (hasDirectUsbHardwareVolume()) {
                        val hwVol = nativeGetRustDirectUsbHardwareVolume()
                        val hwMute = nativeGetRustDirectUsbHardwareMute()
                        val hwVolChanged = when {
                            hwVol.isNaN() && lastObservedHardwareVolume.isNaN() -> false
                            hwVol.isNaN() != lastObservedHardwareVolume.isNaN() -> true
                            hwVol.isNaN() -> false
                            lastObservedHardwareVolume.isNaN() -> true
                            else -> kotlin.math.abs(hwVol - lastObservedHardwareVolume) > 1e-6
                        }
                        val hwMuteChanged = hwMute != lastObservedHardwareMute
                        if (hwVolChanged || hwMuteChanged) {
                            lastObservedHardwareVolume = hwVol
                            lastObservedHardwareMute = hwMute
                            uac2Channel?.invokeMethod("onVolumeChanged", mapOf(
                                "volume" to volume,
                                "muted" to muted,
                            ))
                        }
                    } else {
                        val volRaw = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        // Only notify Flutter if volume or mute actually changed
                        if (volRaw != lastObservedVolume || muted != lastObservedMuted) {
                            lastObservedVolume = volRaw
                            lastObservedMuted = muted
                            uac2Channel?.invokeMethod("onVolumeChanged", mapOf(
                                "volume" to volume,
                                "muted" to muted,
                            ))
                        }
                    }
                }
                volumeObserverHandler.postDelayed(volumeObserverDebounceRunnable!!, 150)
            }
        }
        contentResolver.registerContentObserver(
            android.provider.Settings.System.CONTENT_URI,
            true,
            volumeContentObserver!!,
        )
    }

    private fun unregisterVolumeContentObserver() {
        volumeContentObserver?.let { contentResolver.unregisterContentObserver(it) }
        volumeObserverDebounceRunnable?.let { volumeObserverHandler.removeCallbacks(it) }
        suppressVolumeObserverRunnable?.let { volumeObserverHandler.removeCallbacks(it) }
        volumeContentObserver = null
    }

    private fun registerUsbHotplugReceiver() {
        usbHotplugReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                        // Invalidate cache on device attach
                        uac2DeviceCache = null
                        val attachedDevice: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                        }
                        maybeRequestPermissionForAttachedDevice(attachedDevice)
                        // Notify Flutter if channel is available
                        uac2Channel?.invokeMethod("onDeviceAttached", null)
                        audioDeviceChannel?.invokeMethod("onPlaybackDevicesChanged", null)
                    }
                    UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                        // Invalidate cache on device detach
                        uac2DeviceCache = null
                        val detachedDevice: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                        }
                        if (detachedDevice?.deviceName == activeDirectUsbDeviceName) {
                            deactivateDirectUsb()
                        }
                        detachedDevice?.deviceName?.let { promptedUsbPermissionDeviceNames.remove(it) }
                        // Notify Flutter if channel is available
                        uac2Channel?.invokeMethod("onDeviceDetached", null)
                        audioDeviceChannel?.invokeMethod("onPlaybackDevicesChanged", null)
                    }
                }
            }
        }
        
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbHotplugReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(usbHotplugReceiver, filter)
        }
    }
    
    private fun attachVisualizer(sessionId: Int): Boolean {
        return try {
            detachVisualizer()
            if (sessionId <= 0) {
                Log.w("Visualizer", "Invalid audio session ID: $sessionId")
                return false
            }
            val viz = Visualizer(sessionId).apply {
                val captureSizeRange = Visualizer.getCaptureSizeRange()
                val targetSize = captureSizeRange[1].coerceAtMost(512)
                captureSize = targetSize
                setDataCaptureListener(
                    object : Visualizer.OnDataCaptureListener {
                        override fun onWaveFormDataCapture(
                            v: Visualizer?,
                            waveform: ByteArray?,
                            samplingRate: Int
                        ) {}
                        override fun onFftDataCapture(
                            v: Visualizer?,
                            fft: ByteArray?,
                            samplingRate: Int
                        ) {
                            fft?.let { visualizerEventSink?.success(it) }
                        }
                    },
                    30, // ~33 fps
                    false,
                    true
                )
                enabled = true
            }
            visualizer = viz
            Log.i("Visualizer", "Attached to session $sessionId with capture size ${viz.captureSize}")
            true
        } catch (e: Exception) {
            Log.e("Visualizer", "Failed to attach visualizer: ${e.message}", e)
            false
        }
    }

    private fun detachVisualizer() {
        visualizer?.enabled = false
        visualizer?.release()
        visualizer = null
        visualizerEventSink = null
    }

    private val btBatteryServiceUuid = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
    private val btBatteryCharUuid = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")

    private fun bluetoothAdapter(): BluetoothAdapter? =
        (getSystemService(BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun ensureA2dpProxy() {
        if (a2dpProxy != null) return
        val adapter = bluetoothAdapter() ?: return
        try {
            adapter.getProfileProxy(this, object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile?) {
                    if (profile == BluetoothProfile.A2DP) {
                        a2dpProxy = proxy as? BluetoothA2dp
                    }
                }
                override fun onServiceDisconnected(profile: Int) {
                    if (profile == BluetoothProfile.A2DP) a2dpProxy = null
                }
            }, BluetoothProfile.A2DP)
        } catch (e: SecurityException) {
            Log.w("Bluetooth", "getProfileProxy blocked (BLUETOOTH_CONNECT not granted?): ${e.message}")
        }
    }

    private fun getBluetoothDevices(includeBonded: Boolean): List<Map<String, Any?>> {
        val a2dp = a2dpProxy
        val connectedAddresses = try {
            a2dp?.connectedDevices?.map { it.address }?.toSet() ?: emptySet()
        } catch (e: SecurityException) {
            Log.w("Bluetooth", "connectedDevices blocked: ${e.message}")
            emptySet()
        }
        val connectedDevices = a2dp?.connectedDevices ?: emptyList()
        fun deviceMap(address: String, name: String): Map<String, Any?> = mapOf(
            "address" to address,
            "name" to name.ifBlank { "Unknown" },
            "isA2dp" to true,
            "isConnected" to (address in connectedAddresses)
        )
        val result = connectedDevices.map { deviceMap(it.address, it.name ?: "Unknown") }.toMutableList()
        if (includeBonded) {
            val adapter = bluetoothAdapter()
            val bonded = try {
                adapter?.bondedDevices ?: emptySet()
            } catch (e: SecurityException) {
                Log.w("Bluetooth", "bondedDevices blocked: ${e.message}")
                emptySet()
            }
            val seen = result.map { it["address"] as String }.toMutableSet()
            for (device in bonded) {
                val address = try { device.address } catch (e: SecurityException) { continue }
                if (address in seen) {
                    // upgrade existing entry's connected flag
                    val idx = result.indexOfFirst { it["address"] == address }
                    if (idx >= 0) result[idx] = deviceMap(address, device.name ?: "Unknown")
                    continue
                }
                val name = try { device.name ?: "Unknown" } catch (e: SecurityException) { "Unknown" }
                result.add(deviceMap(address, name))
                seen.add(address)
            }
        }
        // connected first
        return result.sortedByDescending { (it["isConnected"] as Boolean) }
    }

    private fun btCodecTypeLabel(t: Int): String = when (t) {
        0 -> "SBC"; 1 -> "AAC"; 2 -> "aptX"; 3 -> "aptX HD"; 4 -> "LDAC"; else -> "Codec $t"
    }

    private fun devLogD(msg: String) {
        if (developerMode) Log.d("FlickBT", msg)
    }
    private fun btDecodeSampleRate(bits: Int): Int? = when {
        bits and 0x1 != 0 -> 44100
        bits and 0x2 != 0 -> 88200
        bits and 0x4 != 0 -> 48000
        bits and 0x8 != 0 -> 96000
        bits and 0x10 != 0 -> 176400
        bits and 0x20 != 0 -> 192000
        else -> null
    }
    private fun btDecodeBitsPerSample(bits: Int): Int? = when {
        bits and 0x1 != 0 -> 16
        bits and 0x2 != 0 -> 24
        bits and 0x4 != 0 -> 32
        else -> null
    }
    private fun btDecodeChannelMode(bits: Int): String? = when {
        bits and 0x1 != 0 -> "Mono"
        bits and 0x2 != 0 -> "Stereo"
        bits and 0x4 != 0 -> "Dual"
        else -> null
    }

    // Requires API 33+ (BluetoothA2dp.getCodecStatus is @SystemApi → reflection).
    private fun getBluetoothCodecStatus(address: String): Map<String, Any?>? {
        relaxHiddenApiPolicy()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            devLogD("getCodecStatus: skipped (API ${Build.VERSION.SDK_INT} < 33)")
            return null
        }
        val a2dp = a2dpProxy ?: run {
            devLogD("getCodecStatus: no a2dpProxy")
            return null
        }
        val device = a2dp.connectedDevices.firstOrNull { it.address == address } ?: run {
            devLogD("getCodecStatus: device $address not among ${a2dp.connectedDevices.size} connected")
            return null
        }
        return try {
            val status = a2dp.javaClass
                .getMethod("getCodecStatus", BluetoothDevice::class.java)
                .invoke(a2dp, device) ?: return null
            val config = status.javaClass.getMethod("getCodecConfig").invoke(status) ?: return null
            val codecType = config.javaClass.getMethod("getCodecType").invoke(config) as Int
            val sampleRate = config.javaClass.getMethod("getSampleRate").invoke(config) as Int
            val bitsPerSample = config.javaClass.getMethod("getBitsPerSample").invoke(config) as Int
            val channelMode = config.javaClass.getMethod("getChannelMode").invoke(config) as Int
            val statusMap = mapOf(
                "codecName" to btCodecTypeLabel(codecType),
                "sampleRate" to btDecodeSampleRate(sampleRate),
                "bitsPerSample" to btDecodeBitsPerSample(bitsPerSample),
                "channelMode" to btDecodeChannelMode(channelMode)
            )
            devLogD("getCodecStatus: $address -> ${statusMap["codecName"]} ${statusMap["sampleRate"]}Hz ${statusMap["bitsPerSample"]}-bit")
            statusMap
        } catch (e: Exception) {
            devLogD("getCodecStatus: reflection failed: ${e.message}")
            Log.w("Bluetooth", "getCodecStatus failed: ${e.message}")
            null
        }
    }

    private var hiddenApiRelaxed = false

    /// Best-effort lift of the non-SDK API blocklist for this process so the
    /// hidden Bluetooth codec methods (setCodecConfigPreference, getCodecStatus)
    /// are reachable via reflection — same technique apps like UAPP use to
    /// switch A2DP codecs on Android 8+. Device-dependent; no-op if blocked.
    /// ponytail: process-global + idempotent; this is the known one-shot exemption.
    private fun relaxHiddenApiPolicy() {
        if (hiddenApiRelaxed) return
        hiddenApiRelaxed = true
        try {
            val vmRuntimeClass = Class.forName("dalvik.system.VMRuntime")
            // Meta-reflect through Class's own public getDeclaredMethod so the
            // blocklist check on VMRuntime is bypassed.
            val getDeclaredMethod = Class::class.java.getDeclaredMethod(
                "getDeclaredMethod", String::class.java, arrayOf<Class<*>>()::class.java
            )
            val setExemptions = getDeclaredMethod.invoke(
                vmRuntimeClass,
                "setHiddenApiExemptions",
                Array<String>::class.java,
            ) as java.lang.reflect.Method
            setExemptions.invoke(null, arrayOf<Any>(arrayOf("L")))
            devLogD("relaxHiddenApiPolicy: hidden-API exemption applied")
        } catch (e: Exception) {
            devLogD("relaxHiddenApiPolicy: unavailable (${e.javaClass.simpleName}: ${e.message})")
        }
    }

    private fun setBluetoothCodecConfigNative(
        address: String, codecType: Int, sampleRate: Int, bitsPerSample: Int, channelMode: Int, ldacBitrate: Int
    ): Map<String, Any?> {
        relaxHiddenApiPolicy()
        if (codecType < 0) {
            devLogD("setCodecConfig: codecType<0 (Automatic) — letting system decide")
            return mapOf("ok" to true, "reason" to "automatic")
        }
        val a2dp = a2dpProxy ?: run {
            devLogD("setCodecConfig: no a2dpProxy")
            return mapOf("ok" to false, "reason" to "no a2dpProxy (BLUETOOTH_CONNECT not granted or profile proxy not ready)")
        }
        val device = a2dp.connectedDevices.firstOrNull { it.address == address } ?: run {
            devLogD("setCodecConfig: device $address not among ${a2dp.connectedDevices.size} connected")
            val connected = a2dp.connectedDevices.joinToString(",") { it.address }
            return mapOf("ok" to false, "reason" to "device not in A2DP connected list (count=${a2dp.connectedDevices.size}; connected=[$connected])")
        }
        devLogD("setCodecConfig: requesting ${btCodecTypeLabel(codecType)} for $address (sr=$sampleRate bps=$bitsPerSample ch=$channelMode ldac=$ldacBitrate)")
        return try {
            val codecConfigClass = Class.forName("android.bluetooth.BluetoothCodecConfig")
            val constructor = codecConfigClass.getConstructor(
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                Long::class.javaPrimitiveType, Long::class.javaPrimitiveType,
                Long::class.javaPrimitiveType, Long::class.javaPrimitiveType
            )
            val codecPriorityHighest = 1_000_000
            val cs1 = if (codecType == 4) ldacBitrate.toLong() else 0L
            val config = constructor.newInstance(
                codecType, codecPriorityHighest,
                sampleRate, bitsPerSample, channelMode,
                cs1, 0L, 0L, 0L
            )
            // ponytail: successor to the removed setCodecConfig(device, config[])
            val setMethod = a2dp.javaClass.getMethod(
                "setCodecConfigPreference",
                BluetoothDevice::class.java, codecConfigClass
            )
            val ret = setMethod.invoke(a2dp, device, config)
            // Returns void on newer mainline modules, Boolean on older ones.
            // void + no exception = applied; Dart side verifies via getCodecStatus.
            val ok = if (setMethod.returnType == Boolean::class.javaPrimitiveType) {
                (ret as? Boolean) ?: false
            } else {
                true
            }
            devLogD("setCodecConfigPreference: ${btCodecTypeLabel(codecType)} returnType=${setMethod.returnType.simpleName} -> ok=$ok")
            mapOf("ok" to ok, "reason" to if (ok) "invoke succeeded (setCodecConfigPreference)" else "setCodecConfigPreference.invoke returned false")
        } catch (e: Exception) {
            val verdict = if (e is NoSuchMethodException) {
                val codecMethods = a2dp.javaClass.methods
                    .filter { it.name.contains("Codec", ignoreCase = true) }
                    .joinToString(", ") { m ->
                        "${m.name}(${m.parameterTypes.joinToString(",") { p -> p.simpleName }})"
                    }
                "setCodecConfigPreference(BluetoothDevice, BluetoothCodecConfig) not present on this " +
                    "device's BluetoothA2dp. Available codec methods: [$codecMethods]. " +
                    "App cannot switch A2DP codec here — use Android Developer Options → Bluetooth Audio Codec."
            } else {
                "reflection failed: ${e.message}"
            }
            devLogD("setCodecConfigPreference: $verdict")
            Log.w("Bluetooth", "setCodecConfigPreference failed: $verdict")
            mapOf("ok" to false, "reason" to verdict)
        }
    }

    private fun readBluetoothBatteryLevel(address: String, result: MethodChannel.Result) {
        val adapter = bluetoothAdapter()
        if (adapter == null) { result.success(null); return }
        val device = try { adapter.getRemoteDevice(address) } catch (e: Exception) { null }
        if (device == null) { result.success(null); return }
        val handler = Handler(Looper.getMainLooper())
        var finished = false
        fun finish(value: Int?) {
            if (!finished) { finished = true; result.success(value) }
        }
        val gattCallback = object : BluetoothGattCallback() {
            private fun report(value: ByteArray?) {
                finish(if (value != null && value.isNotEmpty()) value[0].toInt() and 0xFF else null)
            }
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> g.discoverServices()
                    BluetoothProfile.STATE_DISCONNECTED -> { try { g.close() } catch (_: Exception) {}; finish(null) }
                }
            }
            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val svc = g.getService(btBatteryServiceUuid)
                val ch = svc?.getCharacteristic(btBatteryCharUuid)
                if (ch != null) g.readCharacteristic(ch) else { try { g.close() } catch (_: Exception) {}; finish(null) }
            }
            override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
                report(value); try { g.close() } catch (_: Exception) {}
            }
        }
        val gatt = try {
            device.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: Exception) {
            finish(null); return
        }
        if (gatt == null) { finish(null); return }
        handler.postDelayed({
            if (!finished) {
                finished = true
                try { gatt.close() } catch (_: Exception) {}
                result.success(null)
            }
        }, 4000)
    }

    private fun setBluetoothAbsoluteVolume(address: String, enabled: Boolean): Boolean {
        return try {
            Settings.Global.putInt(contentResolver, "absolute_volume_enabled", if (enabled) 1 else 0)
        } catch (e: SecurityException) {
            Log.w("Bluetooth", "absolute volume blocked (needs WRITE_SECURE_SETTINGS): ${e.message}")
            false
        } catch (e: Exception) {
            Log.w("Bluetooth", "absolute volume failed: ${e.message}")
            false
        }
    }

    /// Opens Developer Options, where "Bluetooth Audio Codec" lives (the only
    /// reliable in-system way to switch the A2DP codec on stock Android).
    /// Returns false if Developer Options is disabled/unavailable.
    private fun openDeveloperOptions(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w("Bluetooth", "openDeveloperOptions failed: ${e.message}")
            false
        }
    }

    private fun registerBluetoothAclReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val action = intent?.action ?: return
                val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                }
                val event = when (action) {
                    BluetoothDevice.ACTION_ACL_CONNECTED -> "connected"
                    BluetoothDevice.ACTION_ACL_DISCONNECTED -> "disconnected"
                    else -> return
                }
                val address = try { device?.address ?: "" } catch (e: SecurityException) { "" }
                val name = try { device?.name ?: "Unknown" } catch (e: SecurityException) { "Unknown" }
                bluetoothEventSink?.success(mapOf("event" to event, "address" to address, "name" to name))
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, filter)
            }
            aclReceiver = receiver
        } catch (e: Exception) {
            Log.w("Bluetooth", "ACL receiver registration failed: ${e.message}")
        }
    }

    private fun registerAudioDeviceCallback() {
        if (audioDeviceCallback != null) {
            return
        }
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                // Keep the priority anchor pinned to the current music route
                // (e.g. re-pin from speaker to the 3.5mm jack when headphones
                // are plugged in mid-playback).
                priorityAnchorService.updateRouteDevice()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                priorityAnchorService.updateRouteDevice()
            }
        }
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.registerAudioDeviceCallback(callback, Handler(Looper.getMainLooper()))
            audioDeviceCallback = callback
        } catch (e: Exception) {
            Log.w("AudioDevice", "AudioDeviceCallback registration failed: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        audioDeviceCallback?.let {
            try {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.unregisterAudioDeviceCallback(it)
            } catch (e: Exception) {
                Log.w("AudioDevice", "AudioDeviceCallback unregistration failed: ${e.message}")
            }
        }
        audioDeviceCallback = null
        unregisterReceiverSafely(usbHotplugReceiver)
        unregisterReceiverSafely(usbPermissionReceiver)
        unregisterReceiverSafely(aclReceiver)
        aclReceiver = null
        unregisterVolumeContentObserver()
        justAudioProcessingController.release()
        detachVisualizer()
        usbHotplugReceiver = null
        usbPermissionReceiver = null
        try {
            bluetoothAdapter()?.closeProfileProxy(BluetoothProfile.A2DP, a2dpProxy)
        } catch (e: Exception) {
            Log.w("Bluetooth", "closeProfileProxy failed: ${e.message}")
        }
        a2dpProxy = null
        if (killIsochronousUsbOnQuit) {
            deactivateDirectUsb()
        }
    }

    companion object {
        private const val ACTION_USB_PERMISSION = "com.mossapps.flick.USB_PERMISSION"
        private val pluginRegistrationLock = Any()
        private var registeredMainEngineIdentity: Int? = null
    }

    private external fun nativeInitRustAndroidContext(context: Context): Boolean
    private external fun nativeRegisterRustDirectUsbDevice(
        fd: Int,
        vendorId: Int,
        productId: Int,
        productName: String,
        manufacturer: String,
        serial: String?,
        deviceName: String?,
    ): Boolean
    private external fun nativeSetRustDirectUsbPlaybackFormat(
        sampleRate: Int,
        bitDepth: Int,
        channels: Int,
        isDop: Boolean,
        isNativeDsd: Boolean,
    ): Boolean
    private external fun nativeSetRustDirectUsbLockEnabled(enabled: Boolean): Boolean
    private external fun nativeHasRustDirectUsbHardwareVolume(): Boolean
    private external fun nativeGetRustDirectUsbHardwareVolume(): Double
    private external fun nativeSetRustDirectUsbHardwareVolume(volume: Double): Boolean
    private external fun nativeGetRustDirectUsbHardwareMute(): Int
    private external fun nativeSetRustDirectUsbHardwareMute(muted: Boolean): Boolean
    private external fun nativeVerifyRustDirectUsbHardwareVolumeHealth(): Int
    private external fun nativeGetRustAudioDebugStateJson(): String?
    private external fun nativeClearRustDirectUsbPlayback(): Boolean
    private external fun nativeWaitRustDirectUsbSessionStopped(timeoutMs: Int): Boolean
    private external fun nativeIsRustDirectUsbSessionActive(): Boolean
    private external fun nativeMarkRustDirectUsbFallback(reason: String?): Boolean
    private external fun nativeSetRustDeveloperMode(enabled: Boolean)
}
