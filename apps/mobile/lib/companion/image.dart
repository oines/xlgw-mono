import 'package:flutter/material.dart';
import 'assets.dart';
import 'image_native.dart' if (dart.library.js_interop) 'image_web.dart';

class CompanionImage extends StatelessWidget {
  const CompanionImage(
    this.path, {
    super.key,
    this.width,
    this.height,
    this.fit,
  });
  final String path;
  final double? width, height;
  final BoxFit? fit;

  @override
  Widget build(BuildContext context) {
    final fallback = Image.asset(
      '$bundledCompanion/$path',
      width: width,
      height: height,
      fit: fit,
      excludeFromSemantics: true,
    );
    return CachedCompanionImage(
      path,
      width: width,
      height: height,
      fit: fit,
      fallback: fallback,
    );
  }
}
