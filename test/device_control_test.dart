// Unit tests for the Dart models that back the ViHealth-parity
// device-control API (`syncTime`, `connectKnown`, `getBattery`,
// `getDeviceConfig` / `setDeviceConfig`).
//
// These tests fix the wire-format contract between the native plugins
// and Dart consumers — if the iOS or Android emitter changes a key
// name (e.g. drops `family` from a battery event) these will fail
// loudly and tell you which side to fix.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ble_devices/flutter_ble_devices.dart';

void main() {
  group('BatteryInfo.fromMap', () {
    test('parses an iOS-style URAT battery event', () {
      final map = <String, dynamic>{
        'event': 'battery',
        'family': 'bp2',
        'model': 2,
        'state': 1, // charging
        'percent': 82,
        'voltage': 4023,
      };
      final battery = BatteryInfo.fromMap(map);
      expect(battery.family, 'bp2');
      expect(battery.model, 2);
      expect(battery.state, 1);
      expect(battery.percent, 82);
      expect(battery.voltageMv, 4023);
      expect(battery.batLevel, isNull);
    });

    test('accepts the legacy deviceFamily key when family is missing', () {
      // Pre-1.0 events used `deviceFamily` for the family name. The
      // model keeps both readable so a stale native build (e.g. AAR
      // pinned to an older plugin version) still produces a usable
      // event during the upgrade transition.
      final map = <String, dynamic>{
        'event': 'battery',
        'deviceFamily': 'oxy',
        'percent': 55,
      };
      final battery = BatteryInfo.fromMap(map);
      expect(battery.family, 'oxy');
      expect(battery.percent, 55);
      expect(battery.model, -1, reason: 'unknown model defaults to -1');
    });

    test('defaults family to "unknown" when neither key is present', () {
      final battery = BatteryInfo.fromMap(<String, dynamic>{});
      expect(battery.family, 'unknown');
      expect(battery.percent, isNull);
      expect(battery.batLevel, isNull);
    });

    test('preserves PF10AW1 batLevel separately from percent', () {
      // The PF10AW1 / FOxi family reports battery as a coarse 0..3
      // enum, not a percent. Both fields are kept distinct so the
      // consumer can render the right pill.
      final battery = BatteryInfo.fromMap(<String, dynamic>{
        'family': 'pf10aw1',
        'model': 8226,
        'batLevel': 2,
      });
      expect(battery.batLevel, 2);
      expect(battery.percent, isNull);
    });
  });

  group('DeviceConfigEvent.fromMap', () {
    test('strips control keys into the typed fields, keeps the rest', () {
      final map = <String, dynamic>{
        'event': 'deviceConfig',
        'family': 'bp2',
        'model': 2,
        'calibZero': 3450,
        'calibSlope': 14500,
        'volume': 2,
        'avgMeasureMode': 3,
        'unit': 0,
        'language': 1,
      };
      final cfg = DeviceConfigEvent.fromMap(map);
      expect(cfg.family, 'bp2');
      expect(cfg.model, 2);
      // Control keys should NOT leak into `fields`.
      expect(cfg.fields.containsKey('event'), isFalse);
      expect(cfg.fields.containsKey('family'), isFalse);
      expect(cfg.fields.containsKey('model'), isFalse);
      // Payload keys should be present verbatim.
      expect(cfg.fields['calibZero'], 3450);
      expect(cfg.fields['volume'], 2);
      expect(cfg.volume, 2);
    });

    test('convenience getters traverse alternate field names per family', () {
      final woxi = DeviceConfigEvent.fromMap(<String, dynamic>{
        'family': 'woxi',
        'spo2Thr': 88,
        'hrThrLow': 50,
        'hrThrHigh': 120,
        'buzzer': 40,
      });
      // WOxi uses spo2Thr / hrThrLow / hrThrHigh / buzzer.
      expect(woxi.spo2Threshold, 88);
      expect(woxi.pulseRateLow, 50);
      expect(woxi.pulseRateHigh, 120);
      expect(woxi.volume, 40, reason: 'buzzer is the WOxi volume control');

      final foxi = DeviceConfigEvent.fromMap(<String, dynamic>{
        'family': 'foxi',
        'spo2Low': 90,
        'prLow': 45,
        'prHigh': 150,
      });
      // FOxi uses spo2Low / prLow / prHigh.
      expect(foxi.spo2Threshold, 90);
      expect(foxi.pulseRateLow, 45);
      expect(foxi.pulseRateHigh, 150);
    });

    test('handles missing payload gracefully', () {
      final cfg = DeviceConfigEvent.fromMap(<String, dynamic>{
        'event': 'deviceConfig',
      });
      expect(cfg.family, 'unknown');
      expect(cfg.fields, isEmpty);
      expect(cfg.volume, isNull);
      expect(cfg.spo2Threshold, isNull);
    });
  });

  group('ConfigField.toMap', () {
    test('produces the wire format the native bridges expect', () {
      const field = ConfigField('spo2Thr', 88);
      expect(field.toMap(), {'name': 'spo2Thr', 'value': 88});
    });

    test('passes booleans through unchanged for BP2 soundOn', () {
      const field = ConfigField('soundOn', true);
      final map = field.toMap();
      expect(map['name'], 'soundOn');
      expect(map['value'], isTrue);
    });
  });

  group('ScaleUserProfile round-trip', () {
    test('toMap → fromMap preserves every field', () {
      const original = ScaleUserProfile(
        userIndex: 3,
        userId: 42,
        nickName: 'Richie',
        heightCm: 178,
        age: 34,
        sex: ScaleSex.male,
        lastWeightKg: 72.4,
        peopleType: ScalePeopleType.athlete,
        weightUnit: ScaleWeightUnit.lb,
        rulerUnit: ScaleRulerUnit.inch,
        kitchenUnit: KitchenScaleUnit.oz,
        enableImpedance: false,
        enableHeartRate: true,
        enableBalance: false,
        enableGravity: true,
      );
      final round = ScaleUserProfile.fromMap(original.toMap());
      expect(round.userIndex, original.userIndex);
      expect(round.userId, original.userId);
      expect(round.nickName, original.nickName);
      expect(round.heightCm, original.heightCm);
      expect(round.age, original.age);
      expect(round.sex, original.sex);
      expect(round.lastWeightKg, closeTo(original.lastWeightKg, 1e-6));
      expect(round.peopleType, original.peopleType);
      expect(round.weightUnit, original.weightUnit);
      expect(round.rulerUnit, original.rulerUnit);
      expect(round.kitchenUnit, original.kitchenUnit);
      expect(round.enableImpedance, original.enableImpedance);
      expect(round.enableHeartRate, original.enableHeartRate);
      expect(round.enableBalance, original.enableBalance);
      expect(round.enableGravity, original.enableGravity);
    });

    test('toMap pins ICRulerUnit to the 1-indexed wire value', () {
      // ICRulerUnit upstream is `cm=1, inch=2, ftInch=3`. Our enum is
      // 0-indexed but `.wire` (and `toMap()`) must produce 1-indexed
      // values — otherwise the iOS/Android plugins would set the
      // wrong unit on the device.
      const profile = ScaleUserProfile(rulerUnit: ScaleRulerUnit.cm);
      expect(profile.toMap()['rulerUnit'], 1);
      const profileFt = ScaleUserProfile(rulerUnit: ScaleRulerUnit.ftInch);
      expect(profileFt.toMap()['rulerUnit'], 3);
    });

    test('fromMap tolerates a partial payload (older firmware)', () {
      // Older scale firmware may omit nickName / measurement-flag
      // fields. fromMap should land on documented defaults rather
      // than throw, so a Dart consumer can still render the profile.
      final profile = ScaleUserProfile.fromMap({
        'userIndex': 2,
        'heightCm': 165,
        'age': 28,
        'sex': 2, // female
      });
      expect(profile.userIndex, 2);
      expect(profile.heightCm, 165);
      expect(profile.sex, ScaleSex.female);
      expect(profile.nickName, isNull);
      expect(profile.peopleType, ScalePeopleType.normal);
      expect(profile.weightUnit, ScaleWeightUnit.kg);
      expect(
        profile.enableImpedance,
        isTrue,
        reason:
            'measurement flags default to true to match the iOS '
            'plugin behaviour when initialising _currentUserInfo',
      );
    });

    test('enum fromWire helpers clamp out-of-range values to defaults', () {
      // Forward-compat — if a future plugin adds e.g. ICWeightUnitOz
      // before the Dart side learns about it, fromWire must NOT throw.
      expect(ScaleWeightUnit.fromWire(99), ScaleWeightUnit.kg);
      expect(ScaleWeightUnit.fromWire(-1), ScaleWeightUnit.kg);
      expect(
        ScaleRulerUnit.fromWire(0),
        ScaleRulerUnit.cm,
        reason: 'wire 0 is out of range (ICRulerUnit is 1-indexed)',
      );
      expect(KitchenScaleUnit.fromWire(99), KitchenScaleUnit.g);
      expect(ScaleSex.fromWire(99), ScaleSex.unknown);
      expect(ScalePeopleType.fromWire(99), ScalePeopleType.normal);
    });
  });

  group('BlePermissionState.fromWire', () {
    test('maps every documented native string to the matching enum', () {
      expect(
        BlePermissionState.fromWire('granted'),
        BlePermissionState.granted,
      );
      expect(BlePermissionState.fromWire('denied'), BlePermissionState.denied);
      expect(
        BlePermissionState.fromWire('poweredOff'),
        BlePermissionState.poweredOff,
      );
      expect(
        BlePermissionState.fromWire('unsupported'),
        BlePermissionState.unsupported,
      );
      expect(
        BlePermissionState.fromWire('notDetermined'),
        BlePermissionState.notDetermined,
      );
    });

    test('falls back to notDetermined for unknown / null payloads', () {
      // A forward-compatible plugin that introduces e.g. "restricted"
      // should not blow up an older Dart consumer; it should land on
      // notDetermined, the safe default.
      expect(
        BlePermissionState.fromWire(null),
        BlePermissionState.notDetermined,
      );
      expect(BlePermissionState.fromWire(''), BlePermissionState.notDetermined);
      expect(
        BlePermissionState.fromWire('restricted'),
        BlePermissionState.notDetermined,
      );
    });
  });
}
