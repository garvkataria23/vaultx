import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Flutter-side wrapper around the official MEGA Android SDK via MethodChannel.
class MegaSdkService {
  static const _channel = MethodChannel('vaultx/mega');

  MegaSdkService._();
  static final MegaSdkService instance = MegaSdkService._();

  /// Login with email and password via the official SDK.
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final result = await _channel.invokeMethod('login', {
        'email': email,
        'password': password,
      });
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Logout and clear session.
  Future<Map<String, dynamic>> logout() async {
    try {
      final result = await _channel.invokeMethod('logout');
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Restore a previously saved session.
  Future<Map<String, dynamic>> restoreSession() async {
    try {
      final result = await _channel.invokeMethod('restoreSession');
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Fetch remote nodes (required after login/restoreSession).
  Future<Map<String, dynamic>> fetchNodes() async {
    try {
      final result = await _channel.invokeMethod('fetchNodes');
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Ensure the VaultX_Backups folder exists, creating it if missing.
  Future<Map<String, dynamic>> ensureBackupFolder() async {
    try {
      final result = await _channel.invokeMethod('ensureBackupFolder');
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// List all backup files in the VaultX_Backups folder.
  Future<Map<String, dynamic>> listBackupFiles() async {
    try {
      final result = await _channel.invokeMethod('listBackupFiles');
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Upload a file to the backup folder.
  Future<Map<String, dynamic>> uploadFile({
    required List<int> bytes,
    required String fileName,
  }) async {
    try {
      final dataBase64 = base64Encode(bytes);
      final result = await _channel.invokeMethod('uploadFile', {
        'data': dataBase64,
        'fileName': fileName,
      });
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Download a file by its base64 handle.
  Future<Map<String, dynamic>> downloadFile(String handle) async {
    try {
      final result = await _channel.invokeMethod('downloadFile', {
        'handle': handle,
      });
      final map = Map<String, dynamic>.from(result);
      if (map['success'] == true && map['data'] != null) {
        map['bytes'] = base64Decode(map['data'] as String);
      }
      return map;
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Delete a node by its base64 handle.
  Future<Map<String, dynamic>> deleteNode(String handle) async {
    try {
      final result = await _channel.invokeMethod('deleteNode', {
        'handle': handle,
      });
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Get account storage quota.
  Future<Map<String, dynamic>> getAccountQuota() async {
    try {
      final result = await _channel.invokeMethod('getAccountQuota');
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'Platform error'};
    }
  }

  /// Get the email of the currently logged-in user.
  Future<String?> getSessionEmail() async {
    try {
      return await _channel.invokeMethod('getSessionEmail') as String?;
    } on PlatformException {
      return null;
    }
  }

  /// Check if a user is currently logged in.
  Future<bool> isLoggedIn() async {
    try {
      final result = await _channel.invokeMethod('isLoggedIn');
      return result == true;
    } on PlatformException {
      return false;
    }
  }
}
