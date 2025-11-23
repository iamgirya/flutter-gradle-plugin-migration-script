import 'dart:async';
import 'dart:io';

import 'gradle_utils.dart';

/// Script to migrate all detected projects to the new Gradle plugin registration mechanism.
/// Follows this doc: https://docs.flutter.dev/release/breaking-changes/flutter-gradle-plugin-apply
/// Run manually, not wired to any CI.
/// Some migration notes are embedded in the string containers below, under updateGradleFiles().
void main() async {
  // launch from path
  updateGradleFilesInDir(
    Directory.current,
  );
}

/// Get a list of all .gradle files in the directory and subfolders.
void updateGradleFilesInDir(Directory workDir) {
  workDir
      .listSync(recursive: true, followLinks: false)
      .whereType<Directory>()
      .where((directory) =>
          directory.path.endsWith('/android') &&
          !directory.path.contains('.dart'))
      .where((directory) => !directory.path.contains('_deprecated'))
      .forEach((androidFolder) async {
    try {
      final updated = await updateGradleFiles(androidFolder);
      if (updated == Result.noAppBuildFile || updated == Result.updated) {
        // Already updated or this is a plugin (should not be updated)
      } else if (updated == Result.success) {
        stdout.writeln('Updated ${androidFolder.path}');
      } else {
        stdout.writeln('NOT Updated ${androidFolder.path}');
      }
    } catch (error, st) {
      stdout
        ..writeln('Error ${androidFolder.path}')
        ..writeln(error.toString())
        ..writeln(st.toString());
    }
  });
}

enum Result {
  success,
  noFiles,
  noAppBuildFile,
  updated,
}

