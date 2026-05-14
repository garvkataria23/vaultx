import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/key_derivators/argon2.dart';
import 'package:pointycastle/key_derivators/api.dart';

/// Derives keys using Argon2id (primary) or PBKDF2-SHA256 (legacy).
/// Encrypts/decrypts JSON payloads and binary blobs with AES-256-GCM.
///
/// Heavy operations (Argon2id, batch decryption) are offloaded to isolates
/// so the UI thread never blocks.
class CryptoService {
  static const iterations = 210000;
  static const keyLength = 32;
  static const argon2Iterations = 3;
  static const argon2MemoryKiB = 65536;
  static const argon2Lanes = 2;
  final Random _random = Random.secure();

  Uint8List randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }

  /// Offloads Argon2id to an isolate so the UI thread stays responsive.
  Future<Uint8List> deriveCredentialKey(String secret, String saltB64) async {
    final result = await _runIsolate(
      (input) => _argon2Work(input as _Argon2Input),
      _Argon2Input(secret: secret, saltB64: saltB64),
    );
    return result;
  }

  /// Runs Argon2id — must be called inside an isolate (not on main thread).
  static Uint8List _argon2Work(_Argon2Input input) {
    final password = Uint8List.fromList(utf8.encode(input.secret));
    final salt = Uint8List.fromList(base64Decode(input.saltB64));
    final generator = Argon2BytesGenerator()
      ..init(
        Argon2Parameters(
          Argon2Parameters.ARGON2_id,
          salt,
          desiredKeyLength: keyLength,
          iterations: argon2Iterations,
          memory: argon2MemoryKiB,
          lanes: argon2Lanes,
        ),
      );
    final out = Uint8List(keyLength);
    generator.deriveKey(password, 0, out, 0);
    // Overwrite password in memory after use
    for (var i = 0; i < password.length; i++) {
      password[i] = 0;
    }
    return out;
  }

  Uint8List deriveLegacyCredentialKey(String secret, String saltB64) {
    return _pbkdf2(
      utf8.encode(secret),
      base64Decode(saltB64),
      iterations,
      keyLength,
    );
  }

  Uint8List deriveRecordKey(
    Uint8List masterKey,
    String noteId,
    String saltB64,
  ) {
    final mac = Hmac(sha256, masterKey);
    return Uint8List.fromList(
      mac.convert([...utf8.encode(noteId), ...base64Decode(saltB64)]).bytes,
    );
  }

  /// Zeroes out a Uint8List in-place to reduce sensitive data in memory.
  void wipe(Uint8List value) {
    for (var i = 0; i < value.length; i++) {
      value[i] = 0;
    }
  }

  Map<String, dynamic> encryptJson(Map<String, dynamic> value, Uint8List key) {
    final nonce = randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        pc.AEADParameters(
          pc.KeyParameter(key),
          128,
          nonce,
          Uint8List.fromList(utf8.encode('VaultX:v2:json')),
        ),
      );
    final sealed = cipher.process(
      Uint8List.fromList(utf8.encode(jsonEncode(value))),
    );
    return {
      'v': 2,
      'alg': 'AES-256-GCM',
      'nonce': base64Encode(nonce),
      'ct': base64Encode(sealed),
    };
  }

  Uint8List encryptBytes(List<int> value, Uint8List key) {
    final nonce = randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        pc.AEADParameters(
          pc.KeyParameter(key),
          128,
          nonce,
          Uint8List.fromList(utf8.encode('VaultX:v2:blob')),
        ),
      );
    final sealed = cipher.process(Uint8List.fromList(value));
    return Uint8List.fromList([...utf8.encode('VXBLOB2'), ...nonce, ...sealed]);
  }

  Uint8List decryptBytes(List<int> encrypted, Uint8List key) {
    if (encrypted.length > 7 &&
        utf8.decode(encrypted.take(7).toList(), allowMalformed: true) ==
            'VXBLOB2') {
      final nonce = encrypted.skip(7).take(12).toList();
      final sealed = encrypted.skip(19).toList();
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          pc.AEADParameters(
            pc.KeyParameter(key),
            128,
            Uint8List.fromList(nonce),
            Uint8List.fromList(utf8.encode('VaultX:v2:blob')),
          ),
        );
      return cipher.process(Uint8List.fromList(sealed));
    }
    const headerLength = 7;
    const ivLength = 16;
    const tagLength = 32;
    if (encrypted.length <= headerLength + ivLength + tagLength) {
      throw const FormatException('Encrypted blob is too short');
    }
    final header = utf8.decode(encrypted.take(headerLength).toList());
    if (header != 'VXBLOB1') {
      throw const FormatException('Unsupported encrypted blob');
    }
    final body = encrypted.take(encrypted.length - tagLength).toList();
    final actualTag = encrypted.skip(encrypted.length - tagLength).toList();
    final expectedTag = Hmac(sha256, key).convert(body).bytes;
    for (var i = 0; i < tagLength; i++) {
      if (actualTag[i] != expectedTag[i]) {
        throw const FormatException('Encrypted blob authentication failed');
      }
    }
    final iv = body.skip(headerLength).take(ivLength).toList();
    final cipher = body.skip(headerLength + ivLength).toList();
    final aes = enc.Encrypter(
      enc.AES(enc.Key(key), mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    return Uint8List.fromList(
      aes.decryptBytes(
        enc.Encrypted(Uint8List.fromList(cipher)),
        iv: enc.IV(Uint8List.fromList(iv)),
      ),
    );
  }

  Map<String, dynamic> decryptJson(Map raw, Uint8List key) {
    if (raw['v'] == 2) {
      final nonce = base64Decode(raw['nonce'] as String);
      final sealed = base64Decode(raw['ct'] as String);
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          pc.AEADParameters(
            pc.KeyParameter(key),
            128,
            Uint8List.fromList(nonce),
            Uint8List.fromList(utf8.encode('VaultX:v2:json')),
          ),
        );
      final clear = cipher.process(Uint8List.fromList(sealed));
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    }
    final iv = raw['iv'] as String;
    final ct = raw['ct'] as String;
    final expected = Hmac(
      sha256,
      key,
    ).convert(utf8.encode('v1.$iv.$ct')).toString();
    if (expected != raw['tag']) {
      throw const FormatException('Encrypted record authentication failed');
    }
    final aes = enc.Encrypter(
      enc.AES(enc.Key(key), mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    final clear = aes.decryptBytes(
      enc.Encrypted(base64Decode(ct)),
      iv: enc.IV(base64Decode(iv)),
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  /// Decrypts multiple note payloads in a single isolate to avoid
  /// repeated isolate overhead and to keep the UI thread free.
  Future<List<Map<String, dynamic>?>> decryptJsonBatch(
    List<BatchItem> items,
    Uint8List masterKey,
  ) async {
    return _runIsolate(
      (input) => _decryptBatchWork(input as _BatchInput),
      _BatchInput(masterKey: masterKey, items: items),
    );
  }

  static List<Map<String, dynamic>?> _decryptBatchWork(_BatchInput input) {
    final results = <Map<String, dynamic>?>[];
    for (final item in input.items) {
      try {
        final recordKey = _deriveRecordKeySync(
          input.masterKey,
          item.noteId,
          item.salt,
        );
        final raw = item.payload;
        if (raw['v'] == 2) {
          final nonce = base64Decode(raw['nonce'] as String);
          final sealed = base64Decode(raw['ct'] as String);
          final cipher = GCMBlockCipher(AESEngine())
            ..init(
              false,
              pc.AEADParameters(
                pc.KeyParameter(recordKey),
                128,
                Uint8List.fromList(nonce),
                Uint8List.fromList(utf8.encode('VaultX:v2:json')),
              ),
            );
          final clear = cipher.process(Uint8List.fromList(sealed));
          results.add(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
        } else {
          final iv = raw['iv'] as String;
          final ct = raw['ct'] as String;
          final expected = Hmac(
            sha256,
            recordKey,
          ).convert(utf8.encode('v1.$iv.$ct')).toString();
          if (expected != raw['tag']) {
            results.add(null);
            continue;
          }
          final aes = enc.Encrypter(
            enc.AES(
              enc.Key(recordKey),
              mode: enc.AESMode.cbc,
              padding: 'PKCS7',
            ),
          );
          final clear = aes.decryptBytes(
            enc.Encrypted(base64Decode(ct)),
            iv: enc.IV(base64Decode(iv)),
          );
          results.add(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
        }
        // Wipe derived key after use
        for (var i = 0; i < recordKey.length; i++) {
          recordKey[i] = 0;
        }
      } catch (_) {
        results.add(null);
      }
    }
    return results;
  }

  static Uint8List _deriveRecordKeySync(
    Uint8List masterKey,
    String noteId,
    String saltB64,
  ) {
    final mac = Hmac(sha256, masterKey);
    return Uint8List.fromList(
      mac.convert([...utf8.encode(noteId), ...base64Decode(saltB64)]).bytes,
    );
  }

  Uint8List _pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int length,
  ) {
    final hLen = sha256.convert([]).bytes.length;
    final blocks = (length / hLen).ceil();
    final output = <int>[];
    for (var block = 1; block <= blocks; block++) {
      final blockSalt = [...salt, ..._int32(block)];
      var u = Hmac(sha256, password).convert(blockSalt).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iterations; i++) {
        u = Hmac(sha256, password).convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      output.addAll(t);
    }
    return Uint8List.fromList(output.take(length).toList());
  }

  List<int> _int32(int i) => [
    (i >> 24) & 0xff,
    (i >> 16) & 0xff,
    (i >> 8) & 0xff,
    i & 0xff,
  ];

  Future<Uint8List> encryptBytesIsolate(List<int> value, Uint8List key) async {
    return compute(
      _encryptBytesWork,
      _EncryptBytesInput(value: Uint8List.fromList(value), key: key),
    );
  }

  Future<Uint8List> decryptBytesIsolate(
    List<int> encrypted,
    Uint8List key,
  ) async {
    return compute(
      _decryptBytesWork,
      _DecryptBytesInput(
        encrypted: Uint8List.fromList(encrypted),
        key: key,
      ),
    );
  }

  /// Runs [compute] in an isolate and returns the result.
  static Future<T> _runIsolate<T>(
    T Function(dynamic) computeFn,
    dynamic message,
  ) async {
    final receive = ReceivePort();
    try {
      await Isolate.spawn(
        _isolateEntry,
        _IsolateMessage(computeFn, message, receive.sendPort),
      );
      return await receive.first as T;
    } finally {
      receive.close();
    }
  }

  static void _isolateEntry(_IsolateMessage msg) {
    try {
      final result = msg.compute(msg.input);
      msg.sendPort.send(result);
    } catch (e) {
      msg.sendPort.send(e);
    }
  }
}

Uint8List _encryptBytesWork(_EncryptBytesInput input) {
  final nonce = Uint8List.fromList(
    List<int>.generate(12, (_) => Random.secure().nextInt(256)),
  );
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      pc.AEADParameters(
        pc.KeyParameter(input.key),
        128,
        nonce,
        Uint8List.fromList(utf8.encode('VaultX:v2:blob')),
      ),
    );
  final sealed = cipher.process(Uint8List.fromList(input.value));
  return Uint8List.fromList([...utf8.encode('VXBLOB2'), ...nonce, ...sealed]);
}

Uint8List _decryptBytesWork(_DecryptBytesInput input) {
  final encrypted = input.encrypted;
  final key = input.key;
  if (encrypted.length > 7 &&
      utf8.decode(encrypted.take(7).toList(), allowMalformed: true) ==
          'VXBLOB2') {
    final nonce = encrypted.skip(7).take(12).toList();
    final sealed = encrypted.skip(19).toList();
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        pc.AEADParameters(
          pc.KeyParameter(key),
          128,
          Uint8List.fromList(nonce),
          Uint8List.fromList(utf8.encode('VaultX:v2:blob')),
        ),
      );
    return cipher.process(Uint8List.fromList(sealed));
  }
  const headerLength = 7;
  const ivLength = 16;
  const tagLength = 32;
  if (encrypted.length <= headerLength + ivLength + tagLength) {
    throw const FormatException('Encrypted blob is too short');
  }
  final header = utf8.decode(encrypted.take(headerLength).toList());
  if (header != 'VXBLOB1') {
    throw const FormatException('Unsupported encrypted blob');
  }
  final body = encrypted.take(encrypted.length - tagLength).toList();
  final actualTag = encrypted.skip(encrypted.length - tagLength).toList();
  final expectedTag = Hmac(sha256, key).convert(body).bytes;
  for (var i = 0; i < tagLength; i++) {
    if (actualTag[i] != expectedTag[i]) {
      throw const FormatException('Encrypted blob authentication failed');
    }
  }
  final iv = body.skip(headerLength).take(ivLength).toList();
  final cipher = body.skip(headerLength + ivLength).toList();
  final aes = enc.Encrypter(
    enc.AES(enc.Key(key), mode: enc.AESMode.cbc, padding: 'PKCS7'),
  );
  return Uint8List.fromList(
    aes.decryptBytes(
      enc.Encrypted(Uint8List.fromList(cipher)),
      iv: enc.IV(Uint8List.fromList(iv)),
    ),
  );
}

class _EncryptBytesInput {
  final Uint8List value;
  final Uint8List key;
  _EncryptBytesInput({required this.value, required this.key});
}

class _DecryptBytesInput {
  final Uint8List encrypted;
  final Uint8List key;
  _DecryptBytesInput({required this.encrypted, required this.key});
}

class _Argon2Input {
  final String secret;
  final String saltB64;
  _Argon2Input({required this.secret, required this.saltB64});
}

class BatchItem {
  final String noteId;
  final String salt;
  final Map<String, dynamic> payload;
  BatchItem({required this.noteId, required this.salt, required this.payload});
}

class _BatchInput {
  final Uint8List masterKey;
  final List<BatchItem> items;
  _BatchInput({required this.masterKey, required this.items});
}

class _IsolateMessage {
  final dynamic input;
  final dynamic Function(dynamic) compute;
  final SendPort sendPort;
  _IsolateMessage(this.compute, this.input, this.sendPort);
}
