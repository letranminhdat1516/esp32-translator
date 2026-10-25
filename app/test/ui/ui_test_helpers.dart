import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/ui/theme.dart';

const testFont = 'BeVietnamPro';

/// Registers the bundled Be Vietnam Pro so Vietnamese renders in goldens
/// (flutter_test would otherwise draw every glyph as a block).
Future<void> loadTestFont() async {
  final loader = FontLoader(testFont)
    ..addFont(rootBundle.load('assets/fonts/BeVietnamPro-SemiBold.ttf'));
  await loader.load();

  // flutter_test draws icons as blocks unless the icon font is registered.
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final iconLoader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await iconLoader.load();
    }
  }
}

/// iPhone-sized logical screen: 393 x 852.
void useIphoneSize(WidgetTester tester, {double ratio = 2}) {
  tester.view.devicePixelRatio = ratio;
  tester.view.physicalSize = Size(393 * ratio, 852 * ratio);
  addTearDown(tester.view.reset);
}

Widget harness(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildTheme(fontFamily: testFont),
  home: child,
);
