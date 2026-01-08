package com.ultraelectronica.flick

import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.ultraelectronica.flick/storage"
    private val PLAYER_CHANNEL = "com.ultraelectronica.flick/player"
    private val REQUEST_OPEN_DOCUMENT_TREE = 1001

    private var pendingResult: MethodChannel.Result? = null
    // Coroutine scope for background tasks
    private val mainScope = CoroutineScope(Dispatchers.Main)

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        var engine = FlutterEngineCache.getInstance().get("main_engine")
        if (engine == null) {
            engine = FlutterEngine(context)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
            FlutterEngineCache.getInstance().put("main_engine", engine)
        }
        return engine
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openDocumentTree" -> {
                    pendingResult = result
                    openDocumentTree()
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
                "listAudioFiles" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        // Launch in background to avoid blocking UI
                        mainScope.launch {
                            try {
                                val files = withContext(Dispatchers.IO) {
                                    fastScanAudioFiles(uri)
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
                "getDocumentDisplayName" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        val displayName = getDocumentDisplayName(uri)
                        result.success(displayName)
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
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
                    
                    val intent = Intent(this, MusicNotificationService::class.java).apply {
                        putExtra("title", title)
                        putExtra("artist", artist)
                        putExtra("albumArtPath", albumArtPath)
                        putExtra("isPlaying", isPlaying)
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
                    
                    val intent = Intent(this, MusicNotificationService::class.java).apply {
                        title?.let { putExtra("title", it) }
                        artist?.let { putExtra("artist", it) }
                        albumArtPath?.let { putExtra("albumArtPath", it) }
                        isPlaying?.let { putExtra("isPlaying", it) }
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
    }

    private fun openDocumentTree() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_OPEN_DOCUMENT_TREE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQUEST_OPEN_DOCUMENT_TREE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                pendingResult?.success(uri.toString())
            } else {
                pendingResult?.success(null)
            }
            pendingResult = null
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

    private fun getDocumentDisplayName(uriString: String): String? {
        return try {
            val uri = Uri.parse(uriString)
            val documentFile = DocumentFile.fromTreeUri(this, uri)
            documentFile?.name
        } catch (e: Exception) {
            null
        }
    }

    // Phase 1: Fast Scan (Filesystem only)
    private fun fastScanAudioFiles(uriString: String): List<Map<String, Any?>> {
        val uri = Uri.parse(uriString)
        val documentFile = DocumentFile.fromTreeUri(this, uri) ?: return emptyList()
        
        val audioExtensions = setOf("mp3", "flac", "wav", "aac", "m4a", "ogg", "opus", "wma", "alac")
        val result = mutableListOf<Map<String, Any?>>()

        fun scanDirectory(dir: DocumentFile) {
            for (file in dir.listFiles()) {
                if (file.isDirectory) {
                    scanDirectory(file)
                } else if (file.isFile) {
                    val name = file.name ?: continue
                    val extension = name.substringAfterLast('.', "").lowercase()
                    if (extension in audioExtensions) {
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

    // Phase 2: Metadata Extraction (Targeted)
    private fun extractMetadataForFiles(uris: List<String>): List<Map<String, Any?>> {
        val retriever = MediaMetadataRetriever()
        val result = mutableListOf<Map<String, Any?>>()
        // Use filesDir instead of cacheDir for persistent album art storage
        // cacheDir can be cleared by Android at any time when storage is low
        val albumArtDir = java.io.File(filesDir, "album_art").apply { mkdirs() }

        for (uriString in uris) {
            try {
                val uri = Uri.parse(uriString)
                retriever.setDataSource(context, uri)
                
                val metadata = mutableMapOf<String, Any?>("uri" to uriString)
                
                metadata["title"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                metadata["artist"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                metadata["album"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                metadata["bitrate"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                metadata["mimeType"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
                
                val durationStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                if (durationStr != null) {
                    metadata["duration"] = durationStr.toLongOrNull()
                }

                // Extract Album Art
                val embeddedArt = retriever.embeddedPicture
                if (embeddedArt != null) {
                    try {
                        // Use MD5 of URI as filename to avoid collisions and invalid chars
                        val filename = java.math.BigInteger(1, java.security.MessageDigest.getInstance("MD5").digest(uriString.toByteArray())).toString(16) + ".jpg"
                        val file = java.io.File(albumArtDir, filename)
                        
                        // Only write if not exists or maybe overwrite? 
                        // For performance, check existence. 
                        // But what if art changed? (Unlikely for same URI without modified time change, but we assume immutable for now)
                        if (!file.exists()) {
                            file.writeBytes(embeddedArt)
                        }
                        metadata["albumArtPath"] = file.absolutePath
                    } catch (e: Exception) {
                        // Failed to save art
                    }
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
}

