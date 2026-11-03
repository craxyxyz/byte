package com.apurbalaskar.byteapp

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.browse.MediaBrowser
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

// Byte © 2026 Apurba Laskar. The lock-screen player window: shown over the
// keyguard, drawn by a small Flutter engine (entrypoint lockScreenMain), and
// driving the real player through Android's media session (the same
// ByteAudioHandler the app uses, via audio_service).
class LockScreenActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var browser: MediaBrowser? = null
    private var controller: MediaController? = null
    private var preview = false
    private var receiverOn = false
    private var lastArtKey: String? = null
    private var lastArt: ByteArray? = null
    private val main = Handler(Looper.getMainLooper())
    private val audio by lazy { getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private val keyguard by lazy { getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager }

    // Unlocked (any way: fingerprint, face, PIN) → get out of the way.
    private val presentReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            if (!preview) finish()
        }
    }

    private val volumeObserver = object : ContentObserver(main) {
        override fun onChange(selfChange: Boolean) = pushVolume()
    }

    private val controllerCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = pushState()
        override fun onPlaybackStateChanged(state: PlaybackState?) = pushState()
        override fun onSessionDestroyed() {
            controller = null
            if (!preview) finish() else pushState()
        }
    }

    private val resync = object : Runnable {
        override fun run() {
            pushState()
            main.postDelayed(this, 5000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        preview = intent?.getBooleanExtra(ByteLockScreen.EXTRA_PREVIEW, false) == true
        ByteLockScreen.engine(applicationContext) // FlutterActivity looks it up in the cache
        showOverKeyguard()
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
        ByteLockScreen.cancelNotification(this)
        val f = IntentFilter(Intent.ACTION_USER_PRESENT)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(presentReceiver, f, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(presentReceiver, f)
        }
        receiverOn = true
    }

    private fun showOverKeyguard() {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            // Opened because the user turned the screen on: never wake it ourselves.
            setTurnScreenOn(false)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        preview = intent.getBooleanExtra(ByteLockScreen.EXTRA_PREVIEW, false)
        ByteLockScreen.cancelNotification(this)
        pushState()
    }

    override fun getCachedEngineId(): String = ByteLockScreen.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // No super: the lock-screen engine runs without plugins.
        ByteLockScreen.owner = this
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/lockplayer").also {
            it.setMethodCallHandler { call, result -> onCall(call, result) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (ByteLockScreen.owner === this) {
            channel?.setMethodCallHandler(null)
            ByteLockScreen.owner = null
        }
        channel = null
    }

    override fun onStart() {
        super.onStart()
        ByteLockScreen.activityVisible = true
        connect()
        contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, volumeObserver)
        main.post(resync)
        channel?.invokeMethod("shown", null)
    }

    override fun onResume() {
        super.onResume()
        // Already unlocked (e.g. face unlock before we came up): nothing to show.
        if (!preview && !keyguard.isKeyguardLocked) finish()
    }

    override fun onStop() {
        main.removeCallbacks(resync)
        try { contentResolver.unregisterContentObserver(volumeObserver) } catch (_: Exception) {}
        disconnect()
        ByteLockScreen.activityVisible = false
        super.onStop()
    }

    override fun onDestroy() {
        if (receiverOn) {
            try { unregisterReceiver(presentReceiver) } catch (_: Exception) {}
            receiverOn = false
        }
        super.onDestroy()
    }

    // ── Media session ───────────────────────────────────────────────────────
    private fun connect() {
        if (browser != null) return
        val b = MediaBrowser(
            this,
            ComponentName(this, ByteLockScreen.audioServiceClass()),
            object : MediaBrowser.ConnectionCallback() {
                override fun onConnected() {
                    val bb = browser ?: return
                    try {
                        val c = MediaController(this@LockScreenActivity, bb.sessionToken)
                        c.registerCallback(controllerCallback, main)
                        controller = c
                    } catch (_: Exception) {}
                    pushState()
                }

                override fun onConnectionSuspended() {
                    controller?.unregisterCallback(controllerCallback)
                    controller = null
                    pushState()
                }

                override fun onConnectionFailed() = pushState()
            },
            null,
        )
        browser = b
        try { b.connect() } catch (_: IllegalStateException) {}
    }

    private fun disconnect() {
        controller?.unregisterCallback(controllerCallback)
        controller = null
        try { browser?.disconnect() } catch (_: Exception) {}
        browser = null
    }

    private fun volume(): Double? {
        if (audio.isVolumeFixed) return null
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return null
        return audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
    }

    private fun pushVolume() {
        channel?.invokeMethod("volume", volume())
    }

    private fun artBytes(m: MediaMetadata, key: String): ByteArray? {
        if (key == lastArtKey) return lastArt
        val bmp: Bitmap = m.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: m.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            ?: m.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: return null
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 92, out)
        lastArtKey = key
        lastArt = out.toByteArray()
        return lastArt
    }

    private fun pushState() {
        val ch = channel ?: return
        val map = HashMap<String, Any?>()
        val c = controller
        val m = c?.metadata
        if (m != null) {
            val title = m.getString(MediaMetadata.METADATA_KEY_TITLE) ?: m.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
            map["title"] = title ?: ""
            map["artist"] = m.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: m.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)
            map["durationMs"] = m.getLong(MediaMetadata.METADATA_KEY_DURATION)
            val art = m.getString(MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI)
                ?: m.getString(MediaMetadata.METADATA_KEY_ART_URI)
                ?: m.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI)
            if (art != null && (art.startsWith("http") || art.startsWith("file:") || art.startsWith("/"))) {
                map["artUri"] = art
            } else {
                map["artBytes"] = artBytes(m, (m.getString(MediaMetadata.METADATA_KEY_MEDIA_ID) ?: "") + (art ?: ""))
            }
        }
        val s = c?.playbackState
        if (s != null) {
            val playing = s.state == PlaybackState.STATE_PLAYING
            var pos = s.position
            if (playing && s.lastPositionUpdateTime > 0) {
                pos += ((SystemClock.elapsedRealtime() - s.lastPositionUpdateTime) * s.playbackSpeed).toLong()
            }
            map["playing"] = playing || s.state == PlaybackState.STATE_BUFFERING || s.state == PlaybackState.STATE_CONNECTING
            map["positionMs"] = if (pos < 0) 0L else pos
            // Buffering: the shown position holds still.
            map["speed"] = if (playing) s.playbackSpeed.toDouble() else 0.0
        }
        map["volume"] = volume()
        ch.invokeMethod("state", map)
    }

    // ── From the Dart UI ────────────────────────────────────────────────────
    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        val t = controller?.transportControls
        when (call.method) {
            "ready" -> pushState()
            "play" -> t?.play()
            "pause" -> t?.pause()
            "next" -> t?.skipToNext()
            "previous" -> t?.skipToPrevious()
            "seek" -> t?.seekTo((call.argument<Number>("ms") ?: 0).toLong())
            "setVolume" -> {
                val v = (call.argument<Number>("v") ?: 0).toDouble().coerceIn(0.0, 1.0)
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                try {
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, (v * max).roundToInt(), 0)
                } catch (_: SecurityException) {
                    // Do Not Disturb can refuse volume changes.
                }
            }
            "unlock" -> unlock()
            "hide" -> finish()
            else -> {
                result.notImplemented()
                return
            }
        }
        result.success(null)
    }

    private fun unlock() {
        if (preview || !keyguard.isKeyguardLocked) {
            finish()
            return
        }
        if (Build.VERSION.SDK_INT >= 26) {
            keyguard.requestDismissKeyguard(
                this,
                object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() = finish()
                },
            )
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD)
        }
    }
}
