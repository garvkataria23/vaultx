import 'package:flutter_test/flutter_test.dart';
import 'package:vaultx/services/services.dart';

void main() {
  test('encrypts and authenticates note payloads', () async {
    final crypto = CryptoService();
    final salt = 'AAAAAAAAAAAAAAAAAAAAAA==';
    final key = await crypto.deriveCredentialKey('correct horse battery staple', salt);
    final encrypted = crypto.encryptJson({'title': 'Secret', 'body': 'Hidden'}, key);

    expect(encrypted['ct'], isNot(contains('Secret')));
    expect(crypto.decryptJson(encrypted, key)['title'], 'Secret');

    final tampered = Map<String, dynamic>.from(encrypted)..['ct'] = '${encrypted['ct']}AA';
    expect(() => crypto.decryptJson(tampered, key), throwsFormatException);
  });

  test('uses versioned AES-GCM envelopes for new payloads', () async {
    final crypto = CryptoService();
    final key = await crypto.deriveCredentialKey('correct horse battery staple', 'AAAAAAAAAAAAAAAAAAAAAA==');
    final encrypted = crypto.encryptJson({'title': 'Secret'}, key);

    expect(encrypted['v'], 2);
    expect(encrypted['alg'], 'AES-256-GCM');
    expect(encrypted.keys, isNot(contains('tag')));
    expect(crypto.decryptJson(encrypted, key)['title'], 'Secret');
  });

  test('encrypts binary blobs with authenticated VXBLOB2 envelope', () async {
    final crypto = CryptoService();
    final key = await crypto.deriveCredentialKey('correct horse battery staple', 'AAAAAAAAAAAAAAAAAAAAAA==');
    final encrypted = crypto.encryptBytes([1, 2, 3, 4], key);

    expect(String.fromCharCodes(encrypted.take(7)), 'VXBLOB2');
    expect(crypto.decryptBytes(encrypted, key), [1, 2, 3, 4]);

    encrypted[25] = encrypted[25] ^ 1;
    expect(() => crypto.decryptBytes(encrypted, key), throwsA(isA<Exception>()));
  });
}
