import 'package:flutter_test/flutter_test.dart';
import 'package:ssg_shell/ssg_shell.dart';

void main() {
  group('parsePushData（§5.3）', () {
    test('reads the snake_case fields sent by the server', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'chat_id': '1571275627',
        'msg_id': '8842',
        'from_id': '1571275627',
      });

      expect(message.chatId, '1571275627');
      expect(message.messageId, '8842');
      expect(message.fromId, '1571275627');
    });

    test('accepts camelCase as well', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'chatId': '-100123',
        'messageId': 42,
      });

      expect(message.chatId, '-100123');
      // Numbers become strings: the spec says every field on the wire is a string.
      expect(message.messageId, '42');
    });

    test('empty fields count as missing so the Web does not navigate for nothing', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'chat_id': '  ',
        'msg_id': '',
      });

      expect(message.chatId, isNull);
      expect(message.messageId, isNull);
    });

    test('reads fields wrapped in custom.a of a raw APNs payload', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'custom': '{"i":"uuid","a":{"chat_id":"777","msg_id":"9"}}',
      });

      expect(message.chatId, '777');
      expect(message.messageId, '9');
      // The raw content is kept so diagnostics show exactly what the server sent.
      expect(message.data['custom'], contains('uuid'));
    });

    test('nested structures are kept as JSON without losing information', () {
      final PushMessage message = parsePushData(const <String, Object?>{
        'extra': <String, Object?>{'a': 1},
      });

      expect(message.data['extra'], '{"a":1}');
    });

    test('null and an empty map do not throw', () {
      expect(parsePushData(null).data, isEmpty);
      expect(parsePushData(const <String, Object?>{}).chatId, isNull);
    });
  });
}