Future<Result> updateGradleFiles(Directory androidFolder) async {
  final buildFile = File('${androidFolder.path}/build.gradle');
  final appBuildFile = File('${androidFolder.path}/app/build.gradle');
  final settingsFile = File('${androidFolder.path}/settings.gradle');

  if (!appBuildFile.existsSync()) {
    return Result.noAppBuildFile;
  }
  if (!(buildFile.existsSync() && settingsFile.existsSync())) {
    return Result.noFiles;
  }

  final buildContent = buildFile.readAsLinesSync();
  final appBuildContent = appBuildFile.readAsLinesSync();
  final settingsContent = settingsFile.readAsLinesSync();
  // Files included via 'apply from' are not processed, because "Only Project and Settings build scripts can contain plugins {} blocks". Only these three files.

  if (!buildContent.contains('buildscript {') ||
      settingsContent.contains('pluginManagement {')) {
    return Result.updated;
  }

  // --- settings.gradle
  final kotlinVersion = buildContent
      .getVersionOfDependence('org.jetbrains.kotlin:kotlin-gradle-plugin');
  final agpVersion =
      buildContent.getVersionOfDependence('com.android.tools.build:gradle')!;
  settingsContent.removeWhere(
    (line) => SettingsContainer.settingsLinesToDelete.contains(line),
  );

  // --- build.gradle
  var repositoriesBlock =
      buildContent.removeBlock('repositories {').toSingleString;
  if (repositoriesBlock.isEmpty) {
    repositoriesBlock = '''
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }''';
  } else {
    if (repositoriesBlock.endsWith('\n')) {
      repositoriesBlock =
          repositoriesBlock.substring(0, repositoriesBlock.length - 1);
    }
  }

  // custom dependencies
  String settingsAddPlugins = '';
  final dependenciesBlock = buildContent.removeBlock('dependencies {');
  final configurationBlock = <String>[];
  for (final dependence in BuildContainer.dependencePluginNames) {
    final version =
        dependenciesBlock.getVersionOfDependence(dependence.key, buildContent);
    if (version != null) {
      settingsAddPlugins +=
          '\n    id "${dependence.value}" version "$version" apply false';

      //exclude
      final index = dependenciesBlock
          .indexWhere((element) => element.contains(dependence.key));
      if (index != -1 && index != dependenciesBlock.length - 1) {
        if (dependenciesBlock[index + 1].contains('exclude')) {
          configurationBlock
              .add('    ${dependenciesBlock[index + 1].trimLeft()}');
        }
      }
    }
  }

  // huawei case, version
  final huaweiVersion = dependenciesBlock.getVersionOfDependence(
    BuildContainer.huaweiDependencePluginName,
    buildContent,
  );

  // plugins what needs resolution strategy plugins
  String resolutionStrategyPluginsIfBlocks = '';
  for (final resolutionPlugin in BuildContainer.resolutionStrategyPlugins) {
    final version = dependenciesBlock.getVersionOfDependence(
      resolutionPlugin.key,
      buildContent,
    );
    if (version != null) {
      resolutionStrategyPluginsIfBlocks += '''
\n            if (it.requested.id.id == '${resolutionPlugin.value}') {
                it.useModule('${resolutionPlugin.key}:$version')
            }''';
    }
  }

  // remove buildscript
  buildContent.removeBlock('buildscript {');
  if (buildContent.first.isEmpty) {
    buildContent.removeAt(0);
  }

  // Huawei case, insert buildscript
  String buildContentPrefix = '';
  if (huaweiVersion != null) {
    buildContentPrefix = BuildContainer.huaweiBuildScriptBlock(
      huaweiVersion,
      agpVersion,
      repositoriesBlock,
    );
  }

  // insert configurationBlock for excludes
  if (configurationBlock.isNotEmpty) {
    configurationBlock
      ..insert(0, '\nconfigurations.all {')
      ..add('}');

    buildContent.addAll(configurationBlock);
  }

  // --- app/build.gradle
  appBuildContent
    ..removeWhere(
      (line) => AppBuildContainer.appBuildLinesToDelete.contains(line),
    )
    ..removeBlock('if (flutterRoot == null) {')
    ..removeFromDependencies('org.jetbrains.kotlin:kotlin-stdlib-jdk7');

  // custom apply plugins
  String addPlugins = '';
  for (final apply in AppBuildContainer.applyPluginNames) {
    final lineToDeleteInd =
        appBuildContent.indexWhere((line) => line.contains(apply));
    if (lineToDeleteInd != -1) {
      appBuildContent.removeAt(lineToDeleteInd);
      addPlugins += '\n    id "$apply"';
    }
  }
  appBuildContent.insert(0, AppBuildContainer.appBuildPluginsBlock(addPlugins));

  settingsContent.removeDoubleNewLines();
  buildContent.removeDoubleNewLines();
  appBuildContent.removeDoubleNewLines();

  await settingsFile.writeAsString(
    SettingsContainer.settingsText(
          kotlinVersion,
          agpVersion,
          repositoriesBlock,
          settingsAddPlugins,
          resolutionStrategyPluginsIfBlocks,
        ) +
        settingsContent.toSingleString,
  );
  await buildFile
      .writeAsString(buildContentPrefix + buildContent.toSingleString);
  await appBuildFile.writeAsString(appBuildContent.toSingleString);

  return Result.success;
}

class BuildContainer {
  /// Dependencies that will be migrated to the new mechanism.
  /// key - how the dependency is written via classpath; value - how it should appear in plugins {}.
  static const dependencePluginNames = [
    MapEntry(
      'com.google.gms:google-services',
      'com.google.gms.google-services',
    ),
    MapEntry(
      'com.google.firebase:firebase-crashlytics-gradle',
      'com.google.firebase.crashlytics',
    ),
    MapEntry(
      'com.yandex.android:speechkit-internal',
      'com.yandex.android.speechkit-internal',
    ),
    MapEntry(
      'com.google.devtools.ksp:com.google.devtools.ksp.gradle.plugin',
      'com.google.devtools.ksp',
    ),
    MapEntry(
      'io.appmetrica.analytics:gradle',
      'io.appmetrica.analytics.gradle',
    ),
    // TODO: add yours
  ];

