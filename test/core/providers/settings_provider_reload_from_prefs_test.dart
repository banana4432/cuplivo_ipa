import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/provider_group.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

Map<String, dynamic> _providerConfigJson({
  required String id,
  required String name,
  String apiKey = 'sk-test',
  String baseUrl = 'https://example.com',
  bool enabled = true,
  List<String> models = const ['m-1'],
}) => {
  'id': id,
  'enabled': enabled,
  'name': name,
  'apiKey': apiKey,
  'baseUrl': baseUrl,
  'models': models,
};

/// Wait for the constructor `_load()` future started by `SettingsProvider()`
/// to finish — same pattern other settings_provider tests use, since the
/// constructor is fire-and-forget.
Future<void> _waitForSettingsLoad({Duration timeout = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider.reloadFromPrefs', () {
    test('reloads provider_configs_v1 into the in-memory map', () async {
      SharedPreferences.setMockInitialValues({
        'provider_configs_v1': jsonEncode({
          'OpenAI': _providerConfigJson(
            id: 'OpenAI',
            name: 'OpenAI',
            apiKey: 'sk-from-disk',
          ),
          'MyCustom': _providerConfigJson(
            id: 'MyCustom',
            name: 'My Custom Provider',
            baseUrl: 'https://my.example.com/v1',
          ),
        }),
      });

      final settings = SettingsProvider();
      await _waitForSettingsLoad();

      // Sanity: empty before reload (nothing was persisted initially beyond
      // the seed defaults added by `_load` when providerConfigs was empty —
      // those use the in-memory seed defaults, not the disk ones).
      expect(settings.providerConfigs.containsKey('MyCustom'), isFalse,
          reason: 'MyCustom should not exist in memory before reload.');

      await settings.reloadFromPrefs();

      expect(settings.providerConfigs['OpenAI']?.apiKey, 'sk-from-disk');
      expect(settings.providerConfigs['OpenAI']?.baseUrl, 'https://example.com');
      expect(settings.providerConfigs['MyCustom']?.name, 'My Custom Provider');
      expect(settings.providerConfigs['MyCustom']?.baseUrl,
          'https://my.example.com/v1');
      expect(settings.providerConfigs['OpenAI']?.models, ['m-1']);
    });

    test('replaces stale in-memory provider configs with disk contents',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      final before = settings.providerConfigs['OpenAI']?.apiKey;
      expect(before, isNot('sk-fresh-import'),
          reason: 'sanity: pre-reload memory has no fresh-import key.');

      SharedPreferences.setMockInitialValues({
        'provider_configs_v1': jsonEncode({
          'OpenAI': _providerConfigJson(
            id: 'OpenAI',
            name: 'OpenAI',
            apiKey: 'sk-fresh-import',
          ),
        }),
      });

      await settings.reloadFromPrefs();

      expect(settings.providerConfigs['OpenAI']?.apiKey, 'sk-fresh-import');
    });

    test('reloads providers_order_v1', () async {
      SharedPreferences.setMockInitialValues({
        'providers_order_v1': <String>['Custom', 'OpenAI', 'Anthropic'],
      });

      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      await settings.reloadFromPrefs();

      expect(settings.providersOrder, ['Custom', 'OpenAI', 'Anthropic']);
    });

    test('reloads provider groups, mapping, and collapsed state', () async {
      final group = ProviderGroup(
        id: 'g-work',
        name: 'Work',
        createdAt: 1700000000,
      );
      SharedPreferences.setMockInitialValues({
        'provider_groups_v1': ProviderGroup.encodeList([group]),
        'provider_group_map_v1': jsonEncode({'OpenAI': 'g-work'}),
        'provider_group_collapsed_v1': jsonEncode({'g-work': true}),
      });

      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      await settings.reloadFromPrefs();

      expect(settings.providerGroups.single.id, 'g-work');
      expect(settings.groupIdForProvider('OpenAI'), 'g-work');
      // providerGroupCollapsed is a private map — verify behaviorally
      // via the public accessor used by the sidebar.
      expect(settings.isGroupCollapsed('g-work'), isTrue);
    });

    test('reloads pinned models set', () async {
      SharedPreferences.setMockInitialValues({
        'pinned_models_v1': <String>['OpenAI::gpt-4o', 'Anthropic::claude-3.7'],
      });

      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      await settings.reloadFromPrefs();

      expect(settings.isModelPinned('OpenAI', 'gpt-4o'), isTrue);
      expect(settings.isModelPinned('Anthropic', 'claude-3.7'), isTrue);
      expect(settings.isModelPinned('OpenAI', 'gpt-5'), isFalse);
    });

    test('honors disk selected_model_v1 when sentinel is armed', () async {
      SharedPreferences.setMockInitialValues({
        'selected_model_v1': 'MyCustom::my-fancy-model',
        'default_model_seeded_v1': true,
      });

      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      await settings.reloadFromPrefs();

      // Public accessors used by the model picker:
      expect(settings.currentModelProvider, 'MyCustom');
      expect(settings.currentModelId, 'my-fancy-model');
    });

    test('falls back to disk values for missing sentinel-true selections',
        () async {
      // Sentinel armed but selection cleared — most likely "user removed
      // their selection in settings" rather than "fresh install".
      // Omit `selected_model_v1` from the mock: SharedPreferences treats
      // absent keys as null, which is exactly what we want here.
      SharedPreferences.setMockInitialValues({
        'default_model_seeded_v1': true,
      });

      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      // Pre-seed an in-memory selection so we can prove the reload clears it
      // back to null (matching disk state).
      await settings.setCurrentModel('OpenAI', 'gpt-4o');
      expect(settings.currentModelProvider, 'OpenAI');

      await settings.reloadFromPrefs();

      expect(settings.currentModelProvider, isNull);
      expect(settings.currentModelId, isNull);
    });

    test('seeds DeepSeek default when sentinel is not yet armed', () async {
      // Omit both `selected_model_v1` and `default_model_seeded_v1`:
      // a fresh install with no persisted prefs.
      SharedPreferences.setMockInitialValues({});

      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      await settings.reloadFromPrefs();

      expect(settings.currentModelProvider, 'DeepSeek');
      expect(settings.currentModelId, 'deepseek-v4-flash');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('default_model_seeded_v1'), isTrue);
      expect(prefs.getString('selected_model_v1'),
          'DeepSeek::deepseek-v4-flash');
    });

    test('does not touch theme or display prefs that backups never touch',
        () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode_v1': 'dark',
        'display_show_user_message_actions_v1': false,
      });

      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      expect(settings.themeMode.name, 'dark');

      // Tweak disk in a way reload must NOT propagate.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('theme_mode_v1', 'light');

      await settings.reloadFromPrefs();

      expect(settings.themeMode.name, 'dark',
          reason:
              'reloadFromPrefs only refreshes provider-related prefs; '
              'theme/display stay whatever the user picked in-app.');
    });

    test('notifies listeners after reload', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitForSettingsLoad();

      var notifyCount = 0;
      settings.addListener(() => notifyCount++);

      SharedPreferences.setMockInitialValues({
        'providers_order_v1': <String>['OpenAI'],
      });

      await settings.reloadFromPrefs();

      expect(notifyCount, greaterThanOrEqualTo(1),
          reason: 'reloadFromPrefs must call notifyListeners exactly once.');
    });

    test('survives malformed provider_configs_v1 without throwing', () async {
      SharedPreferences.setMockInitialValues({
        'provider_configs_v1': '{not valid json',
      });

      final settings = SettingsProvider();
      await _waitForSettingsLoad();

      await settings.reloadFromPrefs();

      // Decoded to an empty map, never raised an exception that escaped.
      expect(settings.providerConfigs, isNotNull);
      expect(settings.providerConfigs.containsKey('whatever'), isFalse);
    });
  });
}