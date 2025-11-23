## Flutter Gradle Plugin Migration Script

A small Dart utility that migrates Android Gradle files in Flutter apps to the new Gradle plugin application mechanism introduced by Flutter’s breaking change “flutter-gradle-plugin-apply”.

- Follows the official guidance: https://docs.flutter.dev/release/breaking-changes/flutter-gradle-plugin-apply
- Scans recursively for `android/` folders and updates only the three top-level Gradle scripts:
  - `android/settings.gradle`
  - `android/build.gradle`
  - `android/app/build.gradle`

### What it does

- Moves plugin classpaths from `buildscript {}` into the modern `plugins {}` syntax in `settings.gradle`/`app/build.gradle`.
- Cleans obsolete lines (e.g., legacy Flutter loader apply lines).
- Keeps repositories (`google()`, `mavenCentral()`, `gradlePluginPortal()`) in place.
- Handles special cases:
  - Plugins that require resolution strategy in `settings.gradle`.
  - Huawei AG Connect plugin requiring `buildscript` with AGP dependency.
- Skips:
  - Android modules already migrated (e.g., `pluginManagement {}` present).
  - Modules without `app/build.gradle`.
  