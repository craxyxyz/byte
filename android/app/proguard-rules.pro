# Byte release build (R8, obfuscated): keep what plugins use by reflection.
-keepattributes Signature, *Annotation*, InnerClasses, EnclosingMethod
-keepclassmembers enum * { *; }

# Background playback service + media session
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }
-keep class androidx.media.** { *; }

# In-app sign-in page
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }

# The app's own activity.
-keep class com.apurbalaskar.byteapp.** { *; }

-dontwarn com.google.android.play.core.**

# Strip Android log calls from the release build (no logging).
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static int w(...);
}
