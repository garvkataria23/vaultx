import 'package:flutter/material.dart';
import 'navigation_service.dart';

enum AIIntent {
  openHome,
  goDrive,
  openSecurity,
  openSettings,
  openGame,
  unknown,
}

class IntentParser {
  static AIIntent parse(String query) {
    final lower = query.toLowerCase();
    
    if (lower.contains('home')) return AIIntent.openHome;
    if (lower.contains('drive')) return AIIntent.goDrive;
    if (lower.contains('security')) return AIIntent.openSecurity;
    if (lower.contains('settings')) return AIIntent.openSettings;
    if (lower.contains('game')) return AIIntent.openGame;
    
    return AIIntent.unknown;
  }
}

class ActionExecutor {
  static Future<bool> execute(BuildContext context, AIIntent intent, {Map<String, dynamic>? arguments}) async {
    String? route;
    
    switch (intent) {
      case AIIntent.openHome:
        route = NavigationService.routeHome;
        break;
      case AIIntent.goDrive:
        route = NavigationService.routeDrive;
        break;
      case AIIntent.openSecurity:
        route = NavigationService.routeSecurity;
        break;
      case AIIntent.openSettings:
        route = NavigationService.routeSettings;
        break;
      case AIIntent.openGame:
        route = NavigationService.routeGame;
        break;
      case AIIntent.unknown:
        return false;
    }
    
    // Since AIIntent.unknown returns false early, route is guaranteed to be non-null here.
    await NavigationService.navigateTo(context, route, arguments: arguments);
    return true;
  }
}
