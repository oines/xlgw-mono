import 'dart:io' show Platform;

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;

http.Client createHarborClient() {
  if (!Platform.isIOS) return http.Client();
  final configuration = URLSessionConfiguration.ephemeralSessionConfiguration()
    ..cache = null
    ..httpShouldSetCookies = false
    ..waitsForConnectivity = true;
  return CupertinoClient.fromSessionConfiguration(configuration);
}
