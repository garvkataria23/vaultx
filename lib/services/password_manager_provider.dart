import 'package:flutter/foundation.dart';
import 'password_vault_service.dart';
import 'audit_log.dart';

/// Provider for managing Password Manager state and visibility.
/// Ensures the Password Manager is initialized and accessible by default.
class PasswordManagerProvider extends ChangeNotifier {
  PasswordVaultService? _service;
  bool _initialized = false;

  bool get isInitialized => _initialized;
  PasswordVaultService? get service => _service;

  /// Initializes the provider with a [PasswordVaultService].
  /// Called when the vault is unlocked.
  void initialize(PasswordVaultService service) {
    _service = service;
    _initialized = true;
    
    AuditLog.write('PASSWORD_MANAGER_INITIALIZED');
    
    if (service.entryCount == 0) {
      AuditLog.write('EMPTY_PASSWORD_VAULT_CREATED');
    }
    
    notifyListeners();
  }

  void notifyImportSuccess() {
    AuditLog.write('PASSWORD_IMPORT_SUCCESS');
    notifyListeners();
  }

  void clear() {
    _service = null;
    _initialized = false;
    notifyListeners();
  }
}
