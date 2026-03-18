package com.ultraelectronica.flick

object AudioConverterFactory {
    fun create(): AudioConverter = FFmpegConverter()
}
