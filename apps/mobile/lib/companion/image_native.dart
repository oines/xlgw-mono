import 'dart:io';
import 'package:flutter/material.dart';
import 'assets_native.dart';

class CachedCompanionImage extends StatelessWidget {
  const CachedCompanionImage(
    this.path, {
    super.key,
    this.width,
    this.height,
    this.fit,
    required this.fallback,
  });
  final String path;
  final double? width, height;
  final BoxFit? fit;
  final Widget fallback;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: companionRelease,
    builder: (context, release, _) {
      if (release == null) return fallback;
      return FutureBuilder<File?>(
        future: cachedAsset(release, path),
        builder: (context, snapshot) {
          final file = snapshot.data;
          return file == null
              ? fallback
              : Image.file(
                  file,
                  width: width,
                  height: height,
                  fit: fit,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stack) => fallback,
                );
        },
      );
    },
  );
}
