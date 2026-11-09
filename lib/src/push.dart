import 'dart:convert';

import 'messages.g.dart';

/// §5.3 把推送 `data` 解析成 [PushMessage]。
///
/// 服务端下发的是：
///
/// ```json
/// { "chat_id": "1571275627", "msg_id": "8842", "from_id": "1571275627" }
/// ```
///
/// 但到 Dart 手里的形状取决于 SDK 和平台：OneSignal 的 `additionalData` 是
/// 已经解开的 map，APNs / FCM 的原始 payload 可能把它裹在 `custom.a` 里，
/// 数字字段有时是 `String` 有时是 `int`。这里一次性抹平：
///
/// - 键名兼容 `chat_id` / `chatId`、`msg_id` / `message_id` / `messageId`、
///   `from_id` / `fromId`；
/// - 值一律转成字符串（规范规定过线的 params 全是字符串）；
/// - 嵌套的 map / list 用 JSON 编码保留，不丢信息。
PushMessage parsePushData(Map<Object?, Object?>? data) {
  final flat = <String, String>{};
  _flattenInto(data, flat);

  // 原始 APNs / FCM payload：OneSignal 把业务字段放在 custom.a 里。
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
  // 嵌套结构原样保留成 JSON：诊断时还能看到服务端到底发了什么。
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

/// 空串按「没给」算：服务端偶尔会下发空字段，拿它当 chatId 会让 Web 白跳一次。
String? _pick(Map<String, String> flat, List<String> keys) {
  for (final key in keys) {
    final value = flat[key];
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}
