package com.ultraelectronica.flick

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.media.AudioDeviceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.os.PowerManager
import androidx.documentfile.provider.DocumentFile
import com.ultraelectronica.flick.audiofx.JustAudioProcessingController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlin.math.roundToInt

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.ultraelectronica.flick/storage"
    private val PLAYER_CHANNEL = "com.ultraelectronica.flick/player"
    private val INTEGRATION_CHANNEL = "com.ultraelectronica.flick/integration"
    private val UAC2_CHANNEL = "com.ultraelectronica.flick/uac2"
    private val AUDIO_DEVICE_CHANNEL = "com.ultraelectronica.flick/audio_device"
    private val EQUALIZER_CHANNEL = "com.ultraelectronica.flick/equalizer"
    private val LOCKER_PACKAGE = "com.ultraelectronica.locker"
    private val LOCKER_RETURN_URI = "locker://return?source=flick"
    // private val CONVERTER_CHANNEL = "com.ultraelectronica.flick/converter"
    private val REQUEST_OPEN_DOCUMENT_TREE = 1001
    private val REQUEST_OPEN_DOCUMENT = 1003
    private val REQUEST_CREATE_DOCUMENT = 1004
    private val REQUEST_USB_PERMISSION = 1002

    private var pendingDocumentTreeResult: MethodChannel.Result? = null
    private var pendingOpenDocumentResult: MethodChannel.Result? = null
    private var pendingCreateDocumentResult: MethodChannel.Result? = null
    private var pendingUac2PermissionResult: MethodChannel.Result? = null
    private var pendingUac2PermissionCallback: ((Boolean) -> Unit)? = null
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
    // private var audioConverter: AudioConverter? = null
    // Coroutine scope for background tasks
    private val mainScope = CoroutineScope(Dispatchers.Main)

    // Load the Rust shared library before calling into native startup hooks.
    init {
        System.loadLibrary("rust_lib_flick_player")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (!nativeInitRustAndroidContext(applicationContext)) {
            Log.e("Flick", "Failed to initialize Rust Android audio context")
        } else {
            Log.i("Flick", "Rust Android audio context initialized")
        }

        handleExternalPlaybackIntent(intent)
        handleUsbAttachIntent(intent)
        maybeRequestPermissionForConnectedUsbAudioDevices(reason = "activity create")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
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
                    if (uri != null) {
                        mainScope.launch {
                            try {
                                val stagedPath = withContext(Dispatchers.IO) {
                                    cacheUriForPlayback(uri, extensionHint)
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
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "openBatteryOptimizationSettings" -> {
                    result.success(openBatteryOptimizationSettings())
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
                else -> result.notImplemented()
            }
        }
        
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
                    
                    val intent = Intent(this, MusicNotificationService::class.java).apply {
                        putExtra("title", title)
                        putExtra("artist", artist)
                        putExtra("albumArtPath", albumArtPath)
                        putExtra("isPlaying", isPlaying)
                        putExtra("duration", duration)
                        putExtra("position", position)
                        putExtra("isShuffle", isShuffle)
                        putExtra("isFavorite", isFavorite)
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
                    
                    val intent = Intent(this, MusicNotificationService::class.java).apply {
                        title?.let { putExtra("title", it) }
                        artist?.let { putExtra("artist", it) }
                        albumArtPath?.let { putExtra("albumArtPath", it) }
                        isPlaying?.let { putExtra("isPlaying", it) }
                        duration?.let { putExtra("duration", it) }
                        position?.let { putExtra("position", it) }
                        isShuffle?.let { putExtra("isShuffle", it) }
                        isFavorite?.let { putExtra("isFavorite", it) }
                    }
                    startService(intent)
                    result.success(null)
                }
                "hideNotification" -> {
                    stopService(Intent(this, MusicNotificationService::class.java))
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
                    if (sampleRate != null && bitDepth != null && channels != null) {
                        result.success(
                            nativeSetRustDirectUsbPlaybackFormat(
                                sampleRate,
                                bitDepth,
                                channels,
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
                    result.success(nativeSetRustDirectUsbPlaybackFormat(0, 0, 0))
                }
                "deactivateDirectUsb" -> {
                    result.success(deactivateDirectUsb())
                }
                "markDirectUsbFallback" -> {
                    val reason = call.argument<String>("reason")
                    result.success(nativeMarkRustDirectUsbFallback(reason))
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

        // Audio processing channel for Android native AudioEffect counterparts.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EQUALIZER_CHANNEL).setMethodCallHandler { call, result ->
            if (!justAudioProcessingController.handle(call, result)) {
                result.notImplemented()
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
        }
    }

    private fun takePersistableUriPermission(uriString: String): Boolean {
        return try {
            val uri = Uri.parse(uriString)
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun releasePersistableUriPermission(uriString: String) {
        try {
            val uri = Uri.parse(uriString)
            contentResolver.releasePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (e: Exception) {
            // Ignore if permission wasn't held
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
        return try {
            val uri = Uri.parse(uriString)
            if (uri.scheme == "file") {
                return uri.path
            }

            if (uri.scheme != "content" ||
                uri.authority != "com.android.externalstorage.documents"
            ) {
                return null
            }

            val documentId = DocumentsContract.getTreeDocumentId(uri)
            val decodedId = Uri.decode(documentId)
            val parts = decodedId.split(":", limit = 2)
            if (parts.isEmpty()) {
                return null
            }

            val volumeId = parts[0]
            val relativePath = parts.getOrNull(1)?.trim('/') ?: ""
            val basePath = when (volumeId.lowercase()) {
                "primary" -> Environment.getExternalStorageDirectory().absolutePath
                "home" -> Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOCUMENTS
                ).absolutePath
                else -> "/storage/$volumeId"
            }

            val candidate = if (relativePath.isEmpty()) {
                basePath
            } else {
                "$basePath/$relativePath"
            }

            val candidateFile = File(candidate)
            if (!candidateFile.exists() || !candidateFile.canRead()) {
                return null
            }

            candidateFile.absolutePath
        } catch (e: Exception) {
            Log.w("MainActivity", "Failed to resolve tree URI to path: $uriString", e)
            null
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
        return powerManager?.isIgnoringBatteryOptimizations(packageName) ?: false
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        return try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            }.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w("MainActivity", "Failed to open battery optimization settings", e)
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
    private fun fastScanAudioFiles(
        uriString: String,
        filterNonMusicFilesAndFolders: Boolean
    ): List<Map<String, Any?>> {
        val uri = Uri.parse(uriString)
        val documentFile = DocumentFile.fromTreeUri(this, uri) ?: return emptyList()

        val audioExtensions =
            setOf("mp3", "flac", "wav", "aac", "m4a", "ogg", "oga", "ogx", "opus", "wma", "alac", "aif", "aiff")
        val result = mutableListOf<Map<String, Any?>>()

        fun scanDirectory(dir: DocumentFile) {
            val children = dir.listFiles()
            if (filterNonMusicFilesAndFolders &&
                children.any { child -> child.name == ".nomedia" }
            ) {
                return
            }

            for (file in children) {
                if (file.isDirectory) {
                    scanDirectory(file)
                } else if (file.isFile) {
                    val name = file.name ?: continue
                    val extension = name.substringAfterLast('.', "").lowercase()
                    if (!filterNonMusicFilesAndFolders || extension in audioExtensions) {
                        result.add(mapOf(
                            "uri" to file.uri.toString(),
                            "name" to name,
                            "size" to file.length(),
                            "lastModified" to file.lastModified(),
                            "mimeType" to file.type,
                            "extension" to extension
                        ))
                    }
                }
            }
        }

        scanDirectory(documentFile)
        return result
    }

    private fun scanPlaylistFiles(
        uriString: String,
        filterNonMusicFilesAndFolders: Boolean
    ): List<Map<String, Any?>> {
        val uri = Uri.parse(uriString)
        val documentFile = DocumentFile.fromTreeUri(this, uri) ?: return emptyList()
        val playlistExtensions = setOf("m3u", "m3u8")
        val result = mutableListOf<Map<String, Any?>>()

        fun scanDirectory(dir: DocumentFile) {
            val children = dir.listFiles()
            if (filterNonMusicFilesAndFolders &&
                children.any { child -> child.name == ".nomedia" }
            ) {
                return
            }

            for (file in children) {
                if (file.isDirectory) {
                    scanDirectory(file)
                } else if (file.isFile) {
                    val name = file.name ?: continue
                    val extension = name.substringAfterLast('.', "").lowercase()
                    if (extension in playlistExtensions) {
                        result.add(
                            mapOf(
                                "uri" to file.uri.toString(),
                                "name" to name,
                                "size" to file.length(),
                                "lastModified" to file.lastModified(),
                                "extension" to extension,
                            )
                        )
                    }
                }
            }
        }

        scanDirectory(documentFile)
        return result
    }

    // Phase 2: Metadata Extraction (Targeted)
    private fun extractMetadataForFiles(uris: List<String>): List<Map<String, Any?>> {
        val retriever = MediaMetadataRetriever()
        val result = mutableListOf<Map<String, Any?>>()

        for (uriString in uris) {
            try {
                val uri = Uri.parse(uriString)
                retriever.setDataSource(context, uri)
                
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

                result.add(metadata)
            } catch (e: Exception) {
                // Return just the URI if metadata fails, so Dart knows we tried
                result.add(mapOf("uri" to uriString))
            }
        }

        try {
            retriever.release()
        } catch (e: Exception) {
            // Ignore
        }

        return result
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

    private fun cacheUriForPlayback(uriString: String, extensionHint: String?): String? {
        val uri = Uri.parse(uriString)
        val normalizedExt = normalizeAudioExtension(extensionHint)
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
                        null
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
                    if (!skipFully(input, blockLength)) break
                }
            }
            null
        }
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

    private fun skipFully(input: InputStream, bytesToSkip: Int): Boolean {
        var remaining = bytesToSkip.toLong()
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
        val candidateNames = listOf("$stem.lrc", "$stem.txt")
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
        val candidateNames = listOf("$stem.lrc", "$stem.txt", "$stem.LRC", "$stem.TXT")

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

        return deviceHasIsochronousEndpoint(device) && looksLikeUsbAudioName(device)
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
                Intent(ACTION_USB_PERMISSION),
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
                    "[USB] Timed out waiting for Rust direct USB shutdown; keeping connection open for ${deviceName ?: "unknown"}",
                )
                updateDirectUsbAudioFocus()
                return false
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

    private fun setRouteVolume(volume: Double): Boolean {
        if (hasDirectUsbHardwareVolume()) {
            return nativeSetRustDirectUsbHardwareVolume(volume.coerceIn(0.0, 1.0))
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
    
    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiverSafely(usbHotplugReceiver)
        unregisterReceiverSafely(usbPermissionReceiver)
        unregisterVolumeContentObserver()
        justAudioProcessingController.release()
        usbHotplugReceiver = null
        usbPermissionReceiver = null
        deactivateDirectUsb()
    }

    companion object {
        private const val ACTION_USB_PERMISSION = "com.ultraelectronica.flick.USB_PERMISSION"
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
    ): Boolean
    private external fun nativeSetRustDirectUsbLockEnabled(enabled: Boolean): Boolean
    private external fun nativeHasRustDirectUsbHardwareVolume(): Boolean
    private external fun nativeGetRustDirectUsbHardwareVolume(): Double
    private external fun nativeSetRustDirectUsbHardwareVolume(volume: Double): Boolean
    private external fun nativeGetRustDirectUsbHardwareMute(): Int
    private external fun nativeSetRustDirectUsbHardwareMute(muted: Boolean): Boolean
    private external fun nativeGetRustAudioDebugStateJson(): String?
    private external fun nativeClearRustDirectUsbPlayback(): Boolean
    private external fun nativeWaitRustDirectUsbSessionStopped(timeoutMs: Int): Boolean
    private external fun nativeIsRustDirectUsbSessionActive(): Boolean
    private external fun nativeMarkRustDirectUsbFallback(reason: String?): Boolean
}
