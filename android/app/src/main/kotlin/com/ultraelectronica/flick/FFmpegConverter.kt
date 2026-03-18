package com.ultraelectronica.flick

import android.content.Context
import android.net.Uri
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.FFmpegKitConfig
import com.arthenica.ffmpegkit.ReturnCode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File

class FFmpegConverter(private var currentSessionId: Long? = null) : AudioConverter {

    private val supportedExtensions = setOf("m4a", "alac", "aac", "mp3", "flac", "wav", "ogg")

    override fun isSupported(inputExtension: String): Boolean = inputExtension.lowercase() in supportedExtensions

    override suspend fun convertToFlac(inputUri: Uri, context: Context): ConversionResult =
        convert(inputUri, OutputFormat.FLAC, context)

    override suspend fun convertToMp3(inputUri: Uri, context: Context): ConversionResult =
        convert(inputUri, OutputFormat.MP3, context)

    override suspend fun convert(
        inputUri: Uri,
        outputFormat: OutputFormat,
        context: Context
    ): ConversionResult = withContext(Dispatchers.IO) {
        try {
            val inputPath = getInputPath(inputUri, context) ?: return@withContext ConversionResult.Error("Failed to access input file")
            val outputDir = File(context.filesDir, "transcoded").apply { mkdirs() }
            val inputName = getFileName(inputUri, context) ?: "input"
            val baseName = inputName.substringBeforeLast('.')
            val outputFileName = "${baseName}_${System.currentTimeMillis()}.${outputFormat.name.lowercase()}"
            val outputFile = File(outputDir, outputFileName)

            val command = buildCommand(inputPath, outputFile.absolutePath, outputFormat)

            executeCommand(command, outputFile, context)
        } catch (e: Exception) {
            ConversionResult.Error(e.message ?: "Unknown conversion error")
        }
    }

    override fun cancel() {
        currentSessionId?.let { sessionId ->
            FFmpegKit.cancel(sessionId)
        }
    }

    private fun buildCommand(inputPath: String, outputPath: String, format: OutputFormat): String {
        return when (format) {
            OutputFormat.FLAC -> buildString {
                append("-i \"$inputPath\" ")
                append("-af \"aformat=sample_fmts=s16:sample_rates=44100\" ")
                append("-y ")
                append("\"$outputPath\"")
            }
            OutputFormat.MP3 -> buildString {
                append("-i \"$inputPath\" ")
                append("-codec:a libmp3lame ")
                append("-q:a 2 ")
                append("-threads 4 ")
                append("-y ")
                append("\"$outputPath\"")
            }
        }
    }

    private suspend fun executeCommand(
        command: String,
        outputFile: File,
        context: Context
    ): ConversionResult = suspendCancellableCoroutine { continuation ->
        val session = FFmpegKit.executeAsync(command) { session ->
            val returnCode = session.returnCode

            when {
                ReturnCode.isSuccess(returnCode) -> {
                    if (outputFile.exists()) {
                        val outputUri = FFmpegKitConfig.getSafParameterForRead(context, outputFile.absolutePath)
                        continuation.resume(
                            ConversionResult.Success(outputUri, outputFile.absolutePath),
                            null
                        )
                    } else {
                        continuation.resume(
                            ConversionResult.Error("Output file not created"),
                            null
                        )
                    }
                }
                ReturnCode.isCancel(returnCode) -> {
                    continuation.resume(ConversionResult.Error("Conversion cancelled"), null)
                }
                else -> {
                    val errorMessage = session.failStackTrace ?: "Conversion failed"
                    continuation.resume(ConversionResult.Error(errorMessage), null)
                }
            }
            currentSessionId = null
        }

        currentSessionId = session.sessionId

        continuation.invokeOnCancellation {
            cancel()
        }
    }

    private fun getInputPath(uri: Uri, context: Context): String? {
        return try {
            FFmpegKitConfig.getSafParameterForRead(context, uri.toString())
        } catch (e: Exception) {
            null
        }
    }

    private fun getFileName(uri: Uri, context: Context): String? {
        return try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (cursor.moveToFirst() && nameIndex >= 0) {
                    cursor.getString(nameIndex)
                } else null
            }
        } catch (e: Exception) {
            uri.lastPathSegment
        }
    }
}
