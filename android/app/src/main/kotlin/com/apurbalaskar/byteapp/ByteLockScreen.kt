package com.apurbalaskar.byteapp

import android.annotation.TargetApi
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Byte © 2026 Apurba Laskar. Byte's own lock-screen player (Android).
//
// While music plays the Dart side "arms" this: a runtime receiver listens for
// the screen turning on, and if the phone is locked it opens
// LockScreenActivity over the keyguard. Android 10+ blocks activity starts from
// the background, so there the activity is opened through a full-screen-intent
// notification (the sanctioned way; Android 14+ needs the user's OK for it).
// Disarmed (paused for a while, stopped, or the setting off) = no receiver,
// nothing opens.
object ByteLockScreen {
    private const val TAG = "ByteLock"
    const val ENGINE_ID = "byte_lock_engine"
    const val EXTRA_PREVIEW = "byte_lock_preview"
    private const val CHANNEL_ID = "byte_lock_player"
    private const val NOTIFICATION_ID = 0x10C7
    private const val AUDIO_SERVICE_CLASS = "com.ryanheise.audioservice.AudioService"

    private var armed = false
    @Volatile var activityVisible = false
    /** The LockScreenActivity whose method channel handler is current. */
    var owner: Any? = null
    private val main = Handler(Looper.getMainLooper())

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val ctx = c.applicationContext
            when (i.action) {
                // Get the lock-screen engine ready while the screen is dark so it opens instantly.
                Intent.ACTION_SCREEN_OFF -> try { engine(ctx) } catch (e: Exception) { Log.w(TAG, "warm-up failed", e) }
                Intent.ACTION_SCREEN_ON -> if (isLocked(ctx)) show(ctx)
            }
        }
    }

    fun audioServiceClass(): String = AUDIO_SERVICE_CLASS

    fun attach(context: Context, messenger: BinaryMessenger) {
        val ctx = context.applicationContext
        MethodChannel(messenger, "byte/lockscreen").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "arm" -> { arm(ctx); result.success(true) }
                    "disarm" -> { disarm(ctx); result.success(true) }
                    "status" -> result.success(status(ctx))
                    "preview" -> result.success(preview(ctx))
                    "openFullScreenSettings" -> result.success(openFullScreenSettings(ctx))
                    "openOverlaySettings" -> result.success(openOverlaySettings(ctx))
                    "openNotificationSettings" -> result.success(openNotificationSettings(ctx))
                    "openOemSettings" -> result.success(openOemSettings(ctx))
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("lockscreen", e.message, null)
            }
        }
    }

    // ── Arm / disarm ────────────────────────────────────────────────────────
    private fun arm(ctx: Context) {
        if (armed) return
        val f = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            ctx.registerReceiver(screenReceiver, f, Context.RECEIVER_EXPORTED)
        } else {
            ctx.registerReceiver(screenReceiver, f)
        }
        armed = true
    }

    private fun disarm(ctx: Context) {
        if (armed) {
            try { ctx.unregisterReceiver(screenReceiver) } catch (_: IllegalArgumentException) {}
            armed = false
        }
        cancelNotification(ctx)
        if (!activityVisible) releaseEngine()
    }

    // ── The lock-screen engine (separate, small, no plugins) ────────────────
    fun engine(ctx: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = ctx.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) loader.startInitialization(app)
        loader.ensureInitializationComplete(app, null)
        val e = FlutterEngine(app, null, false)
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "lockScreenMain"))
        FlutterEngineCache.getInstance().put(ENGINE_ID, e)
        return e
    }

    private fun releaseEngine() {
        val c = FlutterEngineCache.getInstance()
        val e = c.get(ENGINE_ID) ?: return
        c.remove(ENGINE_ID)
        try { e.destroy() } catch (_: Exception) {}
    }

    // ── Showing it ──────────────────────────────────────────────────────────
    fun isLocked(ctx: Context): Boolean =
        (ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked

    private fun intent(ctx: Context, preview: Boolean = false): Intent =
        Intent(ctx, LockScreenActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)
            .putExtra(EXTRA_PREVIEW, preview)

    private fun show(ctx: Context) {
        if (activityVisible) return
        val i = intent(ctx)
        val direct = Build.VERSION.SDK_INT < 29 || Settings.canDrawOverlays(ctx)
        if (direct) {
            try { ctx.startActivity(i) } catch (e: Exception) { Log.w(TAG, "direct start failed", e) }
        }
        if (Build.VERSION.SDK_INT >= 29) {
            // Phones that still block the direct start (or no overlay permission): full-screen intent.
            // A short wait first: if our window was already on top it comes back by itself.
            main.postDelayed({ if (!activityVisible && isLocked(ctx)) postFullScreen(ctx, i) }, if (direct) 700L else 250L)
        }
    }

    @TargetApi(29)
    private fun postFullScreen(ctx: Context, i: Intent) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!canFullScreen(ctx)) {
            Log.i(TAG, "full-screen intent not allowed on this phone")
            return
        }
        ensureChannel(ctx, nm)
        val pi = PendingIntent.getActivity(ctx, 0x10C, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(smallIcon(ctx))
            .setContentTitle("Byte")
            .setContentText("Now playing")
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setFullScreenIntent(pi, true)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setLocalOnly(true)
            .setTimeoutAfter(5000)
            .build()
        try { nm.notify(NOTIFICATION_ID, n) } catch (e: Exception) { Log.w(TAG, "notify failed", e) }
    }

    @TargetApi(26)
    private fun ensureChannel(ctx: Context, nm: NotificationManager) {
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(CHANNEL_ID, "Lock screen player", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Opens Byte's player when you turn the screen on while music plays"
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(ch)
    }

    fun cancelNotification(ctx: Context) {
        try {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID)
        } catch (_: Exception) {}
    }

    private fun smallIcon(ctx: Context): Int {
        val id = ctx.resources.getIdentifier("ic_stat_byte", "drawable", ctx.packageName)
        return if (id != 0) id else ctx.applicationInfo.icon
    }

    private fun canFullScreen(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        return (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).canUseFullScreenIntent()
    }

    private fun preview(ctx: Context): Boolean = try {
        ctx.startActivity(intent(ctx, preview = true))
        true
    } catch (e: Exception) {
        Log.w(TAG, "preview failed", e)
        false
    }

    // ── Settings page ───────────────────────────────────────────────────────
    private fun status(ctx: Context): Map<String, Any> {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "manufacturer" to (Build.MANUFACTURER ?: ""),
            "brand" to (Build.BRAND ?: ""),
            "miui" to isMiui(),
            "canFullScreenIntent" to canFullScreen(ctx),
            "canDrawOverlays" to Settings.canDrawOverlays(ctx),
            "notificationsEnabled" to nm.areNotificationsEnabled(),
            "armed" to armed,
        )
    }

    private fun sysProp(key: String): String = try {
        val c = Class.forName("android.os.SystemProperties")
        (c.getMethod("get", String::class.java).invoke(null, key) as? String) ?: ""
    } catch (_: Exception) {
        ""
    }

    /** MIUI and its successor HyperOS (Xiaomi, Redmi, POCO). */
    private fun isMiui(): Boolean =
        sysProp("ro.miui.ui.version.name").isNotEmpty() || sysProp("ro.mi.os.version.name").isNotEmpty()

    private fun appDetails(ctx: Context): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))

    private fun startFirst(ctx: Context, intents: List<Intent>): Boolean {
        for (i in intents) {
            try {
                ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
                // not on this phone: try the next one
            }
        }
        return false
    }

    private fun openFullScreenSettings(ctx: Context): Boolean {
        val list = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= 34) {
            list.add(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:" + ctx.packageName)))
        }
        list.add(appDetails(ctx))
        return startFirst(ctx, list)
    }

    private fun openOverlaySettings(ctx: Context): Boolean = startFirst(
        ctx,
        listOf(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + ctx.packageName)), appDetails(ctx)),
    )

    private fun openNotificationSettings(ctx: Context): Boolean {
        val list = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= 26) {
            list.add(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName))
        }
        list.add(appDetails(ctx))
        return startFirst(ctx, list)
    }

    /** The phone maker's own permission page (lock screen, pop-ups, background). */
    private fun openOemSettings(ctx: Context): Boolean {
        val pkg = ctx.packageName
        val m = ((Build.MANUFACTURER ?: "") + " " + (Build.BRAND ?: "")).lowercase()
        val list = mutableListOf<Intent>()
        if (isMiui() || m.contains("xiaomi") || m.contains("redmi") || m.contains("poco")) {
            list.add(
                Intent("miui.intent.action.APP_PERM_EDITOR")
                    .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
                    .putExtra("extra_pkgname", pkg),
            )
            list.add(
                Intent("miui.intent.action.APP_PERM_EDITOR")
                    .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.AppPermissionsEditorActivity")
                    .putExtra("extra_pkgname", pkg),
            )
            list.add(Intent("miui.intent.action.APP_PERM_EDITOR").putExtra("extra_pkgname", pkg))
        } else if (m.contains("vivo") || m.contains("iqoo")) {
            list.add(
                Intent().setClassName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.SoftPermissionDetailActivity")
                    .putExtra("packagename", pkg),
            )
        }
        list.add(appDetails(ctx))
        return startFirst(ctx, list)
    }
}
