import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// Request signing and response decryption of the JM mobile API.
abstract final class JmCrypto {
  static const String appVersion = '2.1.7';
  static const String tokenSecret = '185Hcomic3PAPP7R';

  /// `/chapter_view_template` rejects [tokenSecret] with 403.
  static const String templateTokenSecret = '18comicAPPContent';
  static const String dataSecret = '185Hcomic3PAPP7R';
  static const String domainServerSecret = 'diosfjckwpqpdfjkvnqQjsik';

  static String md5Hex(String text) =>
      md5.convert(utf8.encode(text)).toString();

  /// Headers `token` and `tokenparam` for a request made at [ts] seconds.
  static Map<String, String> tokenHeaders(
    int ts, {
    String secret = tokenSecret,
  }) => <String, String>{
    'token': md5Hex('$ts$secret'),
    'tokenparam': '$ts,$appVersion',
  };

  /// Decrypts a response `data` field: Base64, then AES-ECB with the key
  /// md5([ts] + [secret]) as 32 ASCII hex characters, then PKCS7 padding.
  static String decrypt(String data, String ts, {String secret = dataSecret}) {
    final Uint8List cipherText = base64.decode(data.trim());
    final Uint8List key = Uint8List.fromList(
      utf8.encode(md5Hex('$ts$secret')),
    );
    final BlockCipher cipher = ECBBlockCipher(AESEngine())
      ..init(false, KeyParameter(key));
    final Uint8List plain = Uint8List(cipherText.length);
    for (int offset = 0; offset < cipherText.length; offset += 16) {
      cipher.processBlock(cipherText, offset, plain, offset);
    }
    final int padding = plain.isEmpty ? 0 : plain.last;
    final int end = padding > 0 && padding <= 16
        ? plain.length - padding
        : plain.length;
    return utf8.decode(plain.sublist(0, end));
  }
}
