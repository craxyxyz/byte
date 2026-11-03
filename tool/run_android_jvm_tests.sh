#!/usr/bin/env bash
# Byte © 2026 Apurba Laskar. Offline render test of the Android audio stage on
# the JVM: compiles Byte's channel-stage classes with the media3 library the
# player uses and runs ByteFxOfflineRenderTest (no phone, no test framework).
set -euo pipefail
cd "$(dirname "$0")/.."
source /home/user/env.sh 2>/dev/null || true
V=1.4.1
AAR=$(find "$HOME/.gradle/caches/modules-2/files-2.1/androidx.media3/media3-common/$V" -name "*.aar" | head -1)
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
ANDROID_JAR=$(ls -d "$SDK"/platforms/android-3*/android.jar | head -1)
W=$(mktemp -d)
( cd "$W" && unzip -q -o "$AAR" classes.jar && mv classes.jar media3-common.jar )
GUAVA=$(find "$HOME/.gradle/caches/modules-2/files-2.1/com.google.guava/guava" -name "guava-3*-android.jar" | head -1)
SRC=packages/just_audio/android/src
mkdir -p "$W/out"
javac -nowarn -d "$W/out" -cp "$W/media3-common.jar:$ANDROID_JAR:$GUAVA" \
  $SRC/main/java/com/ryanheise/just_audio/ByteFxCore.java \
  $SRC/main/java/com/ryanheise/just_audio/ByteFxProcessor.java \
  $SRC/main/java/com/ryanheise/just_audio/ByteFxFloatFeeder.java \
  $SRC/test/java/com/ryanheise/just_audio/ByteFxOfflineRenderTest.java
java -cp "$W/out:$W/media3-common.jar:$GUAVA:$ANDROID_JAR" com.ryanheise.just_audio.ByteFxOfflineRenderTest
