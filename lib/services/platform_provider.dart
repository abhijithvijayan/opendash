import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_platform_service.dart';
import 'mock_platform_service.dart';
import 'platform_service.dart';

final platformServiceProvider = Provider<PlatformService>((ref) => defaultPlatformService());

/// The real channel on Android, the mock everywhere else (and in tests).
PlatformService defaultPlatformService() {
  if (kIsWeb || !_isAndroid) return MockPlatformService();
  return DevicePlatformService();
}

bool get _isAndroid {
  try {
    return defaultTargetPlatform == TargetPlatform.android;
  } catch (_) {
    return false;
  }
}
