import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../shared/api.dart';
import 'assets.dart';

Future<Directory>? _root;
Future<String?>? _refresh;
final companionRelease = ValueNotifier<String?>(null);

Future<Directory> _dataDirectory() async {
  final app = await getApplicationSupportDirectory();
  return Directory(
    '${app.path}/companion-v$topologyVersion',
  ).create(recursive: true);
}

Future<String?> cachedRelease() async {
  try {
    final root = await (_root ??= _dataDirectory());
    final pointer = File('${root.path}/current');
    if (!await pointer.exists()) return null;
    final release = (await pointer.readAsString()).trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,79}$').hasMatch(release)) return null;
    if (!await File('${root.path}/$release/companion.glb').exists())
      return null;
    companionRelease.value = release;
    return release;
  } catch (_) {
    return null;
  }
}

Future<File?> cachedAsset(String release, String path) async {
  if (!CompanionBundle.validPath(path) ||
      !RegExp(r'^[a-z0-9][a-z0-9.-]{0,79}$').hasMatch(release))
    return null;
  final root = await (_root ??= _dataDirectory());
  final file = File('${root.path}/$release/$path');
  return await file.exists() ? file : null;
}

Future<String?> refreshAssets(HarborApi api) =>
    _refresh ??= _download(api).whenComplete(() => _refresh = null);

Future<String?> _download(HarborApi api) async {
  final previous = await cachedRelease();
  Directory? staging;
  final client = http.Client();
  try {
    final bundle = await discoverBundle(api);
    if (bundle == null || bundle.release == previous) return previous;
    final root = await (_root ??= _dataDirectory());
    final target = Directory('${root.path}/${bundle.release}');
    if (await target.exists() &&
        !await File('${target.path}/companion.glb').exists()) {
      await target.delete(recursive: true);
    }
    if (!await target.exists()) {
      staging = await root.createTemp('.incoming-');
      for (final asset in bundle.files) {
        final request = http.Request(
          'GET',
          Uri.parse(remoteAsset(api.base, bundle.release, asset.path)),
        );
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 12));
        if (response.statusCode != 200)
          throw HttpException('Asset download failed');
        final file = File('${staging.path}/${asset.path}');
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        final digest = _DigestSink();
        final hashing = sha256.startChunkedConversion(digest);
        var total = 0;
        try {
          await for (final part in response.stream.timeout(
            const Duration(seconds: 15),
          )) {
            total += part.length;
            if (total > asset.size)
              throw const FormatException('Asset length mismatch');
            hashing.add(part);
            sink.add(part);
          }
          hashing.close();
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (total != asset.size || digest.result?.toString() != asset.sha256)
          throw const FormatException('Asset checksum mismatch');
      }
      await staging.rename(target.path);
      staging = null;
    }
    final pointer = File('${root.path}/current.tmp');
    await pointer.writeAsString(bundle.release, flush: true);
    await pointer.rename('${root.path}/current');
    for (final entry in await root.list().toList()) {
      if (entry is! Directory) continue;
      final name = entry.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (name == bundle.release || name == previous) continue;
      try {
        await entry.delete(recursive: true);
      } catch (_) {
        /* Old cache is expendable. */
      }
    }
    companionRelease.value = bundle.release;
    return bundle.release;
  } catch (_) {
    return previous;
  } finally {
    client.close();
    if (staging != null) {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? result;
  @override
  void add(Digest data) {
    result = data;
  }

  @override
  void close() {}
}
