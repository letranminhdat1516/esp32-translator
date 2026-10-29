# LiveTranslator (React Native, Android)

Android app of the native translator plan. Package and applicationId: `vn.cicca.livetranslator`.
The iPhone app is the Swift one in `../ios`; do not confuse this folder's `android/android/` (native project) with the repo root.

- React Native **0.88.1** (New Architecture on, Hermes on), React 19.3.0, TypeScript 6 (`strict: true`)
- minSdk 29, targetSdk 35, compileSdk 35, build-tools 35.0.0, NDK 28.2.13676358
- ABIs: arm64-v8a, armeabi-v7a
- Dependencies: `react-native-ble-plx` 3.5.x, `@react-native-async-storage/async-storage` 3.1.x

## Environment

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools   # or keep sdk.dir in android/android/local.properties
export PATH="$ANDROID_HOME/platform-tools:$PATH"
```

`android/android/local.properties` (git-ignored) must contain
`sdk.dir=/opt/homebrew/share/android-commandlinetools`.
Node >= 22.11 (Node 24 / npm 11 used), no yarn, no watchman needed.

## Install

```sh
cd android
npm install
```

## Test

```sh
npm test            # Jest
npx tsc --noEmit    # type check
```

## Run on the phone (Samsung Note 9, serial 271c1de1761c7ece)

USB debugging on, device listed by `adb devices`.

```sh
cd android
npx react-native start &          # Metro (note its PID, stop it when done)
npx react-native run-android --deviceId 271c1de1761c7ece
adb -s 271c1de1761c7ece exec-out screencap -p > shot.png
```

## Release build

```sh
cd android/android
./gradlew assembleRelease     # APK: app/build/outputs/apk/release/app-release.apk
./gradlew bundleRelease       # AAB
```

The release build is signed with the debug keystore for now; replace `signingConfigs` before publishing.

## Manifest

BLE permissions: `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` (API <= 30), `BLUETOOTH_SCAN` (`neverForLocation`),
`BLUETOOTH_CONNECT` (API 31+), feature `android.hardware.bluetooth_le`. Runtime permission prompts are the UI task's job.
