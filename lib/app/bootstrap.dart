import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:smart_search_app/app/app.dart';
import 'package:smart_search_app/features/account/data/account_sync.dart';
import 'package:smart_search_app/features/account/data/firebase_config.dart';

class SmartSearchBootstrap extends StatefulWidget {
  const SmartSearchBootstrap({super.key});

  @override
  State<SmartSearchBootstrap> createState() => _SmartSearchBootstrapState();
}

class _SmartSearchBootstrapState extends State<SmartSearchBootstrap> {
  AccountSync? _accountSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      if (mounted) unawaited(_initializeAccountSync());
    });
  }

  Future<void> _initializeAccountSync() async {
    try {
      if (FirebaseConfig.isConfigured) {
        await Firebase.initializeApp(options: FirebaseConfig.options);
      } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        // The Google Services Gradle plugin supplies the Android Firebase
        // options from android/app/google-services.json.
        await Firebase.initializeApp();
      } else {
        return;
      }
      if (mounted) setState(() => _accountSync = AccountSync());
    } on FirebaseException catch (error) {
      debugPrint('Firebase initialization failed: ${error.code}');
    }
  }

  @override
  Widget build(BuildContext context) =>
      SmartSearchApp(accountSync: _accountSync, enableOnboarding: true);
}
