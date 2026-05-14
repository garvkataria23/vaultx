import 'dart:typed_data';

/// The three vault modes the app can operate in.
enum VaultKind {
  /// Real vault — normal usage.
  main,

  /// A separate encrypted vault behind a different password.
  /// Completely invisible to the main vault.
  hidden,

  /// Fake empty vault shown under coercion.
  /// No real notes are ever stored or shown.
  decoy,
}

/// Result of an authentication attempt.
///
/// States:
///   • pending  — masterKey unwrapped but HMAC not yet verified (verify() not called)
///   • ok=true  — verified and ready to open vault
///   • ok=false — wrong credential or other failure
///   • decoy    — special case: ok=true, kind=decoy, masterKey=null
class AuthResult {
  const AuthResult._({
    required this.ok,
    required this.kind,
    this.masterKey,
    this.verifierKey,
    this.error,
  });

  final bool ok;
  final VaultKind kind;
  final Uint8List? masterKey;

  /// The Hive/secure-storage key whose value is the HMAC we verify against.
  final String? verifierKey;
  final String? error;

  // ── Factories ──────────────────────────────────────────────────────────────

  /// Intermediate state: key unwrapped, pending HMAC verification.
  factory AuthResult.pending(
    Uint8List masterKey,
    String verifierKey,
    VaultKind kind,
  ) => AuthResult._(
    ok: false,
    kind: kind,
    masterKey: masterKey,
    verifierKey: verifierKey,
  );

  /// Wrong password / crypto failure.
  factory AuthResult.failure(String error) =>
      AuthResult._(ok: false, kind: VaultKind.main, error: error);

  /// Decoy vault: no real key needed, immediately ok.
  factory AuthResult.decoy() =>
      const AuthResult._(ok: true, kind: VaultKind.decoy);

  // ── Helpers ────────────────────────────────────────────────────────────────

  AuthResult copyWith({bool? ok, String? error}) => AuthResult._(
    ok: ok ?? this.ok,
    kind: kind,
    masterKey: masterKey,
    verifierKey: verifierKey,
    error: error ?? this.error,
  );
}
