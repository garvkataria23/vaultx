import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import 'password_vault_service.dart';
import 'audit_log.dart';

class BrowserExtensionService {
  static final BrowserExtensionService instance = BrowserExtensionService._();
  BrowserExtensionService._();

  HttpServer? _server;
  String _pairingPin = '';
  String _sessionToken = '';
  bool _isRunning = false;
  
  PasswordVaultService? _passwordService;
  
  bool get isRunning => _isRunning;
  String get pairingPin => _pairingPin;

  Future<void> start(PasswordVaultService passwordService) async {
    if (_isRunning) return;
    _passwordService = passwordService;
    
    // Generate secure pairing PIN and Token
    _pairingPin = (100000 + DateTime.now().microsecondsSinceEpoch % 900000).toString();
    _sessionToken = base64Encode(sha256.convert(utf8.encode(_pairingPin + DateTime.now().toString())).bytes);

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
      _isRunning = true;
      debugPrint('BROWSER_EXT: Server running on ws://${_server!.address.address}:${_server!.port}/ws');
      
      _server!.listen((HttpRequest request) {
        if (request.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocketTransformer.upgrade(request).then(_handleWebSocket);
        } else {
          request.response
            ..statusCode = HttpStatus.forbidden
            ..close();
        }
      });
      await AuditLog.write('Browser extension bridge started');
    } catch (e) {
      debugPrint('BROWSER_EXT ERROR: $e');
      _isRunning = false;
    }
  }

  Future<void> stop() async {
    if (!_isRunning) return;
    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
    _passwordService = null;
    await AuditLog.write('Browser extension bridge stopped');
  }

  void _handleWebSocket(WebSocket webSocket) {
    debugPrint('BROWSER_EXT: WebSocket connected');
    bool isAuthorized = false;

    webSocket.listen((data) async {
      try {
        final Map<String, dynamic> msg = jsonDecode(data as String);
        final type = msg['type'] as String?;

        if (type == 'pair') {
          final pin = msg['pin'] as String?;
          if (pin == _pairingPin) {
            isAuthorized = true;
            webSocket.add(jsonEncode({'type': 'paired', 'token': _sessionToken}));
            await AuditLog.write('Pair success: Browser Extension');
          } else {
            webSocket.add(jsonEncode({'type': 'pair_failed', 'error': 'Invalid PIN'}));
            await AuditLog.write('Pair failed: Invalid PIN');
          }
        } 
        else if (type == 'auth') {
          final token = msg['token'] as String?;
          if (token == _sessionToken) {
            isAuthorized = true;
          } else {
            webSocket.add(jsonEncode({'type': 'auth_failed'}));
          }
        }
        else if (type == 'get_credentials') {
          if (!isAuthorized) return;
          if (msg['token'] != _sessionToken) return;

          final domain = msg['domain'] as String?;
          if (domain == null || _passwordService == null) return;

          await AuditLog.write('Autofill detected for domain: $domain');
          
          final entries = await _passwordService!.loadActiveEntries();
          final matches = entries.where((e) {
            if (e.url.isEmpty) return false;
            final entryDomain = e.url.replaceAll(RegExp(r'https?://'), '').split('/').first;
            return entryDomain == domain || domain.endsWith('.$entryDomain') || entryDomain.endsWith('.$domain');
          }).toList();

          if (matches.isNotEmpty) {
            await AuditLog.write('Credential matched for $domain');
          }

          final credentials = matches.map((e) => {
            'username': e.username,
            'password': e.password,
            'serviceName': e.serviceName
          }).toList();

          webSocket.add(jsonEncode({
            'type': 'credentials',
            'domain': domain,
            'credentials': credentials
          }));
        }
      } catch (e) {
        debugPrint('BROWSER_EXT WS ERROR: $e');
      }
    }, onDone: () {
      debugPrint('BROWSER_EXT: WebSocket disconnected');
    });
  }
}