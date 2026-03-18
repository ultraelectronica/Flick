package com.ultraelectronica.flick

import android.net.Uri

sealed class ConversionResult {
    data class Success(val outputUri: String, val outputPath: String) : ConversionResult()
    data class Error(val message: String) : ConversionResult()
    data class Progress(val progress: Float) : ConversionResult()
}

enum class OutputFormat { FLAC, MP3 }

interface AudioConverter {
    suspend fun convertToFlac(inputUri: Uri, context: android.content.Context): ConversionResult
    suspend fun convertToMp3(inputUri: Uri, context: android.content.Context): ConversionResult
    suspend fun convert(inputUri: Uri, outputFormat: OutputFormat, context: android.content.Context): ConversionResult
    fun cancel()
    fun isSupported(inputExtension: String): Boolean
}
