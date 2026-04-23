# Shorebird Setup

This project already includes the Shorebird updater package and app id. The missing piece is how the release build is produced.

## Why `flutter run --release` does not work

`flutter run --release` builds a normal Flutter release binary.

That binary does not include Shorebird's patched engine, so `ShorebirdUpdater.isAvailable` is `false` and the app correctly reports that updates are unavailable.

To receive in-app updates, the installed app must be built with `shorebird release`, then patched with `shorebird patch`.

## Current repo state

- `shorebird.yaml` is present with the app id for this app.
- `shorebird_code_push` is included in `pubspec.yaml`.
- Automatic Shorebird checks are enabled with `auto_update: true`.
- Manual update actions in the settings screen still work and can be used to force a check or install flow from inside the app.

## One-time setup

1. Install the Shorebird CLI.
2. Sign in.
3. Verify the toolchain.

```bash
shorebird login
shorebird doctor
```

## Create a release build

Build the app with Shorebird, not plain Flutter.

For Play Store style distribution:

```bash
shorebird release android
```

For local APK testing or side loading:

```bash
shorebird release android --artifact apk
```

This creates the release record Shorebird needs and produces a binary that can actually receive patches.

## Test the release locally

The easiest local check is:

```bash
shorebird preview
```

That installs a Shorebird-built release on a connected device or emulator.

You can also install the generated APK manually, but it still must come from `shorebird release android --artifact apk`.

## Publish an update

1. Start from an app version that was released with Shorebird.
2. Make Dart-only changes.
3. Publish a patch for the same release version.

```bash
shorebird patch android
```

After the app launches, Shorebird checks for updates in the background. A downloaded patch becomes active on the next app restart.

## Version matching rules

Patches only apply to the exact release version they were built for.

For this project, the current app version comes from `pubspec.yaml` and Android picks it up through `flutter.versionName` and `flutter.versionCode`.

Example current version at the time of writing:

- release version: `0.12.0-beta.2+7`

If the installed build is `0.12.0-beta.2+7`, the patch must target that same release. A patch for `+8` will not apply.

## What can be patched

Shorebird patches Dart code.

Safe candidates:

- Flutter UI changes
- business logic in Dart
- Riverpod logic
- pure-Dart dependency updates

Not patchable:

- Android or iOS native code
- Flutter engine changes
- new or changed assets that the patched Dart code depends on

If native or asset changes are involved, ship a new release instead of a patch.

## How to confirm it is working

Check device logs.

- If you see log lines prefixed with `[shorebird]`, the installed app is using a Shorebird release build.
- If there are no `[shorebird]` logs, the app was not built with `shorebird release`.

Useful things to verify in logs:

- the `app_id`
- the release version being requested
- whether Shorebird reports `no active patch`

If Shorebird reports `no active patch`, first verify that the installed app version exactly matches the release version you patched.

## Typical Android test flow for this repo

```bash
shorebird release android --artifact apk
shorebird preview
```

Then:

1. Make a Dart-only change.
2. Run `shorebird patch android`.
3. Launch the app.
4. Wait for the automatic background check, or use the manual update action in settings.
5. Restart the app to load the patch.

## Notes for this repo

- The settings UI already handles manual check and install actions.
- Automatic checks are now enabled on launch.
- Manual update controls remain useful for testing and for forcing an update check without restarting the app.
