# JARVIS — Android control app

Don's phone app for running Jarvis: sign in as ADMIN, then type (or speak)
commands — `create portal <name>`, `invite <email> to <portal>`,
`block <email> on <portal>`, `list portals`, `list methods`,
`show traffic <portal>` — or use the on-screen buttons for the same actions.
The generated invite code is shown **once** on screen and is never stored
on the phone (in-memory state only — no SharedPreferences, no DataStore).

## Pinned versions (Prompt 10)

| Tool | Version | Where |
|---|---|---|
| Gradle | 8.7 | `gradle/wrapper/gradle-wrapper.properties` (+ `gradlew`; see "Gradle wrapper jar" below) |
| Android Gradle Plugin | 8.4.1 | `build.gradle.kts` |
| Kotlin | 1.9.23 | `build.gradle.kts` |
| Compose compiler | 1.5.14 | `app/build.gradle.kts` (matches Kotlin 1.9.23) |
| compileSdk / targetSdk | 34 | `app/build.gradle.kts` |
| minSdk | 26 | `app/build.gradle.kts` |
| JDK | 17 | `app/build.gradle.kts` (`sourceCompatibility` / `jvmTarget`) |

AGP 8.4.1 needs Gradle 8.6+, so the wrapper's 8.7 is the pin — do not
downgrade it. Open `apps/android/` in **Android Studio Hedgehog or newer**
with JDK 17 and let Gradle sync; then **Run** on a device or emulator.

## Pointing the app at the server

`ApiClient.BASE_URL` is `http://10.0.2.2:4000` — the Android emulator's
alias for the host machine's `localhost:4000`, where the dev server runs.
On a physical phone, change it to your machine's LAN IP, e.g.
`http://192.168.1.10:4000` (same Wi-Fi, server on `0.0.0.0:4000`).
The manifest allows cleartext HTTP (`usesCleartextTraffic`) for that dev
address only — production must be HTTPS.

## Voice

On-device Android `SpeechRecognizer` is the default voice input — no
audio leaves the phone. The Whisper hook in `VoiceInput.kt` is **disabled**
unless a `WHISPER_API_KEY` is set (`whisperApiKey`), and even then it is
an integration point (multipart POST to OpenAI's transcriptions endpoint),
not wired to a recorder — see the comment in `VoiceInput.kt`.

## Launcher icon

No Jarvis logo or brand artwork has been supplied yet, so the launcher
icon is a neutral placeholder: a silver "J" monogram on near-black
(`res/mipmap-anydpi-v26/ic_launcher.xml` + `ic_launcher_round.xml`,
foreground `res/drawable/ic_launcher_foreground.xml`). Replace it when
Don provides a logo. minSdk 26 means the adaptive icon covers every
supported device — no legacy PNGs are needed.

## Gradle wrapper jar

`gradle/wrapper/gradle-wrapper.jar` is **not in the repo yet** — the tooling
used to push this code can only push text files, so the binary jar could
not be uploaded. Before the first build, fetch the official Gradle 8.7
wrapper jar into `gradle/wrapper/`:

```
curl -L -o gradle/wrapper/gradle-wrapper.jar \
  https://github.com/gradle/gradle/raw/v8.7.0/gradle/wrapper/gradle-wrapper.jar
```

Verify it with `sha256sum` — it must be
`cb0da6751c2b753a16ac168bb354870ebb1e162e9083f116729cec9c781156b8`.
(Or run `gradle wrapper --gradle-version 8.7` once from a machine that
already has Gradle, which generates the same file.) `gradlew` will not
run until the jar is in place.

## Build verification status

Prompt 10 was finished and its command flow verified against the live
dev server (`server/scripts/android-commands-test.sh`, 50 checks), but
**no Gradle build was run in this environment** — there is no JDK,
Android SDK, or Android Studio here. The first real build is the
**GitHub Actions workflow** `.github/workflows/apk-build.yml` (Issue
#13): it runs on every push to `apps/android/**` (and on demand from
the Actions tab), sets up JDK 17 + the Android SDK, fetches the
official Gradle 8.7 wrapper jar with its SHA-256 verified, and runs
`./gradlew assembleDebug`.

### Download the debug APK (no computer needed)

1. Open the repo on GitHub → **Actions** tab → **Android APK build
   (debug)** → pick the latest green run.
2. Scroll to **Artifacts** at the bottom of the run page and download
   **jarvis-debug-apk** (a zip containing `app-debug.apk`).
3. On your phone, unzip it and open the APK to install. Android will
   ask to allow installs from that source — this is a debug build
   signed with the default debug key, not a Play Store release.

**Artifact expiry:** the APK artifact is kept for **30 days** after the
run (`retention-days: 30` in the workflow). After that it disappears
from the run page — re-run the workflow (Actions tab → Run workflow)
to build a fresh one. If you need an APK kept longer, download it
before the 30 days are up.

Android Studio is still the way to run the app from source and
debug it: open `apps/android/` in **Android Studio Hedgehog or
newer** with JDK 17 and let Gradle sync; then **Run** on a device or
emulator. If a build fails on a version, update the table above with
what you pinned and why.
