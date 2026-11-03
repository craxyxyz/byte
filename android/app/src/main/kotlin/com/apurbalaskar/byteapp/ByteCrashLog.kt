package com.apurbalaskar.byteapp

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import android.annotation.TargetApi
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// Byte © 2026 Apurba Laskar. 1.4.5: "Byte closes by itself" — the Android side
// of Settings → About → Report a problem. Writes into the same small file the
// Dart side uses (lib/core/crash_log.dart, app support folder = filesDir):
//  • an Android (Java/Kotlin) crash that would close Byte, with its stack, and
//  • on the next start, why Android closed Byte last time (Android 11+:
//    crash, ANR, low memory, killed while in the background…).
object ByteCrashLog {
    private const val MAX = 64 * 1024
    private const val FILE = "crash_log.txt"
    private const val OLD = "crash_log.1.txt"
    @Volatile private var installed = false

    private fun stamp(ms: Long): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date(ms))

    @Synchronized
    fun append(ctx: Context, text: String) {
        try {
            val f = File(ctx.filesDir, FILE)
            if (f.exists() && f.length() + text.length > MAX) {
                val old = File(ctx.filesDir, OLD)
                if (old.exists()) old.delete()
                f.renameTo(old)
            }
            f.appendText(text)
        } catch (_: Throwable) {}
    }

    fun install(context: Context) {
        if (installed) return
        installed = true
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                val stack = Log.getStackTraceString(e).lines().take(40).joinToString("\n")
                append(app, "\n[${stamp(System.currentTimeMillis())}] Android crash (thread ${t.name}) · ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}\n$stack\n")
            } catch (_: Throwable) {}
            previous?.uncaughtException(t, e)
        }
        if (Build.VERSION.SDK_INT >= 30) try { recordExitReasons(app) } catch (_: Throwable) {}
    }

    @TargetApi(30)
    private fun reasonName(r: Int): String = when (r) {
        ApplicationExitInfo.REASON_ANR -> "not responding (ANR)"
        ApplicationExitInfo.REASON_CRASH -> "crash (Java/Kotlin)"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash (native)"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "closed by Android: low memory"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "closed by Android: too much battery/CPU"
        ApplicationExitInfo.REASON_SIGNALED -> "closed by Android (signal)"
        ApplicationExitInfo.REASON_EXIT_SELF -> "Byte exited"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "failed to start"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "a permission was changed"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "force-stopped / closed from settings"
        ApplicationExitInfo.REASON_USER_STOPPED -> "stopped by the user"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "a system part it used died"
        ApplicationExitInfo.REASON_OTHER -> "closed by Android (other)"
        else -> "reason $r"
    }

    private fun importanceName(i: Int): String = when {
        i <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "on screen"
        i <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE -> "playing in the background"
        i <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "visible"
        i <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "background service"
        else -> "in the background, not playing"
    }

    /** Why Android closed Byte since the last look (Android 11+). */
    @TargetApi(30)
    private fun recordExitReasons(ctx: Context) {
        if (Build.VERSION.SDK_INT < 30) return
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val prefs = ctx.getSharedPreferences("byte_crash_log", Context.MODE_PRIVATE)
        val seen = prefs.getLong("seen", 0L)
        val list = am.getHistoricalProcessExitReasons(ctx.packageName, 0, 8)
        var newest = seen
        for (info in list.sortedBy { it.timestamp }) {
            if (info.timestamp <= seen) continue
            newest = maxOf(newest, info.timestamp)
            if (seen == 0L) continue // first run with this version: only note what comes next
            val desc = info.description?.let { " — $it" } ?: ""
            append(ctx, "\n[${stamp(info.timestamp)}] Android closed Byte: ${reasonName(info.reason)} while ${importanceName(info.importance)}$desc · memory ${info.pss / 1024} MB\n")
        }
        prefs.edit().putLong("seen", if (newest == 0L) System.currentTimeMillis() else newest).apply()
    }
}