  // Plugins that cannot be resolved by name in the plugins block in settings.gradle because the repository is specified incorrectly.
  // Example used as a reference: https://stackoverflow.com/questions/71121109/com-huawei-agconnect-plugin-not-found
  // This is a workaround, but it works for now.
  static const resolutionStrategyPlugins = [
    MapEntry(
      'io.appmetrica.analytics:gradle',
      'io.appmetrica.analytics.gradle',
    ),
    MapEntry(
      'com.google.firebase:firebase-crashlytics-gradle',
      'com.google.firebase.crashlytics',
    ),
  ];

  // This could also be migrated using the resolutionStrategyPlugins mechanism, but this plugin additionally requires com.android.tools.build:gradle specifically in buildscript:
  // https://stackoverflow.com/questions/71121109/com-huawei-agconnect-plugin-not-found
  // Maybe Huawei will fix this in future versions.
  static const huaweiDependencePluginName = 'com.huawei.agconnect:agcp';

  static String huaweiBuildScriptBlock(
    String huaweiVersion,
    String agpVersion,
    String repositories,
  ) =>
      '''
buildscript {
$repositories

    dependencies {
      classpath "com.android.tools.build:gradle:$agpVersion"
      classpath "com.huawei.agconnect:agcp:$huaweiVersion"
    }
}
''';
}

class SettingsContainer {
  static const settingsLinesToDelete = [
    'def localPropertiesFile = new File(rootProject.projectDir, "local.properties")',
    'def properties = new Properties()',
    'assert localPropertiesFile.exists()',
    'localPropertiesFile.withReader("UTF-8") { reader -> properties.load(reader) }',
    'def flutterSdkPath = properties.getProperty("flutter.sdk")',
    'assert flutterSdkPath != null, "flutter.sdk not set in local.properties"',
    r'apply from: "$flutterSdkPath/packages/flutter_tools/gradle/app_plugin_loader.gradle"',
  ];

  static String resolutionStrategyBlock(String plugins) => '''

    resolutionStrategy {
        eachPlugin {$plugins
        }
    }''';

  static String settingsText(
    String? kotlinVersion,
    String agpVersion,
    String repositories,
    String settingsAddPlugins,
    String resolutionStrategyPluginsIfBlocks,
  ) =>
      '''
pluginManagement {
    def flutterSdkPath = {
        def properties = new Properties()
        file("local.properties").withInputStream { properties.load(it) }
        def flutterSdkPath = properties.getProperty("flutter.sdk")
        assert flutterSdkPath != null, "flutter.sdk not set in local.properties"
        return flutterSdkPath
    }()

    includeBuild("\$flutterSdkPath/packages/flutter_tools/gradle")

$repositories${resolutionStrategyPluginsIfBlocks.isEmpty ? '' : resolutionStrategyBlock(resolutionStrategyPluginsIfBlocks)}
}

plugins {
    id "dev.flutter.flutter-plugin-loader" version "1.0.0"
    id "com.android.application" version "$agpVersion" apply false${kotlinVersion != null ? '\n    id "org.jetbrains.kotlin.android" version "$kotlinVersion" apply false' : ''}$settingsAddPlugins
}

''';
}

class AppBuildContainer {
  static const appBuildLinesToDelete = [
    "def flutterRoot = localProperties.getProperty('flutter.sdk')",
    "apply plugin: 'com.android.application'",
    "apply plugin: 'kotlin-android'",
    "apply plugin: 'com.jetbrains.kotlin.android'",
    r'apply from: "$flutterRoot/packages/flutter_tools/gradle/flutter.gradle"',
  ];

  // The list can be incomplete because the plugins {...} block is essentially syntactic sugar that ultimately translates to apply "...":
  // https://www.droidcon.com/2023/06/12/gradle-deep-dive-demystifying-the-groovy-script/
  static const applyPluginNames = [
    'com.google.gms.google-services',
    'com.google.firebase.crashlytics',
    'com.huawei.agconnect',
    'com.yandex.android.speechkit-internal',
  ];

  static String appBuildPluginsBlock(String addPlugins) => '''
plugins {
    id "com.android.application"
    id "kotlin-android"
    id "dev.flutter.flutter-gradle-plugin"$addPlugins
}
''';
}
