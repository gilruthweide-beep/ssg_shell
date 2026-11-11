import 'dart:convert';

import 'messages.g.dart';

/// §5.3 Parse push `data` into [PushMessage].
///
/// The server sends:
///
/// ```json
/// { "chat_id": "1571275627", "msg_id": "8842", "from_id": "1571275627" }
/// ```
///
/// The shape received by Dart depends on the SDK and platform: OneSignal's `additionalData`
/// is already a map, while raw APNs / FCM payloads may wrap business fields in `custom.a`.
/// Numeric values may be strings or integers. Normalize these variations here:
///
/// - Accept `chat_id` / `chatId` and `msg_id` / `message_id` / `messageId` aliases.
///   `from_id` / `fromId`;
/// - Convert values to strings, matching the specification's wire parameter contract.
/// - Preserve nested maps and lists as JSON without losing information.
PushMessage parsePushData(Map<Object?, Object?>? data) {
  final flat = <String, String>{};
  _flattenInto(data, flat);

  // Raw APNs / FCM payload: OneSignal places business fields in custom.a.
  final custom = flat['custom'];
  if (custom != null && custom.trimLeft().startsWith('{')) {
    final decoded = _tryDecodeMap(custom);
    final inner = decoded?['a'];
    if (inner is Map) {
      _flattenInto(inner.cast<Object?, Object?>(), flat);
    }
  }

  return PushMessage(
    chatId: _pick(flat, const ['chat_id', 'chatId']),
    messageId: _pick(flat, const ['msg_id', 'message_id', 'messageId']),
    fromId: _pick(flat, const ['from_id', 'fromId']),
    data: flat,
  );
}

void _flattenInto(Map<Object?, Object?>? source, Map<String, String> into) {
  if (source == null) return;
  source.forEach((key, value) {
    if (key == null || value == null) return;
    final name = key.toString();
    if (name.isEmpty) return;
    into[name] = _stringify(value);
  });
}

String _stringify(Object value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  // Preserve nested data as JSON so diagnostics retain the complete server payload.
  return jsonEncode(value);
}

Map<String, Object?>? _tryDecodeMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

/// Treat empty strings as absent; an empty chatId would cause an unnecessary Web navigation attempt.
String? _pick(Map<String, String> flat, List<String> keys) {
  for (final key in keys) {
    final value = flat[key];
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}
