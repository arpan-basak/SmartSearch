import 'package:flutter/services.dart';

/// Wire name shared with Android MainActivity and platform contract tests.
/// Creating the channel performs no native work; invoke it only after the
/// first rasterized frame or in response to an explicit user action.
const searchPlatformChannel = MethodChannel('smart_search/apps');
