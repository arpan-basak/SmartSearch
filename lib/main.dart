import 'package:flutter/material.dart';
import 'package:smart_search_app/app/bootstrap.dart';

/// Render the usable shell before initializing plugins or loading data.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartSearchBootstrap());
}
