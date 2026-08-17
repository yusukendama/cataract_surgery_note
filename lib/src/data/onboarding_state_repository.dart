import 'package:shared_preferences/shared_preferences.dart';

const currentOnboardingVersion = 1;
const onboardingCompletedVersionKey = 'onboarding_completed_version';

abstract interface class OnboardingStateRepository {
  Future<int?> readCompletedVersion();

  Future<void> writeCompletedVersion(int version);
}

final class SharedPreferencesOnboardingStateRepository
    implements OnboardingStateRepository {
  SharedPreferencesOnboardingStateRepository({
    SharedPreferencesAsync? preferences,
  }) : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<int?> readCompletedVersion() async {
    final version = await _preferences.getInt(onboardingCompletedVersionKey);
    if (version != null && version < 0) {
      throw const FormatException('Invalid onboarding version.');
    }
    return version;
  }

  @override
  Future<void> writeCompletedVersion(int version) {
    if (version < 0) {
      throw ArgumentError.value(version, 'version');
    }
    return _preferences.setInt(onboardingCompletedVersionKey, version);
  }
}
