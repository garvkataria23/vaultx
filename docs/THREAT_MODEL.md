# VaultX Threat Model

## Security Goals

- Keep notes, attachments, voice recordings, and metadata local-first.
- Store only encrypted note records and encrypted blobs at rest.
- Derive vault access keys from user credentials with Argon2id for new vaults.
- Use authenticated encryption for new records and blobs.
- Prevent casual disclosure through screenshots, recent-app previews, clipboard residue, and weak PIN brute force.

## In Scope

- Lost or borrowed device while VaultX is locked
- Local storage inspection without the master password
- Backup file disclosure without the correct vault credential
- Forced-access pressure mitigated by decoy mode and hidden vault
- Accidental disclosure through clipboard, screenshots, or app backgrounding
- Google Drive backup: ciphertext-only upload; Google never sees plaintext or keys

## Out of Scope

- A fully compromised operating system with live memory access
- Malware with accessibility privileges reading the screen while unlocked
- Hardware forensic attacks against flash wear-leveling
- Coerced disclosure of the real master password
- Google account compromise (mitigated by zero-knowledge encryption; attacker still needs vault password)

## Important Residual Risks

- Best-effort memory wiping in Dart cannot guarantee compiler/runtime elimination of all copies.
- Best-effort secure delete cannot guarantee erasure on flash storage due to wear leveling.
- Root and debugger checks are advisory signals, not proof of device integrity.
- No claim of independent audit should be made until a third-party review is completed.
