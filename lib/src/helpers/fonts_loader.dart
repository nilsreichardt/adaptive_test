import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:file/file.dart' as f;
import 'package:file/local.dart' as l;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform/platform.dart' as p;

/// A class representing a package within a multi-packages app
class Package {
  /// This is the name of the package as defined in the pubspec.yaml file
  final String? name;

  /// This is the path to the package relative to where the test is run from.
  final String? relativePath;

  /// Creates a new [Package] instance.
  /// Either [name] or [relativePath] must be provided.
  Package({this.name, this.relativePath})
      : assert(name != null || relativePath != null);
}

/// Load fonts to make sure they show up in golden tests.
///
/// To use it efficiently:
/// * Create a flutter_test_config.dart file. See:
/// https://api.flutter.dev/flutter/flutter_test/flutter_test-library.html
/// * add `await loadFonts();` in the `testExecutable` function.
///
/// *Note* for this function to work, your package needs to include all fonts
/// it uses in a font dir at the root of the project.
Future<void> loadFonts([String? package]) async {
  final fontManifest = await rootBundle.loadStructuredData<Iterable<dynamic>>(
    'FontManifest.json',
    (string) async => json.decode(string),
  );

  for (final Map<String, dynamic> font in fontManifest) {
    final fontLoader = FontLoader(derivedFontFamily(font));
    for (final Map<String, dynamic> fontType in font['fonts']) {
      fontLoader.addFont(rootBundle.load(fontType['asset']));
    }
    await fontLoader.load();
  }
}

/// There is no way to easily load the Roboto or Cupertino fonts.
/// To make them available in tests, a package needs to include their own copies of them.
///
/// GoldenToolkit supplies Roboto because it is free to use.
///
/// However, when a downstream package includes a font, the font family will be prefixed with
/// /packages/<package name>/<fontFamily> in order to disambiguate when multiple packages include
/// fonts with the same name.
///
/// Ultimately, the font loader will load whatever we tell it, so if we see a font that looks like
/// a Material or Cupertino font family, let's treat it as the main font family
@visibleForTesting
String derivedFontFamily(Map<String, dynamic> fontDefinition) {
  if (!fontDefinition.containsKey('family')) {
    return '';
  }

  final String fontFamily = fontDefinition['family'];

  if (_overridableFonts.contains(fontFamily)) {
    return fontFamily;
  }

  if (fontFamily.startsWith('packages/')) {
    final fontFamilyName = fontFamily.split('/').last;
    if (_overridableFonts.any((font) => font == fontFamilyName)) {
      return fontFamilyName;
    }
  } else {
    for (final Map<String, dynamic> fontType in fontDefinition['fonts']) {
      final String? asset = fontType['asset'];
      if (asset != null && asset.startsWith('packages')) {
        final packageName = asset.split('/')[1];
        return 'packages/$packageName/$fontFamily';
      }
    }
  }
  return fontFamily;
}

const List<String> _overridableFonts = [
  'Roboto',
  '.SF UI Display',
  '.SF UI Text',
  '.SF Pro Text',
  '.SF Pro Display',
];

/// Load fonts from a given package to make sure they show up in golden tests.
///
/// To use it efficiently:
/// * Create a flutter_test_config.dart file. See:
/// https://api.flutter.dev/flutter/flutter_test/flutter_test-library.html
/// * add `await loadFontsFromPackage(Package(name: 'my_theme', relativePath: './theme'));` in the `testExecutable` function.
///
/// *Note* for this function to work, your given package needs to include all fonts
/// it uses in a font dir at the root of the project referenced by the given [package] argument.
/// If no [package] is provided, it will look for a fonts dir at the root of the project.
/// If a [package] is provided with a [Package.relativePath] it will look for a fonts dir with the package located at that path
/// If a [package] is provided with a [Package.name] it will prefix the fonts dir with `packages/[package.name]`
Future<void> loadFontsFromPackage({Package? package}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await _load(loadFontsFromFontsDir(package));
  await _loadMaterialIconFont();
}

/// Assumes a fonts dir in root of project
@visibleForTesting
Map<String, List<Future<ByteData>>> loadFontsFromFontsDir([Package? package]) {
  final fontFamilyToData = <String, List<Future<ByteData>>>{};
  final currentDir = path.dirname(Platform.script.path);
  final fontsDirectory = path.join(
    currentDir,
    package == null || package.relativePath == null
        ? 'fonts'
        : '${package.relativePath}/fonts',
  );
  final prefix = package == null || package.name == null
      ? ''
      : 'packages/${package.name}/';
  for (final file in Directory(fontsDirectory).listSync()) {
    if (file is File) {
      final fontFamily =
          prefix + path.basenameWithoutExtension(file.path).split('-').first;
      (fontFamilyToData[fontFamily] ??= [])
          .add(file.readAsBytes().then((bytes) => ByteData.view(bytes.buffer)));
    }
  }
  return fontFamilyToData;
}

Future<void> _load(Map<String, List<Future<ByteData>>> fontFamilyToData) async {
  final waitList = <Future<void>>[];
  for (final entry in fontFamilyToData.entries) {
    final loader = FontLoader(entry.key);
    for (final data in entry.value) {
      loader.addFont(data);
    }
    waitList.add(loader.load());
  }
  await Future.wait(waitList);
}

// Loads the cached material icon font.
// Only necessary for golden tests. Relies on the tool updating cached assets
// before running tests.
Future<void> _loadMaterialIconFont() async {
  const f.FileSystem fs = l.LocalFileSystem();
  const p.Platform platform = p.LocalPlatform();
  final flutterRoot = fs.directory(platform.environment['FLUTTER_ROOT']);

  final iconFont = flutterRoot.childFile(
    fs.path.join(
      'bin',
      'cache',
      'artifacts',
      'material_fonts',
      'MaterialIcons-Regular.otf',
    ),
  );

  final bytes =
      Future<ByteData>.value(iconFont.readAsBytesSync().buffer.asByteData());

  await (FontLoader('MaterialIcons')..addFont(bytes)).load();
}
