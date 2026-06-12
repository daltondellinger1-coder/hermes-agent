# Android Pocket Mode Prototype

Minimal Kotlin foundation for the future Hermes Pocket Mode companion app.

## Current build

The current APK is a native Android shell that loads Dalton's phone-facing Hermes cockpit directly inside a `WebView`:

```text
https://desktop-vcb4ksf-1.tail87092b.ts.net/cockpit
```

It also keeps the foreground-service foundation in place for future pocket/locked-screen microphone work.

## Included

- `MainActivity` native WebView shell for the existing mobile cockpit UI.
- Default cockpit URL prefilled for Dalton's Tailscale HTTPS host.
- WebView JavaScript, DOM storage, media playback, and microphone permission bridge.
- `PocketModeService` foreground service foundation.
- Persistent notification with planned/stubbed actions: Mute, Stop, Open.
- Manifest permissions for microphone, notifications, internet, and foreground microphone service.

## Not included yet

- Wake phrase/hotword detection.
- Native audio capture/encoding/upload outside WebView.
- Android-native TTS playback outside WebView/browser speech synthesis.
- Encrypted keystore-backed token storage.
- Physical lock-screen/pocket testing.

## Build from WSL

Known working local toolchain on Dalton's BeeLink/WSL:

```bash
export JAVA_HOME=/home/dalton/android-tooling/jdk-17
export ANDROID_HOME=/home/dalton/android-sdk
export ANDROID_SDK_ROOT=/home/dalton/android-sdk
export PATH=/home/dalton/android-tooling/jdk-17/bin:/home/dalton/android-tooling/gradle-8.9/bin:/home/dalton/android-sdk/platform-tools:$PATH
cd /home/dalton/.hermes/hermes-agent/prototypes/android-pocket-mode
printf 'sdk.dir=/home/dalton/android-sdk\n' > local.properties
./gradlew :app:assembleDebug
./gradlew :app:lintDebug
```

Debug APK output:

```text
app/build/outputs/apk/debug/app-debug.apk
```

The checked-in `gradlew` scripts are lightweight launchers that delegate to a local `gradle` binary. A full Gradle wrapper JAR cannot be generated in an offline environment without an existing Gradle installation; `gradle/wrapper/gradle-wrapper.properties` records the intended Gradle 8.9 distribution for developers who regenerate the standard wrapper.

Physical Android testing is required before claiming locked-screen microphone reliability.
