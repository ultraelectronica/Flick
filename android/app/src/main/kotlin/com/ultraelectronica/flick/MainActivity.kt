package com.ultraelectronica.flick

import android.content.Intent
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.ultraelectronica.flick/storage"
    private val REQUEST_OPEN_DOCUMENT_TREE = 1001

    private var pendingResult: MethodChannel.Result? = null

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
                        val files = listAudioFilesRecursive(uri)
                        result.success(files)
                    } else {
                        result.error("INVALID_ARGUMENT", "URI is required", null)
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

    private fun listAudioFilesRecursive(uriString: String): List<Map<String, Any?>> {
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
}
