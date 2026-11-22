import 'package:flutter/material.dart';
import 'assets.dart';
import 'assets_web.dart';

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
  Widget build(BuildContext context) =>
      ValueListenableBuilder<CompanionBundle?>(
        valueListenable: webCompanionBundle,
        builder: (context, bundle, _) {
          if (bundle == null || !bundle.has(path)) {
            return fallback;
          }
          return Image.network(
            remoteAsset(Uri.base.origin, bundle.release, path),
            width: width,
            height: height,
            fit: fit,
            excludeFromSemantics: true,
            errorBuilder: (context, error, stack) => fallback,
          );
        },
      );
}
