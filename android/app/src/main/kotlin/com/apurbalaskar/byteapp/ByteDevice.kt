package com.apurbalaskar.byteapp

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Byte © 2026 Apurba Laskar. Phone details and the per-brand "Phone setup"
// pages: every phone maker hides autostart / lock-screen / battery settings
// somewhere else. Each kind tries the maker's own page first, then the
// standard Android page, then the app's details page (never crashes).
class ByteDevice(private val activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "byte/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(info())
                "open" -> result.success(open(call.arguments as? String ?: "app"))
                "requestIgnoreBattery" -> result.success(requestIgnoreBattery())
                else -> result.notImplemented()
            }
        }
    }

    private val pkg: String get() = activity.packageName

    private fun sysProp(key: String): String = try {
        @SuppressLint("PrivateApi")
        val c = Class.forName("android.os.SystemProperties")
        (c.getMethod("get", String::class.java).invoke(null, key) as? String) ?: ""
    } catch (e: Throwable) {
        ""
    }

    private fun ignoringBattery(): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            (activity.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(pkg)
        } else {
            true
        }
    } catch (e: Throwable) {
        false
    }

    private fun info(): Map<String, Any> {
        val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        try { am.getMemoryInfo(mi) } catch (e: Throwable) {}
        return mapOf(
            "manufacturer" to (Build.MANUFACTURER ?: ""),
            "brand" to (Build.BRAND ?: ""),
            "model" to (Build.MODEL ?: ""),
            "sdk" to Build.VERSION.SDK_INT,
            "release" to (Build.VERSION.RELEASE ?: ""),
            "lowRam" to am.isLowRamDevice,
            "totalMemMb" to (mi.totalMem / (1024L * 1024L)).toInt(),
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "miui" to (sysProp("ro.miui.ui.version.name").isNotEmpty() || sysProp("ro.mi.os.version.name").isNotEmpty()),
            "coloros" to (sysProp("ro.build.version.opporom").isNotEmpty() || sysProp("ro.build.version.oplusrom").isNotEmpty()),
            "funtouch" to sysProp("ro.vivo.os.version").isNotEmpty(),
            "emui" to sysProp("ro.build.version.emui").isNotEmpty(),
            "ignoringBattery" to ignoringBattery(),
        )
    }

    private fun comp(p: String, c: String): Intent = Intent().setComponent(ComponentName(p, c))
        .putExtra("package_name", pkg).putExtra("packagename", pkg).putExtra("extra_pkgname", pkg)
        .putExtra("package_label", "Byte").putExtra("pkg_name", pkg)

    private fun appDetails(): Intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))

    private fun brand(): String = ((Build.MANUFACTURER ?: "") + " " + (Build.BRAND ?: "")).lowercase()

    private fun isXiaomi(b: String) = b.contains("xiaomi") || b.contains("redmi") || b.contains("poco") ||
        sysProp("ro.miui.ui.version.name").isNotEmpty() || sysProp("ro.mi.os.version.name").isNotEmpty()
    private fun isVivo(b: String) = b.contains("vivo") || b.contains("iqoo")
    private fun isOppo(b: String) = b.contains("oppo") || b.contains("realme") || b.contains("oneplus") || b.contains("oplus")
    private fun isHuawei(b: String) = b.contains("huawei") || b.contains("honor")

    /** The candidates for one kind of setting on this phone, best first. */
    fun candidates(kind: String): List<Intent> {
        val b = brand()
        val out = mutableListOf<Intent>()
        when (kind) {
            "autostart" -> when {
                isXiaomi(b) -> out.add(comp("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"))
                isVivo(b) -> {
                    out.add(comp("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"))
                    out.add(comp("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"))
                    out.add(comp("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"))
                }
                isOppo(b) -> {
                    out.add(comp("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"))
                    out.add(comp("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"))
                    out.add(comp("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"))
                    out.add(comp("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"))
                }
                isHuawei(b) -> {
                    out.add(comp("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"))
                    out.add(comp("com.huawei.systemmanager", "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"))
                    out.add(comp("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"))
                    out.add(comp("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"))
                }
                b.contains("asus") -> out.add(comp("com.asus.mobilemanager", "com.asus.mobilemanager.autostart.AutoStartActivity"))
            }
            "lockscreen", "popup" -> when {
                isXiaomi(b) -> {
                    out.add(Intent("miui.intent.action.APP_PERM_EDITOR")
                        .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
                        .putExtra("extra_pkgname", pkg))
                    out.add(Intent("miui.intent.action.APP_PERM_EDITOR")
                        .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.AppPermissionsEditorActivity")
                        .putExtra("extra_pkgname", pkg))
                }
                isVivo(b) -> {
                    out.add(comp("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.SoftPermissionDetailActivity"))
                    out.add(comp("com.iqoo.secure", "com.iqoo.secure.safecenter.permission.SoftPermissionDetailActivity"))
                }
                isOppo(b) -> {
                    out.add(comp("com.coloros.safecenter", "com.coloros.safecenter.permission.floatwindow.FloatWindowListActivity"))
                    out.add(comp("com.oppo.safe", "com.oppo.safe.permission.floatwindow.FloatWindowListActivity"))
                }
            }
            "battery" -> when {
                isXiaomi(b) -> out.add(comp("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"))
                isVivo(b) -> out.add(comp("com.vivo.abe", "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity"))
                isOppo(b) -> {
                    out.add(comp("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"))
                    out.add(comp("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerConsumptionActivity"))
                }
                b.contains("samsung") -> {
                    // Samsung: Byte's own app page has Battery → Unrestricted.
                    out.add(appDetails())
                    out.add(comp("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"))
                }
                isHuawei(b) -> out.add(comp("com.huawei.systemmanager", "com.huawei.systemmanager.power.ui.HwPowerManagerActivity"))
                b.contains("nokia") || b.contains("hmd") ->
                    out.add(comp("com.evenwell.powersaving.g3", "com.evenwell.powersaving.g3.exception.PowerSaverExceptionActivity"))
            }
            "overlay" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                out.add(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$pkg")))
            }
            "notifications" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                out.add(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, pkg))
            }
        }
        // Standard Android pages behind the maker's own.
        if (kind == "battery" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            out.add(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
        if (kind == "lockscreen" && Build.VERSION.SDK_INT >= 34) {
            out.add(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$pkg")))
        }
        out.add(appDetails())
        return out
    }

    /** Opens the first page that exists; "maker", "android" or "app" says which, "" if none. */
    private fun open(kind: String): String {
        val list = candidates(kind)
        for (it in list) {
            try {
                it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(it)
                val isApp = it.action == Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                return if (isApp) "app" else if (it.component != null || (it.action?.startsWith("miui") == true)) "maker" else "android"
            } catch (e: Throwable) {
                // not on this phone (or not opened to other apps): try the next one
            }
        }
        return ""
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBattery(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (ignoringBattery()) return true
        return try {
            activity.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$pkg")))
            true
        } catch (e: Throwable) {
            try {
                activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (e2: Throwable) {
                false
            }
        }
    }
}
