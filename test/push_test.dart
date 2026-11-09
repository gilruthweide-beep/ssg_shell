import 'package:flutter_test/flutter_test.dart';
import 'package:ssg_shell/ssg_shell.dart';

void main() {
  group('parsePushData（§5.3）', () {
    test('服务端下发的下划线字段能读到', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'chat_id': '1571275627',
        'msg_id': '8842',
        'from_id': '1571275627',
      });

      expect(message.chatId, '1571275627');
      expect(message.messageId, '8842');
      expect(message.fromId, '1571275627');
    });

    test('驼峰写法同样兼容', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'chatId': '-100123',
        'messageId': 42,
      });

      expect(message.chatId, '-100123');
      // 数字一律转字符串：规范规定过线的字段全是字符串。
      expect(message.messageId, '42');
    });

    test('空字段按没给算，不会让 Web 白跳一次', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'chat_id': '  ',
        'msg_id': '',
      });

      expect(message.chatId, isNull);
      expect(message.messageId, isNull);
    });

    test('原始 APNs payload 里裹在 custom.a 的字段也能捞出来', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'custom': '{"i":"uuid","a":{"chat_id":"777","msg_id":"9"}}',
      });

      expect(message.chatId, '777');
      expect(message.messageId, '9');
      // 原样内容保留，诊断时还能看到服务端到底发了什么。
      expect(message.data['custom'], contains('uuid'));
    });

    test('嵌套结构编成 JSON 保留，不丢信息', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'extra': <String, Object?>{'a': 1},
      });

      expect(message.data['extra'], '{"a":1}');
    });

    test('null 和空 map 不抛', () {
      expect(parsePushData(null).data, isEmpty);
      expect(parsePushData(const <String, Object?>{}).chatId, isNull);
    });
  });
}
