package com.apurbalaskar.byteapp

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.view.WindowManager
import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Byte © 2026 Apurba Laskar. AudioServiceActivity keeps playback alive in the
// background and wires the lock-screen / notification controls.
class MainActivity : AudioServiceActivity() {
    private var links: MethodChannel? = null
    private val automixWorker = java.util.concurrent.Executors.newSingleThreadExecutor()
    private var initialLink: String? = null
    private var pendingIcon: String? = null

    private fun applyIcon(want: String) {
        val pm = packageManager
        // Enable the new one first so there is always a launcher entry.
        pm.setComponentEnabledSetting(
            ComponentName(this, "$ALIAS_PREFIX$want"),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        for (name in icons) {
            if (name == want) continue
            pm.setComponentEnabledSetting(
                ComponentName(this, "$ALIAS_PREFIX$name"),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    override fun onStop() {
        super.onStop()
        // 1.4.2: music-app log-ins (web view cookies) are written to disk when
        // Byte leaves the screen, so a swipe-away or reboot doesn't log out.
        try {
            CookieManager.getInstance().flush()
        } catch (e: Exception) {}
        val want = pendingIcon ?: getSharedPreferences("byte_icon", MODE_PRIVATE).getString("pending", null)
        if (want != null && want in icons) {
            try {
                applyIcon(want)
            } catch (e: Exception) {}
            pendingIcon = null
            getSharedPreferences("byte_icon", MODE_PRIVATE).edit().remove("pending").apply()
        }
    }

    // Launcher aliases live under the code package (namespace), not the
    // installed application id, so name them in full.
    private val ALIAS_PREFIX = "com.apurbalaskar.byteapp.Logo"
    private val icons = listOf("Default", "Monochrome", "LiquidGlass", "LiquidGlassDark", "LiquidGlassClear", "LiquidGlassClearDark", "NeonSilver", "NeonCyan", "NeonViolet", "SamsungGlass", "SamsungGlassDark", "SamsungNeonCyan", "PixelGlass", "PixelGlassDark", "PixelNeonCyan")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        ByteMediaChannel.ensure(this) // lock-screen media panel: public, before the service makes it
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        initialLink = intent?.dataString
        ByteAudioRoute(this, messenger)
        ByteAudioLab(messenger) // Settings → Audio Lab
        ByteLockScreen.attach(this, messenger) // lock-screen player (Settings → Playback)

        // A script the music service's sign-in page runs before its own (it only
        // listens for the sign-in the page gives its web player).
        MethodChannel(messenger, "byte/webview").setMethodCallHandler { call, result ->
            when (call.method) {
                "docStart" -> {
                    try {
                        val id = (call.argument<Number>("id"))?.toLong() ?: -1L
                        val script = call.argument<String>("script") ?: ""
                        val origins = call.argument<List<String>>("origins") ?: listOf("*")
                        @Suppress("DEPRECATION")
                        val wv = io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, id)
                        if (wv != null && androidx.webkit.WebViewFeature.isFeatureSupported(androidx.webkit.WebViewFeature.DOCUMENT_START_SCRIPT)) {
                            androidx.webkit.WebViewCompat.addDocumentStartJavaScript(wv, script, origins.toSet())
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "clearCookies" -> {
                    val host = call.argument<String>("host") ?: ""
                    val cm = CookieManager.getInstance()
                    val list = cm.getCookie("https://$host")?.split(";") ?: emptyList()
                    for (c in list) {
                        val name = c.substringBefore("=").trim()
                        if (name.isNotEmpty()) {
                            cm.setCookie("https://$host", "$name=; Max-Age=0; Path=/; Domain=.$host")
                            cm.setCookie("https://$host", "$name=; Max-Age=0; Path=/")
                        }
                    }
                    cm.flush()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // The sign-in page's cookies (YouTube Music session), read on the phone.
        MethodChannel(messenger, "byte/cookies").setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> {
                    val url = call.argument<String>("url") ?: "https://music.youtube.com"
                    CookieManager.getInstance().flush()
                    result.success(CookieManager.getInstance().getCookie(url))
                }
                else -> result.notImplemented()
            }
        }

        // App icon chooser: ONE handler (a second registration on the same
        // channel silently replaces the first). Switching the launcher entry
        // while Byte is on screen makes Android close Byte's window (it looks
        // like a crash), so "set" only records the choice and onStop() applies
        // it the moment Byte goes to the background.
        MethodChannel(messenger, "byte/icons").setMethodCallHandler { call, result ->
            when (call.method) {
                "set" -> {
                    val want = (call.arguments as? String ?: "Default")
                    if (want !in icons) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    pendingIcon = want
                    getSharedPreferences("byte_icon", MODE_PRIVATE).edit().putString("pending", want).apply()
                    result.success(true)
                }
                "get" -> {
                    val p = pendingIcon ?: getSharedPreferences("byte_icon", MODE_PRIVATE).getString("pending", null)
                    if (p != null) {
                        result.success(p)
                        return@setMethodCallHandler
                    }
                    try {
                        val pm = packageManager
                        var current = "Default"
                        for (name in icons) {
                            val s = pm.getComponentEnabledSetting(ComponentName(this, "$ALIAS_PREFIX$name"))
                            val on = if (name == "Default") s != PackageManager.COMPONENT_ENABLED_STATE_DISABLED else s == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                            if (on && name != "Default") current = name
                        }
                        result.success(current)
                    } catch (e: Exception) {
                        result.success("Default")
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Phone details + per-brand setup pages (Settings → Phone setup) and the
        // low-RAM hint the liquid glass uses to go lighter.
        ByteDevice(this, messenger)

        // Home-screen widget: what's playing (title, artist, play state, cover file).
        MethodChannel(messenger, "byte/widget").setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    try {
                        ByteWidget.push(
                            this,
                            call.argument<String>("title"),
                            call.argument<String>("artist"),
                            call.argument<Boolean>("playing") ?: false,
                            call.argument<String>("art"),
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // High performance mode: ask for the screen's fastest refresh rate.
        MethodChannel(messenger, "byte/display").setMethodCallHandler { call, result ->
            when (call.method) {
                "setHighRefresh" -> {
                    val high = call.arguments as? Boolean ?: false
                    try {
                        val attrs = window.attributes
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val d = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else @Suppress("DEPRECATION") windowManager.defaultDisplay
                            val modes = d?.supportedModes ?: emptyArray()
                            val cur = d?.mode
                            val best = modes
                                .filter { cur == null || (it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight) }
                                .maxByOrNull { it.refreshRate }
                            attrs.preferredDisplayModeId = if (high && best != null) best.modeId else 0
                        }
                        window.attributes = attrs
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                // 1.4.2: lyrics screen open → the screen doesn't turn off (no permission needed).
                "keepScreenOn" -> {
                    val on = call.arguments as? Boolean ?: false
                    try {
                        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Automix: decode a song to PCM for analysis, off the main thread.
        MethodChannel(messenger, "byte/automix").setMethodCallHandler { call, result ->
            when (call.method) {
                "decode" -> {
                    val path = call.argument<String>("path")
                    val rate = call.argument<Int>("rate") ?: 11025
                    val maxSeconds = call.argument<Int>("maxSeconds") ?: 1200
                    if (path == null) {
                        result.error("args", "no path", null)
                        return@setMethodCallHandler
                    }
                    automixWorker.execute {
                        try {
                            val pcm = AutomixDecoder.decode(path, rate, maxSeconds)
                            runOnUiThread { result.success(pcm) }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("decode", e.message ?: e.javaClass.simpleName, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // byte://listen/CODE links (party invites).
        links = MethodChannel(messenger, "byte/links").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "initial" -> {
                        result.success(initialLink)
                        initialLink = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }


    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = intent.dataString
        if (link != null) links?.invokeMethod("link", link)
    }
}
