package com.apurbalaskar.byteapp

import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.EnvironmentalReverb
import android.os.Build
import com.ryanheise.just_audio.ByteFxCore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Byte © 2026 Apurba Laskar. Audio Lab on the phone: the graph equalizer,
// loudness and limiter (Android's band processor), reverb (Android's room
// reverb), and Byte's own balance / mono / crossfeed stage in the player.
class ByteAudioLab(messenger: BinaryMessenger) {
    private class Fx(val dp: DynamicsProcessing?, val rv: EnvironmentalReverb?)
    private val sessions = HashMap<Int, Fx>()
    private var cfg: Map<String, Any?> = emptyMap()
    private val bands = 32

    init {
        MethodChannel(messenger, "byte/audiolab").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "caps" -> result.success(mapOf(
                        "bandProcessor" to (Build.VERSION.SDK_INT >= 28),
                        "reverb" to true,
                        "channelStage" to true,
                        "spatializer" to (Build.VERSION.SDK_INT >= 32),
                    ))
                    "attach" -> {
                        val s = call.argument<Number>("session")?.toInt() ?: 0
                        // 1.4.5: an effect the phone refused earlier (too many at once)
                        // is made again; Dart now releases each song's old session.
                        val had = sessions[s]
                        if (s > 0 && (had == null || (had.dp == null && Build.VERSION.SDK_INT >= 28) || had.rv == null)) {
                            had?.let { release(it) }
                            sessions[s] = make(s)
                        }
                        apply()
                        result.success(true)
                    }
                    "detach" -> {
                        val s = call.argument<Number>("session")?.toInt() ?: 0
                        sessions.remove(s)?.let { release(it) }
                        result.success(true)
                    }
                    "config" -> {
                        @Suppress("UNCHECKED_CAST")
                        cfg = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                        apply()
                        result.success(true)
                    }
                    "count" -> result.success(sessions.size)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("audiolab", e.message, null)
            }
        }
    }

    private fun make(session: Int): Fx {
        var dp: DynamicsProcessing? = null
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                val c = DynamicsProcessing.Config.Builder(
                    DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, 2,
                    true, bands, true, 1, false, 0, true,
                ).build()
                dp = DynamicsProcessing(0, session, c)
            } catch (_: Exception) { dp = null }
        }
        var rv: EnvironmentalReverb? = null
        try { rv = EnvironmentalReverb(0, session) } catch (_: Exception) { rv = null }
        return Fx(dp, rv)
    }

    private fun release(f: Fx) {
        try { f.dp?.release() } catch (_: Exception) {}
        try { f.rv?.release() } catch (_: Exception) {}
    }

    private fun d(k: String, def: Double = 0.0): Double = (cfg[k] as? Number)?.toDouble() ?: def
    private fun b(k: String): Boolean = cfg[k] as? Boolean ?: false

    private fun apply() {
        ByteFxCore.floatOutput = b("float32")
        // Byte's own channel stage (all players read it).
        ByteFxCore.current = ByteFxCore.Params(
            b("mono"), d("balance").toFloat(), b("crossfeed"), d("xfDb", -6.0).toFloat(), d("xfHz", 700.0).toFloat(), d("xfAmount", 1.0).toFloat(), 0.3f,
        )
        @Suppress("UNCHECKED_CAST")
        val cut = (cfg["cutoffs"] as? List<Number>)?.map { it.toFloat() } ?: emptyList()
        @Suppress("UNCHECKED_CAST")
        val gains = (cfg["gains"] as? List<Number>)?.map { it.toFloat() } ?: emptyList()
        @Suppress("UNCHECKED_CAST")
        val rvc = (cfg["reverb"] as? Map<String, Number>) ?: emptyMap()
        val dpOn = b("eqOn") || b("mbcOn") || b("limiterOn")
        for ((_, f) in sessions) {
            val dp = f.dp
            if (dp != null && Build.VERSION.SDK_INT >= 28) {
                try {
                    for (i in 0 until minOf(bands, cut.size, gains.size)) {
                        dp.setPreEqBandAllChannelsTo(i, DynamicsProcessing.EqBand(true, cut[i], gains[i]))
                    }
                    dp.setInputGainAllChannelsTo(d("inputGain").toFloat())
                    val mbc = DynamicsProcessing.MbcBand(b("mbcOn"), 20000f, 10f, 200f, d("ratio", 1.0).toFloat(), d("threshold", 0.0).toFloat(), 6f, -90f, 1f, 0f, 0f)
                    dp.setMbcBandAllChannelsTo(0, mbc)
                    dp.setLimiterAllChannelsTo(DynamicsProcessing.Limiter(true, b("limiterOn"), 0, 1f, 60f, 10f, -1f, 0f))
                    dp.enabled = dpOn
                } catch (_: Exception) {}
            }
            val rv = f.rv
            if (rv != null) {
                try {
                    if (b("rvOn")) {
                        rvc["roomLevel"]?.let { rv.roomLevel = it.toShort() }
                        rvc["decayTime"]?.let { rv.decayTime = it.toInt() }
                        rvc["decayHFRatio"]?.let { rv.decayHFRatio = it.toShort() }
                        rvc["reflectionsLevel"]?.let { rv.reflectionsLevel = it.toShort() }
                        rvc["reflectionsDelay"]?.let { rv.reflectionsDelay = it.toInt() }
                        rvc["reverbLevel"]?.let { rv.reverbLevel = it.toShort() }
                        rvc["reverbDelay"]?.let { rv.reverbDelay = it.toInt() }
                        rvc["diffusion"]?.let { rv.diffusion = it.toShort() }
                        rvc["density"]?.let { rv.density = it.toShort() }
                    }
                    rv.enabled = b("rvOn")
                } catch (_: Exception) {}
            }
        }
    }
}
