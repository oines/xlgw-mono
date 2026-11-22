import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

typedef Data = Map<String, dynamic>;

const harborOffline = bool.fromEnvironment('HARBOR_OFFLINE');

List<Data> objects(Object? raw) => raw is List
    ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : [];
Data data(Object? raw) => raw is Map ? Map<String, dynamic>.from(raw) : {};
String text(Data value, String key, [String empty = '']) =>
    value[key]?.toString() ?? empty;
String newID() => const Uuid().v4();

class ApiError implements Exception {
  const ApiError(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
  @override
  String toString() => message;
}

class HarborApi {
  HarborApi({http.Client? client, String? base})
    : client = client ?? http.Client(),
      base = base ?? _base();
  final http.Client client;
  final String base;
  String? token;
  VoidCallback? onUnauthorized;
  static const storage = FlutterSecureStorage();
  static const _key = 'harbor.auth.v1';
  static String _base() {
    const configured = String.fromEnvironment('HARBOR_API_URL');
    if (configured.isNotEmpty) return configured.replaceAll(RegExp(r'/+$'), '');
    if (kIsWeb) return Uri.base.origin;
    if (defaultTargetPlatform == TargetPlatform.android)
      return 'http://10.0.2.2:8080';
    return 'http://127.0.0.1:8080';
  }

  Future<void> restore() async {
    token = await storage.read(key: _key);
  }

  Future<void> remember(String? value) async {
    token = value;
    if (value == null) {
      await storage.delete(key: _key);
    } else {
      await storage.write(key: _key, value: value);
    }
  }

  Uri uri(String path) => Uri.parse('$base/api/v1$path');
  Map<String, String> get headers => {
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };
  ApiError error(int status, String raw) {
    Data payload = {};
    try {
      payload = data(jsonDecode(raw));
    } on FormatException {
      /* use fallback */
    }
    if (status == 401 && token != null) onUnauthorized?.call();
    return ApiError(
      status,
      text(payload, 'code', 'request_failed'),
      text(payload, 'message', '暂时无法完成（$status），请稍后重试'),
    );
  }

  Future<Data> request(
    String path, {
    String method = 'GET',
    Data? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final req = http.Request(method, uri(path))..headers.addAll(headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    try {
      final streamed = await client.send(req).timeout(timeout);
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(timeout);
      final value = utf8.decode(response.bodyBytes);
      if (response.statusCode >= 400) throw error(response.statusCode, value);
      return value.isEmpty ? {} : data(jsonDecode(value));
    } on http.ClientException {
      throw const ApiError(0, 'network', '连接不上心灵港湾，请检查网络后重试');
    } on TimeoutException {
      throw const ApiError(0, 'timeout', '连接超时，请稍后重试');
    }
  }

  Future<List<Data>> list(String path) async =>
      objects((await request(path))['items']);
  Future<Data> post(String path, [Data body = const {}]) =>
      request(path, method: 'POST', body: body);
  Future<Data> put(String path, Data body) =>
      request(path, method: 'PUT', body: body);
  Future<Data> patch(String path, Data body) =>
      request(path, method: 'PATCH', body: body);
  Future<Data> delete(String path) => request(path, method: 'DELETE');
  Stream<Data> events(String runId) async* {
    final req = http.Request('GET', uri('/ai/runs/$runId/events'))
      ..headers.addAll(headers);
    req.headers['Accept'] = 'text/event-stream';
    final response = await client
        .send(req)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode >= 400)
      throw error(response.statusCode, await response.stream.bytesToString());
    final payload = <String>[];
    var event = '';
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.startsWith('event:')) event = line.substring(6).trim();
      if (line.startsWith('data:')) payload.add(line.substring(5).trimLeft());
      if (line.isEmpty && payload.isNotEmpty) {
        final parsed = data(jsonDecode(payload.join('\n')));
        payload.clear();
        yield {...parsed, 'event': event};
        event = '';
      }
    }
  }
}
