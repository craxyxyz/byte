import java.util.Properties

// ── Byte by Apurba Laskar ───────────────────────────────────────────────
// The id Android installs the app under (one place).
val byteApplicationId = "com.apurbalaskar.byte"

// Release signing key: android/key.properties (NOT in the source zip — see
// key.properties.example), or the file named by BYTE_KEY_PROPERTIES.
val keyProps = Properties().apply {
    val f = System.getenv("BYTE_KEY_PROPERTIES")?.let { file(it) } ?: rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keyProps.getProperty("storeFile") != null

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // "byte" is a Java keyword, so the code package is byteapp; the installed
    // application id stays com.apurbalaskar.byte.
    namespace = "com.apurbalaskar.byteapp"
    compileSdk = 37 // a plugin (permission_handler) needs 37; targetSdk stays Flutter's
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = byteApplicationId
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // One APK per CPU type: only that type's native libraries go in, so a
        // phone never picks a folder that has no Flutter engine in it.
        (project.findProperty("target-platform") as String?)?.let { tp ->
            val abis = tp.split(",").mapNotNull {
                when (it.trim()) {
                    "android-arm" -> "armeabi-v7a"
                    "android-arm64" -> "arm64-v8a"
                    "android-x64" -> "x86_64"
                    "android-x86" -> "x86"
                    else -> null
                }
            }
            if (abis.isNotEmpty()) ndk { abiFilters.clear(); abiFilters.addAll(abis) }
        }
    }

    // Release key (alias "apex", CN=Apurba Laskar). Every update must be signed
    // with the same key to install over the previous one — keep it safe.
    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Without key.properties a release build is signed with the local
            // debug key (fine for testing, cannot update the real app).
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.webkit:webkit:1.15.0")
}
