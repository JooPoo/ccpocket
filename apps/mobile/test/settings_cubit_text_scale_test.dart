import 'package:ccpocket/features/settings/state/settings_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsCubit text scale', () {
    test('defaults to 100 percent and persists app scale', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cubit = SettingsCubit(prefs);

      expect(cubit.state.textScale, 1.0);

      cubit.setTextScale(0.9);

      expect(cubit.state.textScale, 0.9);
      expect(prefs.getDouble('settings_text_scale'), 0.9);

      await cubit.close();

      final restored = SettingsCubit(prefs);
      expect(restored.state.textScale, 0.9);

      await restored.close();
    });

    test('clamps text scale to the supported compact range', () async {
      SharedPreferences.setMockInitialValues({'settings_text_scale': 0.5});
      final prefs = await SharedPreferences.getInstance();
      final cubit = SettingsCubit(prefs);

      expect(cubit.state.textScale, SettingsCubit.minTextScale);

      cubit.setTextScale(1.2);
      expect(cubit.state.textScale, SettingsCubit.maxTextScale);

      cubit.setTextScale(0.5);
      expect(cubit.state.textScale, SettingsCubit.minTextScale);

      await cubit.close();
    });

    test('persists auto rename setting', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cubit = SettingsCubit(prefs);

      expect(cubit.state.autoRenameSessions, isTrue);

      cubit.setAutoRenameSessions(false);

      expect(cubit.state.autoRenameSessions, isFalse);
      expect(prefs.getBool('autoRenameSessions'), isFalse);

      await cubit.close();

      final restored = SettingsCubit(prefs);
      expect(restored.state.autoRenameSessions, isFalse);

      await restored.close();
    });
  });
}
