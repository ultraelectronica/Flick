package com.ultraelectronica.flick

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log

class PriorityAnchorService(private val context: Context) {

    private var anchorTrack: AudioTrack? = null
    private var anchorThread: Thread? = null
    private var running = false

    companion object {
        private const val TAG = "PriorityAnchor"
        private const val ANCHOR_SAMPLE_RATE = 48000
        private const val ANCHOR_CHANNELS = AudioFormat.CHANNEL_OUT_STEREO
        private const val ANCHOR_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    fun start() {
        if (anchorTrack != null) {
            Log.d(TAG, "Anchor already active")
            return
        }

        val bufferSize = AudioTrack.getMinBufferSize(
            ANCHOR_SAMPLE_RATE, ANCHOR_CHANNELS, ANCHOR_FORMAT
        )
        if (bufferSize <= 0) {
            Log.e(TAG, "Invalid buffer size: $bufferSize")
            return
        }

        try {
            anchorTrack = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(ANCHOR_SAMPLE_RATE)
                        .setEncoding(ANCHOR_FORMAT)
                        .setChannelMask(ANCHOR_CHANNELS)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create AudioTrack: ${e.message}")
            anchorTrack = null
            return
        }

        val track = anchorTrack ?: return

        val builtinDevice = findBuiltinAudioDevice()
        if (builtinDevice != null) {
            track.preferredDevice = builtinDevice
            Log.d(TAG, "Routed anchor to built-in device: ${builtinDevice.productName}")
        } else {
            Log.w(TAG, "No built-in audio device found; anchor may route to USB DAC")
        }

        running = true

        try {
            track.play()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play anchor track: ${e.message}")
            track.release()
            anchorTrack = null
            running = false
            return
        }

        val bufferDurationMs = bufferDurationMs(bufferSize)
        val silence = ByteArray(bufferSize)

        anchorThread = Thread({
            while (running) {
                val written = track.write(silence, 0, silence.size)
                if (written < 0) {
                    Log.e(TAG, "Anchor write failed: $written")
                    break
                }
                try {
                    Thread.sleep(bufferDurationMs - 5)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }, "PriorityAnchor").apply {
            priority = Thread.NORM_PRIORITY
            start()
        }

        Log.d(TAG, "Priority anchor started")
    }

    fun stop() {
        if (anchorTrack == null) {
            return
        }
        running = false
        anchorThread?.interrupt()
        anchorThread = null
        try {
            anchorTrack?.stop()
            anchorTrack?.release()
        } catch (_: Exception) {
        }
        anchorTrack = null
        Log.d(TAG, "Priority anchor stopped")
    }

    private fun bufferDurationMs(bufferSizeBytes: Int): Long {
        val frames = bufferSizeBytes / 4
        return (frames * 1000L + ANCHOR_SAMPLE_RATE / 2) / ANCHOR_SAMPLE_RATE
    }

    @Suppress("DEPRECATION")
    private fun findBuiltinAudioDevice(): AudioDeviceInfo? {
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return devices.firstOrNull {
            it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                || it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
        }
    }
}