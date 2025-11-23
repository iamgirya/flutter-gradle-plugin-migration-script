import 'dart:io';

extension GradleBlocks on List<String> {
  String? getVersionOfField(String field) {
    try {
      final fieldLine = firstWhere(
        (element) => element.contains(field) && !element.contains(r'$'),
      );
      return RegExp('("|\').*("|\')')
          .firstMatch(fieldLine)![0]!
          .replaceAll(RegExp("(\"|')"), '');
    } catch (_) {
      return null;
    }
  }

  String? getVersionOfDependence(String dependence,
      [List<String>? versionContainer]) {
    try {
      final fieldLine = firstWhere((element) => element.contains(dependence));
      final versionStartInd = RegExp(r':').allMatches(fieldLine).last.end;
      final versionEndInd = RegExp("(\"|')").allMatches(fieldLine).last.start;
      final version = fieldLine.substring(versionStartInd, versionEndInd);

      if (version.contains(r'$')) {
        final interpolationRegExp = RegExp(r'\$\w+(_\w+)*');
        final interpolatedVersion = version.replaceAllMapped(
          interpolationRegExp,
          (match) => (versionContainer ?? this)
              .getVersionOfField(match.group(0)!.substring(1))!,
        );
        return interpolatedVersion;
      } else {
        return version;
      }
    } catch (_) {
      return null;
    }
  }

  List<String> removeBlock(String block) =>
      removeBlockAt(indexWhere((element) => element.contains(block)));

  List<String> removeBlockAt(int blockStartInd) {
    int blockLevel = 0;

    // Find the { of the given block
    int nowLineInd = blockStartInd;
    while (blockLevel == 0 && nowLineInd != length) {
      blockLevel += r'{'.allMatches(this[nowLineInd]).length;
      nowLineInd++;
    }

    while (blockLevel != 0 && nowLineInd != length) {
      blockLevel += r'{'.allMatches(this[nowLineInd]).length;
      blockLevel -= r'}'.allMatches(this[nowLineInd]).length;
      nowLineInd++;
    }

    final removingBlock = sublist(blockStartInd, nowLineInd);
    removeRange(blockStartInd, nowLineInd);
    return removingBlock;
  }

  void removeFromDependencies(String dependence) {
    final fieldLineInd = indexWhere((element) => element.contains(dependence));
    if (fieldLineInd == -1) {
      return;
    }

    // Check whether this is the only dependency
    if (fieldLineInd - 1 != -1 &&
        this[fieldLineInd - 1].endsWith('dependencies {') &&
        fieldLineInd + 1 != length &&
        this[fieldLineInd + 1].endsWith('}')) {
      if (fieldLineInd - 2 != -1 && this[fieldLineInd - 2].isEmpty) {
        removeRange(fieldLineInd - 2, fieldLineInd + 2);
      } else {
        removeRange(fieldLineInd - 1, fieldLineInd + 2);
      }
    } else {
      removeAt(fieldLineInd);
    }
  }
}

extension FileUtils on List<String> {
  void removeDoubleNewLines() {
    for (int i = 0; i < length; i++) {
      if (this[i].trim().isEmpty &&
          i + 1 != length &&
          this[i + 1].trim().isEmpty) {
        removeAt(i + 1);
        i--;
      }
    }

    return;
  }

  String get toSingleString =>
      fold('', (previousValue, element) => '$previousValue$element\n');
}

extension FileNameExtension on File {
  String get filename => uri.pathSegments.last;
}
