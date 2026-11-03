package com.apurbalaskar.byteapp

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Byte © 2026 Apurba Laskar. What the phone's audio output is doing right now:
// device name, where the sound goes, the mixer's rate, volume, Atmos and
// spatial-audio support. Also the Wi-Fi multicast lock that Cast discovery needs.
class ByteAudioRoute(private val ctx: Context, messenger: BinaryMessenger) {
    private val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var lock: WifiManager.MulticastLock? = null
    // Audio-service calls are cross-process and slow on some phones; doing
    // them on the UI thread made the volume slider lag. One worker thread,
    // newest volume wins.
    private val bg = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    @Volatile private var wantedIndex = -1

    // The phone's volume buttons (and any other app) changing media volume:
    // tell the slider at once instead of waiting for the next poll.
    private var volumeSink: EventChannel.EventSink? = null
    private var volumeReceiver: android.content.BroadcastReceiver? = null

    private fun startVolumeEvents() {
        if (volumeReceiver != null) return
        val r = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                val type = i?.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1) ?: -1
                if (type != -1 && type != AudioManager.STREAM_MUSIC) return
                val idx = i?.getIntExtra("android.media.EXTRA_VOLUME_STREAM_VALUE", -1) ?: -1
                val index = if (idx >= 0) idx else am.getStreamVolume(AudioManager.STREAM_MUSIC)
                volumeSink?.success(mapOf("index" to index, "max" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)))
            }
        }
        val f = android.content.IntentFilter("android.media.VOLUME_CHANGED_ACTION")
        if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED) else ctx.registerReceiver(r, f)
        volumeReceiver = r
    }

    private fun stopVolumeEvents() {
        volumeReceiver?.let { try { ctx.unregisterReceiver(it) } catch (_: Exception) {} }
        volumeReceiver = null
    }

    init {
        EventChannel(messenger, "byte/audio/volume").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                volumeSink = sink
                startVolumeEvents()
                sink?.success(mapOf("index" to am.getStreamVolume(AudioManager.STREAM_MUSIC), "max" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)))
            }
            override fun onCancel(args: Any?) {
                volumeSink = null
                stopVolumeEvents()
            }
        })
        MethodChannel(messenger, "byte/audio").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> bg.execute {
                        try {
                            val i = info()
                            main.post { result.success(i) }
                        } catch (e: Exception) {
                            main.post { result.error("audio", e.message, null) }
                        }
                    }
                    "setVolume" -> {
                        val f = (call.argument<Number>("v")?.toDouble() ?: 0.5).coerceIn(0.0, 1.0)
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val index = call.argument<Number>("index")?.toInt()?.coerceIn(0, max) ?: Math.round(f * max).toInt()
                        wantedIndex = index
                        bg.execute {
                            // A newer value already queued: skip this one.
                            if (wantedIndex == index) {
                                try {
                                    if (am.getStreamVolume(AudioManager.STREAM_MUSIC) != index) am.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
                                } catch (_: SecurityException) {
                                    // Do Not Disturb can refuse volume changes.
                                }
                            }
                        }
                        result.success(null)
                    }
                    "multicast" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        if (on && lock == null) {
                            val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            lock = wm.createMulticastLock("byte-cast").apply { setReferenceCounted(false); acquire() }
                        } else if (!on) {
                            lock?.release(); lock = null
                        }
                        result.success(null)
                    }
                    "usbMixer" -> result.success(usbMixer(call.argument<String>("mode") ?: "off"))
                    "soundSettings" -> {
                        val i = Intent(Settings.ACTION_SOUND_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        ctx.startActivity(i)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("audio", e.message, null)
            }
        }
    }

    /// Android 14+: ask for the USB DAC's own mixer format. "best" = its highest
    /// sample rate; "bitperfect" = no mixing at all (volume and effects off).
    /// Returns what the phone accepted: "off", "best", "bitperfect" or "unsupported".
    private fun usbMixer(mode: String): String {
        if (Build.VERSION.SDK_INT < 34) return "unsupported"
        val dac = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET } ?: return "unsupported"
        val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
        if (mode == "off") {
            am.clearPreferredMixerAttributes(attrs, dac)
            return "off"
        }
        val all = am.getSupportedMixerAttributes(dac)
        val wanted = if (mode == "bitperfect") android.media.AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT
            else android.media.AudioMixerAttributes.MIXER_BEHAVIOR_DEFAULT
        val pick = all.filter { it.mixerBehavior == wanted }.maxByOrNull { it.format.sampleRate } ?: return "unsupported"
        return if (am.setPreferredMixerAttributes(attrs, dac, pick)) mode else "unsupported"
    }

    private fun info(): Map<String, Any?> {
        val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        // The device Android plays media to: the newest external one wins over the speaker.
        val order = listOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_HDMI)
        var route: AudioDeviceInfo? = null
        for (t in order) { route = outs.firstOrNull { it.type == t }; if (route != null) break }
        val type = when (route?.type) {
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired"
            AudioDeviceInfo.TYPE_HDMI -> "hdmi"
            else -> "speaker"
        }
        val name = try { Settings.Global.getString(ctx.contentResolver, "device_name") } catch (e: Exception) { null }
        var atmos = false
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
                for (enc in listOf(AudioFormat.ENCODING_E_AC3_JOC, AudioFormat.ENCODING_AC4)) {
                    val f = AudioFormat.Builder().setEncoding(enc).setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_5POINT1).build()
                    if (AudioTrack.isDirectPlaybackSupported(f, attrs)) atmos = true
                }
            } catch (e: Exception) {}
        }
        var spatialAvailable = false
        var spatialEnabled = false
        if (Build.VERSION.SDK_INT >= 32) {
            try {
                val sp = am.spatializer
                spatialAvailable = sp.immersiveAudioLevel != android.media.Spatializer.SPATIALIZER_IMMERSIVE_LEVEL_NONE && sp.isAvailable
                spatialEnabled = sp.isEnabled
            } catch (e: Exception) {}
        }
        return mapOf(
            "deviceName" to (name ?: Build.MODEL),
            "model" to Build.MODEL,
            "outputType" to type,
            "outputName" to (route?.productName?.toString()),
            "sampleRate" to am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull(),
            "framesPerBuffer" to am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull(),
            "volume" to am.getStreamVolume(AudioManager.STREAM_MUSIC),
            "maxVolume" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "atmos" to atmos,
            "spatialAvailable" to spatialAvailable,
            "spatialEnabled" to spatialEnabled,
            "sdk" to Build.VERSION.SDK_INT,
        )
    }
}
