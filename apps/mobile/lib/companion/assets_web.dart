import 'package:flutter/foundation.dart';
import '../shared/api.dart';
import 'assets.dart';

final webCompanionBundle = ValueNotifier<CompanionBundle?>(null);
Future<CompanionBundle?>? _refresh;
DateTime? _checked;

Future<CompanionBundle?> refreshWebBundle() {
  if (harborOffline) return Future.value(null);
  final checked = _checked;
  if (checked != null &&
      DateTime.now().difference(checked) < const Duration(minutes: 2)) {
    return Future.value(webCompanionBundle.value);
  }
  return _refresh ??= _check().whenComplete(() => _refresh = null);
}

Future<CompanionBundle?> _check() async {
  final api = HarborApi();
  try {
    if (api.base != Uri.base.origin) return null;
    final bundle = await discoverBundle(api);
    _checked = DateTime.now();
    if (webCompanionBundle.value?.release != bundle?.release)
      webCompanionBundle.value = bundle;
  } catch (_) {
    /* Retain the last loadable release. */
  } finally {
    api.client.close();
  }
  return webCompanionBundle.value;
}
