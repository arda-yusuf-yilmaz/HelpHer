import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum E2eeStatus { ready, newKeypair, backupAvailable }

/// Manages X25519 keypairs and AES-256-GCM encryption for direct chat E2EE.
class E2eeManager {
  static const _storage = FlutterSecureStorage();
  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits();

  static String _privKey(String uid) => 'e2ee_priv_$uid';
  static String _pubKey(String uid) => 'e2ee_pub_$uid';

  /// Ensures a keypair exists locally and publishes the public key to Firestore.
  /// Returns [E2eeStatus.ready] if the keypair already existed,
  /// [E2eeStatus.backupAvailable] if no local key but a Firestore backup
  /// exists (new device — caller should prompt for passphrase recovery), or
  /// [E2eeStatus.newKeypair] if a brand-new keypair was generated (caller
  /// should prompt to set up a backup passphrase).
  static Future<E2eeStatus> ensureKeypair(
    String uid,
    FirebaseFirestore firestore,
  ) async {
    try {
      final storedPriv = await _storage.read(key: _privKey(uid));
      final storedPub = await _storage.read(key: _pubKey(uid));
      if (storedPriv != null && storedPub != null) {
        // Already have a local keypair — just make sure public key is published.
        await firestore.collection('users').doc(uid).set(
          {'e2eePublicKey': base64.encode(base64.decode(storedPub))},
          SetOptions(merge: true),
        );
        return E2eeStatus.ready;
      }
      // No local keypair. Check whether the user has a Firestore backup.
      final backupDoc = await firestore
          .collection('users')
          .doc(uid)
          .collection('privateData')
          .doc('keyBackup')
          .get();
      if (backupDoc.exists) {
        return E2eeStatus.backupAvailable;
      }
      // Nothing anywhere — generate a fresh keypair.
      final keyPair = await _x25519.newKeyPair();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      final pubBytes = (await keyPair.extractPublicKey()).bytes;
      await _storage.write(key: _privKey(uid), value: base64.encode(privBytes));
      await _storage.write(key: _pubKey(uid), value: base64.encode(pubBytes));
      await firestore.collection('users').doc(uid).set(
        {'e2eePublicKey': base64.encode(pubBytes)},
        SetOptions(merge: true),
      );
      return E2eeStatus.newKeypair;
    } catch (_) {
      return E2eeStatus.ready; // Non-fatal fallback.
    }
  }

  /// Encrypts the local private key with a PBKDF2-derived wrapping key and
  /// stores the result in Firestore under users/{uid}/privateData/keyBackup.
  static Future<void> backupPrivateKey(
    String uid,
    String passphrase,
    FirebaseFirestore firestore,
  ) async {
    final privB64 = await _storage.read(key: _privKey(uid));
    if (privB64 == null) return;
    final privBytes = base64.decode(privB64);

    final salt = _aesGcm.newNonce(); // 16 random bytes as salt
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    final wrappingKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    final wrappingKeyBytes = await wrappingKey.extractBytes();
    final wrapKey = await _aesGcm.newSecretKeyFromBytes(wrappingKeyBytes);
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(privBytes, secretKey: wrapKey, nonce: nonce);

    await firestore
        .collection('users')
        .doc(uid)
        .collection('privateData')
        .doc('keyBackup')
        .set({
      'enc': base64.encode([...box.cipherText, ...box.mac.bytes]),
      'salt': base64.encode(salt),
      'iv': base64.encode(nonce),
    });
  }

  /// Fetches the Firestore backup, derives the wrapping key from [passphrase],
  /// decrypts the private key, and saves it to local secure storage.
  /// Returns true on success, false if the passphrase is wrong or no backup exists.
  static Future<bool> restoreFromBackup(
    String uid,
    String passphrase,
    FirebaseFirestore firestore,
  ) async {
    try {
      final doc = await firestore
          .collection('users')
          .doc(uid)
          .collection('privateData')
          .doc('keyBackup')
          .get();
      if (!doc.exists) return false;
      final data = doc.data()!;
      final salt = base64.decode(data['salt'] as String);
      final iv = base64.decode(data['iv'] as String);
      final raw = base64.decode(data['enc'] as String);
      final mac = raw.sublist(raw.length - 16);
      final ct = raw.sublist(0, raw.length - 16);

      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 100000,
        bits: 256,
      );
      final wrappingKey = await pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(passphrase)),
        nonce: salt,
      );
      final wrapKey = await _aesGcm.newSecretKeyFromBytes(
        await wrappingKey.extractBytes(),
      );
      final privBytes = await _aesGcm.decrypt(
        SecretBox(ct, nonce: iv, mac: Mac(mac)),
        secretKey: wrapKey,
      );

      // Reconstruct the X25519 public key from the private key.
      final keyPair = await _x25519.newKeyPairFromSeed(privBytes);
      final pubBytes = (await keyPair.extractPublicKey()).bytes;

      await _storage.write(key: _privKey(uid), value: base64.encode(privBytes));
      await _storage.write(key: _pubKey(uid), value: base64.encode(pubBytes));
      await firestore.collection('users').doc(uid).set(
        {'e2eePublicKey': base64.encode(pubBytes)},
        SetOptions(merge: true),
      );
      return true;
    } catch (_) {
      return false; // Wrong passphrase or decryption failure.
    }
  }

  /// Derives the shared secret bytes for a direct chat with [theirPublicKeyB64].
  /// Returns null if our keypair is missing.
  static Future<Uint8List?> deriveSharedSecret(
    String myUid,
    String theirPublicKeyB64,
  ) async {
    try {
      final privB64 = await _storage.read(key: _privKey(myUid));
      final pubB64 = await _storage.read(key: _pubKey(myUid));
      if (privB64 == null || pubB64 == null) return null;
      final keyPair = SimpleKeyPairData(
        base64.decode(privB64),
        publicKey: SimplePublicKey(
          base64.decode(pubB64),
          type: KeyPairType.x25519,
        ),
        type: KeyPairType.x25519,
      );
      final sharedKey = await _x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: SimplePublicKey(
          base64.decode(theirPublicKeyB64),
          type: KeyPairType.x25519,
        ),
      );
      return Uint8List.fromList(await sharedKey.extractBytes());
    } catch (_) {
      return null;
    }
  }

  /// Encrypts [plaintext]. Returns base64-encoded `iv` and `ct` (ciphertext+MAC).
  static Future<({String iv, String ct})> encrypt(
    String plaintext,
    Uint8List sharedSecret,
  ) async {
    final secretKey = await _aesGcm.newSecretKeyFromBytes(sharedSecret);
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );
    return (
      iv: base64.encode(box.nonce),
      ct: base64.encode([...box.cipherText, ...box.mac.bytes]),
    );
  }

  /// Decrypts a message. Returns null if decryption fails.
  static Future<String?> decrypt(
    String ivB64,
    String ctB64,
    Uint8List sharedSecret,
  ) async {
    try {
      final secretKey = await _aesGcm.newSecretKeyFromBytes(sharedSecret);
      final raw = base64.decode(ctB64);
      final mac = raw.sublist(raw.length - 16);
      final ct = raw.sublist(0, raw.length - 16);
      final plain = await _aesGcm.decrypt(
        SecretBox(ct, nonce: base64.decode(ivB64), mac: Mac(mac)),
        secretKey: secretKey,
      );
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }
}
