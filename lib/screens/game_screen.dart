import 'package:flutter/material.dart';
import '../game/connectx/main.dart';

class VaultXGameScreen extends StatefulWidget {
  const VaultXGameScreen({super.key});

  @override
  State<VaultXGameScreen> createState() => _VaultXGameScreenState();
}

class _VaultXGameScreenState extends State<VaultXGameScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // We return the game entry point directly.
    // ConnectXMain handles its own theme and internal navigation.
    // Removed nested MaterialApp to prevent navigation and state issues.
    return const ConnectXMain();
  }
}
