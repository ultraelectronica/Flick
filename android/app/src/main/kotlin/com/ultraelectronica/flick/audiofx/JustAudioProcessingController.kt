package com.ultraelectronica.flick.audiofx

import android.media.audiofx.AudioEffect
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.EnvironmentalReverb
import android.media.audiofx.Equalizer
import android.media.audiofx.Virtualizer
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.roundToInt

internal class JustAudioProcessingController {
    private var attachedSessionId: Int? = null
    private var equalizer: Equalizer? = null
    private var dynamicsProcessing: DynamicsProcessing? = null
    private var environmentalReverb: EnvironmentalReverb? = null
    private var virtualizer: Virtualizer? = null

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method != METHOD_APPLY_AUDIO_PROCESSING) {
            return false
        }

        val request = AudioProcessingRequest.from(call.arguments)
        if (request == null) {
            result.error(
                "INVALID_ARGUMENT",
                "Expected a valid audio processing payload for just_audio",
                null,
            )
            return true
        }

        apply(request, result)
        return true
    }

    fun release() {
        releaseAll()
    }

    private fun apply(request: AudioProcessingRequest, result: MethodChannel.Result) {
        try {
            if (!request.requiresAudioSession) {
                releaseAll()
                result.success(null)
                return
            }

            val sessionId = request.audioSessionId ?: run {
                result.error(
                    "AUDIO_SESSION_NOT_READY",
                    "Audio session not ready. Start playback first.",
                    null,
                )
                return
            }

            ensureSession(sessionId)
            applyEqualizer(sessionId, request)
            applyDynamics(sessionId, request)
            applyCreativeFx(sessionId, request.fx)
            result.success(null)
        } catch (e: Exception) {
            result.error(
                "AUDIO_PROCESSING_ERROR",
                "Failed to apply audio processing: ${e.message}",
                null,
            )
        }
    }

    private fun ensureSession(sessionId: Int) {
        if (attachedSessionId == sessionId) {
            return
        }

        releaseAll()
        attachedSessionId = sessionId
    }

    private fun applyEqualizer(sessionId: Int, request: AudioProcessingRequest) {
        if (!request.hasEqualizer) {
            releaseEqualizer()
            return
        }

        val effect = equalizer ?: createEqualizer(sessionId)?.also { equalizer = it } ?: return

        try {
            effect.enabled = true

            val bandCount = effect.numberOfBands.toInt()
            val bandLevelRange = effect.bandLevelRange
            val minLevelDb = bandLevelRange[0] / 100.0
            val maxLevelDb = bandLevelRange[1] / 100.0

            for (bandIndex in 0 until bandCount) {
                val startIndex = (bandIndex * request.gainsDb.size) / bandCount
                val endIndex = ((bandIndex + 1) * request.gainsDb.size) / bandCount
                val averagedGainDb = request.gainsDb
                    .subList(startIndex, endIndex)
                    .average()
                    .coerceIn(minLevelDb, maxLevelDb)
                effect.setBandLevel(
                    bandIndex.toShort(),
                    (averagedGainDb * 100).roundToInt().toShort(),
                )
            }
        } catch (e: Exception) {
            logAndRelease("Equalizer", e) { releaseEqualizer() }
        }
    }

    private fun applyDynamics(sessionId: Int, request: AudioProcessingRequest) {
        if (!request.hasDynamics || Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            releaseDynamics()
            return
        }

        val effect = dynamicsProcessing
            ?: createDynamicsProcessing(sessionId)?.also { dynamicsProcessing = it }
            ?: return

        try {
            effect.enabled = true

            for (channelIndex in 0 until effect.channelCount) {
                effect.setInputGainbyChannel(
                    channelIndex,
                    computeChannelInputGainDb(
                        channelIndex = channelIndex,
                        channelCount = effect.channelCount,
                        limiter = request.limiter,
                        fx = request.fx,
                    ),
                )

                val mbc = effect.getMbcByChannelIndex(channelIndex)
                mbc.setEnabled(request.compressor.enabled)
                for (bandIndex in 0 until mbc.bandCount) {
                    val band = mbc.getBand(bandIndex)
                    configureCompressorBand(band, request.compressor)
                    mbc.setBand(bandIndex, band)
                }
                effect.setMbcByChannelIndex(channelIndex, mbc)

                val limiter = effect.getLimiterByChannelIndex(channelIndex)
                configureLimiter(limiter, request.limiter)
                effect.setLimiterByChannelIndex(channelIndex, limiter)
            }
        } catch (e: Exception) {
            logAndRelease("DynamicsProcessing", e) { releaseDynamics() }
        }
    }

    private fun applyCreativeFx(sessionId: Int, fx: FxPayload) {
        if (!fx.hasNativeCounterpart) {
            releaseCreativeFx()
            return
        }

        applyReverb(sessionId, fx)
        applyVirtualizer(sessionId, fx)
    }

    private fun applyReverb(sessionId: Int, fx: FxPayload) {
        if (!fx.usesReverb) {
            releaseReverb()
            return
        }

        val effect = environmentalReverb
            ?: createEnvironmentalReverb(sessionId)?.also { environmentalReverb = it }
            ?: return

        try {
            effect.enabled = true
            effect.setRoomLevel(mapRoomLevel(fx.mix))
            effect.setRoomHFLevel(mapRoomHighFrequencyLevel(fx.filterHz, fx.damp))
            effect.setDecayTime(mapDecayTime(fx.size, fx.feedback))
            effect.setDecayHFRatio(mapDecayHighFrequencyRatio(fx.damp))
            effect.setReflectionsLevel(mapReflectionsLevel(fx.mix, fx.balance))
            effect.setReflectionsDelay(mapReflectionsDelay(fx.delayMs, fx.tempo))
            effect.setReverbLevel(mapReverbLevel(fx.mix, fx.feedback))
            effect.setReverbDelay(mapReverbDelay(fx.delayMs, fx.tempo))
            effect.setDiffusion(mapDiffusion(fx.feedback, fx.tempo))
            effect.setDensity(mapDensity(fx.size))
        } catch (e: Exception) {
            logAndRelease("EnvironmentalReverb", e) { releaseReverb() }
        }
    }

    private fun applyVirtualizer(sessionId: Int, fx: FxPayload) {
        if (!fx.usesVirtualizer) {
            releaseVirtualizer()
            return
        }

        val effect = virtualizer ?: createVirtualizer(sessionId)?.also { virtualizer = it } ?: return

        try {
            effect.enabled = true
            effect.setStrength(mapVirtualizerStrength(fx.width))
        } catch (e: Exception) {
            logAndRelease("Virtualizer", e) { releaseVirtualizer() }
        }
    }

    private fun configureCompressorBand(
        band: DynamicsProcessing.MbcBand,
        compressor: CompressorPayload,
    ) {
        band.setEnabled(compressor.enabled)
        band.setAttackTime(compressor.attackMs.toFloat())
        band.setReleaseTime(compressor.releaseMs.toFloat())
        band.setRatio(compressor.ratio.toFloat())
        band.setThreshold(compressor.thresholdDb.toFloat())
        band.setKneeWidth(COMPRESSOR_KNEE_WIDTH_DB)
        band.setNoiseGateThreshold(COMPRESSOR_NOISE_GATE_DB)
        band.setExpanderRatio(COMPRESSOR_EXPANDER_RATIO)
        band.setPreGain(0f)
        band.setPostGain(compressor.makeupGainDb.toFloat())
    }

    private fun configureLimiter(
        limiter: DynamicsProcessing.Limiter,
        settings: LimiterPayload,
    ) {
        limiter.setEnabled(settings.enabled)
        limiter.setLinkGroup(LIMITER_LINK_GROUP)
        limiter.setAttackTime(LIMITER_ATTACK_MS)
        limiter.setReleaseTime(settings.releaseMs.toFloat())
        limiter.setRatio(LIMITER_RATIO)
        limiter.setThreshold(settings.ceilingDb.toFloat())
        limiter.setPostGain(0f)
    }

    private fun computeChannelInputGainDb(
        channelIndex: Int,
        channelCount: Int,
        limiter: LimiterPayload,
        fx: FxPayload,
    ): Float {
        val limiterGainDb = if (limiter.enabled) limiter.inputGainDb else 0.0
        val (leftGain, rightGain) = balanceGains(fx.balance)
        val balanceGainDb = when {
            !fx.usesBalance || channelCount < 2 -> 0.0
            channelIndex % 2 == 0 -> panGainToDb(leftGain)
            else -> panGainToDb(rightGain)
        }
        return (limiterGainDb + balanceGainDb)
            .coerceIn(MIN_CHANNEL_INPUT_GAIN_DB, MAX_CHANNEL_INPUT_GAIN_DB)
            .toFloat()
    }

    private fun createEqualizer(sessionId: Int): Equalizer? {
        return try {
            Equalizer(0, sessionId)
        } catch (e: Exception) {
            logEffectFailure("Equalizer", e)
            null
        }
    }

    private fun createDynamicsProcessing(sessionId: Int): DynamicsProcessing? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return null
        }

        return try {
            DynamicsProcessing(sessionId)
        } catch (e: Exception) {
            logEffectFailure("DynamicsProcessing", e)
            null
        }
    }

    private fun createEnvironmentalReverb(sessionId: Int): EnvironmentalReverb? {
        return try {
            EnvironmentalReverb(0, sessionId)
        } catch (e: Exception) {
            logEffectFailure("EnvironmentalReverb", e)
            null
        }
    }

    private fun createVirtualizer(sessionId: Int): Virtualizer? {
        return try {
            Virtualizer(0, sessionId)
        } catch (e: Exception) {
            logEffectFailure("Virtualizer", e)
            null
        }
    }

    private fun releaseAll() {
        releaseEqualizer()
        releaseDynamics()
        releaseCreativeFx()
        attachedSessionId = null
    }

    private fun releaseCreativeFx() {
        releaseReverb()
        releaseVirtualizer()
    }

    private fun releaseEqualizer() {
        releaseAudioEffect(equalizer)
        equalizer = null
    }

    private fun releaseDynamics() {
        releaseAudioEffect(dynamicsProcessing)
        dynamicsProcessing = null
    }

    private fun releaseReverb() {
        releaseAudioEffect(environmentalReverb)
        environmentalReverb = null
    }

    private fun releaseVirtualizer() {
        releaseAudioEffect(virtualizer)
        virtualizer = null
    }

    private fun releaseAudioEffect(effect: AudioEffect?) {
        try {
            effect?.release()
        } catch (_: Exception) {
        }
    }

    private fun logAndRelease(label: String, error: Exception, release: () -> Unit) {
        logEffectFailure(label, error)
        release()
    }

    private fun logEffectFailure(label: String, error: Exception) {
        Log.w(TAG, "$label counterpart unavailable for just_audio: ${error.message}")
    }

    private fun mapRoomLevel(mix: Double): Short {
        return mapDouble(mix, 0.0, 1.0, -9000.0, -1200.0)
            .roundToInt()
            .coerceIn(-9000, 0)
            .toShort()
    }

    private fun mapRoomHighFrequencyLevel(filterHz: Double, damp: Double): Short {
        val logMin = ln(FILTER_MIN_HZ)
        val logMax = ln(FILTER_MAX_HZ)
        val clampedFilterHz = filterHz.coerceIn(FILTER_MIN_HZ, FILTER_MAX_HZ)
        val filterT = ((ln(clampedFilterHz) - logMin) / (logMax - logMin)).coerceIn(0.0, 1.0)
        val filterLevel = mapDouble(filterT, 0.0, 1.0, -8500.0, 0.0)
        val dampingCut = mapDouble(damp, 0.0, 1.0, 0.0, 2500.0)
        return (filterLevel - dampingCut)
            .roundToInt()
            .coerceIn(-9000, 0)
            .toShort()
    }

    private fun mapDecayTime(size: Double, feedback: Double): Int {
        val sizeT = size.coerceIn(0.0, 1.0)
        val feedbackT = (feedback.coerceIn(0.0, 0.95) / 0.95)
        val combined = (sizeT * 0.55) + (feedbackT * 0.45)
        return mapDouble(combined, 0.0, 1.0, 250.0, 7000.0)
            .roundToInt()
            .coerceIn(100, 7000)
    }

    private fun mapDecayHighFrequencyRatio(damp: Double): Short {
        return mapDouble(1.0 - damp.coerceIn(0.0, 1.0), 0.0, 1.0, 100.0, 2000.0)
            .roundToInt()
            .coerceIn(100, 2000)
            .toShort()
    }

    private fun mapReflectionsLevel(mix: Double, balance: Double): Short {
        val centeredBalance = 1.0 - balance.coerceIn(-1.0, 1.0).let { abs(it) }
        val weightedMix = (mix.coerceIn(0.0, 1.0) * 0.8) + (centeredBalance * 0.2)
        return mapDouble(weightedMix, 0.0, 1.0, -9000.0, -500.0)
            .roundToInt()
            .coerceIn(-9000, 1000)
            .toShort()
    }

    private fun mapReflectionsDelay(delayMs: Double, tempo: Double): Int {
        val tempoFactor = mapDouble(tempo.coerceIn(0.5, 2.0), 0.5, 2.0, 1.15, 0.75)
        return (delayMs * tempoFactor)
            .roundToInt()
            .coerceIn(0, 300)
    }

    private fun mapReverbLevel(mix: Double, feedback: Double): Short {
        val combined = ((mix.coerceIn(0.0, 1.0) * 0.7) +
            ((feedback.coerceIn(0.0, 0.95) / 0.95) * 0.3))
        return mapDouble(combined, 0.0, 1.0, -7000.0, 0.0)
            .roundToInt()
            .coerceIn(-9000, 2000)
            .toShort()
    }

    private fun mapReverbDelay(delayMs: Double, tempo: Double): Int {
        val baseDelayMs = delayMs.coerceIn(10.0, 1600.0)
        val tempoFactor = mapDouble(tempo.coerceIn(0.5, 2.0), 0.5, 2.0, 0.45, 0.2)
        return (baseDelayMs * tempoFactor)
            .roundToInt()
            .coerceIn(0, 100)
    }

    private fun mapDiffusion(feedback: Double, tempo: Double): Short {
        val feedbackT = feedback.coerceIn(0.0, 0.95) / 0.95
        val tempoT = mapDouble(tempo.coerceIn(0.5, 2.0), 0.5, 2.0, 0.0, 1.0)
        val combined = (feedbackT * 0.7) + (tempoT * 0.3)
        return mapDouble(combined, 0.0, 1.0, 150.0, 1000.0)
            .roundToInt()
            .coerceIn(0, 1000)
            .toShort()
    }

    private fun mapDensity(size: Double): Short {
        return mapDouble(size.coerceIn(0.0, 1.0), 0.0, 1.0, 200.0, 1000.0)
            .roundToInt()
            .coerceIn(0, 1000)
            .toShort()
    }

    private fun mapVirtualizerStrength(width: Double): Short {
        val normalizedWidth = mapDouble(width.coerceIn(1.0, 2.0), 1.0, 2.0, 0.0, 1.0)
        return mapDouble(normalizedWidth, 0.0, 1.0, 0.0, 1000.0)
            .roundToInt()
            .coerceIn(0, 1000)
            .toShort()
    }

    private fun balanceGains(balance: Double): Pair<Double, Double> {
        val clamped = balance.coerceIn(-1.0, 1.0)
        return if (clamped >= 0.0) {
            Pair(1.0 - clamped, 1.0)
        } else {
            Pair(1.0, 1.0 + clamped)
        }
    }

    private fun panGainToDb(gain: Double): Double {
        val clamped = gain.coerceIn(MIN_PAN_LINEAR_GAIN, 1.0)
        return if (clamped <= MIN_PAN_LINEAR_GAIN) {
            MIN_CHANNEL_INPUT_GAIN_DB
        } else {
            20.0 * ln(clamped) / ln(10.0)
        }
    }

    private fun mapDouble(
        value: Double,
        inMin: Double,
        inMax: Double,
        outMin: Double,
        outMax: Double,
    ): Double {
        if (inMax == inMin) {
            return outMin
        }

        val normalized = ((value - inMin) / (inMax - inMin)).coerceIn(0.0, 1.0)
        return outMin + ((outMax - outMin) * normalized)
    }

    private data class AudioProcessingRequest(
        val masterEnabled: Boolean,
        val audioSessionId: Int?,
        val gainsDb: List<Double>,
        val compressor: CompressorPayload,
        val limiter: LimiterPayload,
        val fx: FxPayload,
    ) {
        val hasEqualizer: Boolean
            get() = masterEnabled && gainsDb.any { abs(it) >= DB_EPSILON }

        val hasDynamics: Boolean
            get() = compressor.enabled || limiter.enabled || fx.usesBalance

        val requiresAudioSession: Boolean
            get() = hasEqualizer || hasDynamics || fx.hasNativeCounterpart

        companion object {
            fun from(arguments: Any?): AudioProcessingRequest? {
                val payload = arguments as? Map<*, *> ?: return null
                val gainsDb = payload.doubleList("gainsDb") ?: return null
                if (gainsDb.size != 10) {
                    return null
                }

                return AudioProcessingRequest(
                    masterEnabled = payload.boolean("masterEnabled"),
                    audioSessionId = payload.intOrNull("audioSessionId"),
                    gainsDb = gainsDb,
                    compressor = CompressorPayload.from(payload.map("compressor")),
                    limiter = LimiterPayload.from(payload.map("limiter")),
                    fx = FxPayload.from(payload.map("fx")),
                )
            }
        }
    }

    private data class CompressorPayload(
        val enabled: Boolean,
        val thresholdDb: Double,
        val ratio: Double,
        val attackMs: Double,
        val releaseMs: Double,
        val makeupGainDb: Double,
    ) {
        companion object {
            fun from(payload: Map<*, *>?): CompressorPayload {
                return CompressorPayload(
                    enabled = payload.boolean("enabled"),
                    thresholdDb = payload.double("thresholdDb", -18.0),
                    ratio = payload.double("ratio", 3.0),
                    attackMs = payload.double("attackMs", 12.0),
                    releaseMs = payload.double("releaseMs", 140.0),
                    makeupGainDb = payload.double("makeupGainDb", 0.0),
                )
            }
        }
    }

    private data class LimiterPayload(
        val enabled: Boolean,
        val inputGainDb: Double,
        val ceilingDb: Double,
        val releaseMs: Double,
    ) {
        companion object {
            fun from(payload: Map<*, *>?): LimiterPayload {
                return LimiterPayload(
                    enabled = payload.boolean("enabled"),
                    inputGainDb = payload.double("inputGainDb", 0.0),
                    ceilingDb = payload.double("ceilingDb", -0.8),
                    releaseMs = payload.double("releaseMs", 80.0),
                )
            }
        }
    }

    private data class FxPayload(
        val enabled: Boolean,
        val balance: Double,
        val tempo: Double,
        val damp: Double,
        val filterHz: Double,
        val delayMs: Double,
        val size: Double,
        val mix: Double,
        val feedback: Double,
        val width: Double,
    ) {
        val usesBalance: Boolean
            get() = enabled && abs(balance) > DB_EPSILON

        val usesReverb: Boolean
            get() = enabled && mix > DB_EPSILON

        val usesVirtualizer: Boolean
            get() = enabled && width > 1.0 + DB_EPSILON

        val hasNativeCounterpart: Boolean
            get() = usesBalance || usesReverb || usesVirtualizer

        companion object {
            fun from(payload: Map<*, *>?): FxPayload {
                return FxPayload(
                    enabled = payload.boolean("enabled"),
                    balance = payload.double("balance", 0.0),
                    tempo = payload.double("tempo", 1.0),
                    damp = payload.double("damp", 0.35),
                    filterHz = payload.double("filterHz", 6800.0),
                    delayMs = payload.double("delayMs", 240.0),
                    size = payload.double("size", 0.55),
                    mix = payload.double("mix", 0.25),
                    feedback = payload.double("feedback", 0.35),
                    width = payload.double("width", 1.0),
                )
            }
        }
    }

    companion object {
        private const val TAG = "JustAudioProcessing"
        private const val METHOD_APPLY_AUDIO_PROCESSING = "applyAudioProcessing"
        private const val LIMITER_LINK_GROUP = 0
        private const val LIMITER_ATTACK_MS = 1f
        private const val LIMITER_RATIO = 20f
        private const val COMPRESSOR_KNEE_WIDTH_DB = 6f
        private const val COMPRESSOR_NOISE_GATE_DB = -90f
        private const val COMPRESSOR_EXPANDER_RATIO = 1f
        private const val FILTER_MIN_HZ = 200.0
        private const val FILTER_MAX_HZ = 18000.0
        private const val DB_EPSILON = 0.01
        private const val MIN_PAN_LINEAR_GAIN = 0.0001
        private const val MIN_CHANNEL_INPUT_GAIN_DB = -80.0
        private const val MAX_CHANNEL_INPUT_GAIN_DB = 12.0
    }
}

private fun Map<*, *>?.boolean(key: String, defaultValue: Boolean = false): Boolean {
    return (this?.get(key) as? Boolean) ?: defaultValue
}

private fun Map<*, *>?.intOrNull(key: String): Int? {
    return (this?.get(key) as? Number)?.toInt()
}

private fun Map<*, *>?.double(key: String, defaultValue: Double): Double {
    return (this?.get(key) as? Number)?.toDouble() ?: defaultValue
}

private fun Map<*, *>?.map(key: String): Map<*, *>? {
    return this?.get(key) as? Map<*, *>
}

private fun Map<*, *>.doubleList(key: String): List<Double>? {
    val values = this[key] as? List<*> ?: return null
    val result = ArrayList<Double>(values.size)
    for (value in values) {
        val number = value as? Number ?: return null
        result += number.toDouble()
    }
    return result
}
