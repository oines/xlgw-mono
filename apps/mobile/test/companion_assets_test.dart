import 'package:flutter_test/flutter_test.dart';
import 'package:spiritual_harbor/companion/assets.dart';

void main() {
  final digest = List.filled(64, 'a').join();
  Map<String, dynamic> manifest({
    String release = 'pets-1',
    int version = 1,
    String file = 'companion.glb',
    String? sha,
    int size = 1024,
  }) => {
    'current': release,
    'bundles': [
      {
        'release': release,
        'version': version,
        'files': [
          {'path': file, 'size': size, 'sha256': sha ?? digest},
        ],
      },
    ],
  };

  test('reads a compatible version and asset locations', () {
    final bundle = CompanionBundle.current(manifest())!;
    expect(bundle.release, 'pets-1');
    expect(bundle.files.single.sha256, digest);
    expect(bundle.has('companion.glb'), isTrue);
    expect(
      remoteAsset(
        'https://campus.example',
        bundle.release,
        bundle.files.single.path,
      ),
      'https://campus.example/companion-assets/pets-1/companion.glb',
    );
  });
  test('rejects incompatible, unsafe or malformed deployments', () {
    expect(CompanionBundle.current(manifest(version: 2)), isNull);
    expect(CompanionBundle.current(manifest(release: '../broken')), isNull);
    expect(CompanionBundle.current(manifest(file: '../companion.glb')), isNull);
    expect(CompanionBundle.current(manifest(file: 'viewer.js')), isNull);
    expect(CompanionBundle.current(manifest(sha: 'bad')), isNull);
    expect(CompanionBundle.current(manifest(size: 70 * 1024 * 1024)), isNull);
  });
}
