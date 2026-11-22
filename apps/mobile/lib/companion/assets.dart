import '../shared/api.dart';

const bundledCompanion = 'assets/companion';
const topologyVersion = 1;

class CompanionBundle {
  CompanionBundle(this.release, this.files);
  final String release;
  final List<CompanionFile> files;
  bool has(String path) => files.any((file) => file.path == path);

  static CompanionBundle? current(Data manifest) {
    final expected = text(manifest, 'current');
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,79}$').hasMatch(expected)) return null;
    for (final bundle in objects(manifest['bundles'])) {
      if (bundle['release'] != expected || bundle['version'] != topologyVersion)
        continue;
      final candidates = objects(bundle['files']);
      if (candidates.isEmpty || candidates.length > 64) return null;
      final files = <CompanionFile>[];
      var length = 0;
      for (final row in candidates) {
        final path = text(row, 'path'),
            hash = text(row, 'sha256'),
            size = row['size'];
        if (!validPath(path) ||
            hash.length != 64 ||
            !RegExp(r'^[a-f0-9]+$').hasMatch(hash) ||
            size is! int ||
            size < 1 ||
            size > 64 * 1024 * 1024 ||
            files.any((file) => file.path == path))
          return null;
        length += size;
        files.add(CompanionFile(path, size, hash));
      }
      if (length > 100 * 1024 * 1024 ||
          !files.any((file) => file.path == 'companion.glb'))
        return null;
      return CompanionBundle(expected, files);
    }
    return null;
  }

  static bool validPath(String path) =>
      path.isNotEmpty &&
      path.length <= 120 &&
      path
          .split('/')
          .every(
            (segment) =>
                RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(segment),
          ) &&
      RegExp(r'\.(glb|vrm|png|webp|jpg|jpeg)$').hasMatch(path);
}

class CompanionFile {
  const CompanionFile(this.path, this.size, this.sha256);
  final String path, sha256;
  final int size;
}

String remoteAsset(String origin, String release, String path) =>
    '$origin/companion-assets/$release/$path';
Future<CompanionBundle?> discoverBundle(HarborApi api) async =>
    CompanionBundle.current(
      await api.request(
        '/companion/assets',
        timeout: const Duration(seconds: 6),
      ),
    );
