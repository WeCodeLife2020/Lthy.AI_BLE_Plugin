// Multi-user picker tests for the LeScale F4 controller.
//
// `LescaleController` keeps its profile state in static fields so the
// patient-app side (where there's exactly one logged-in scale at a
// time) doesn't have to thread an instance through. The tests reset
// that state at the top of every group so they remain order-
// independent.

import 'package:flutter_ble_devices/flutter_ble_devices.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reset shared static state between tests so each one runs from a
/// clean slate. Mirrors what would happen on a fresh app launch.
void _resetController() {
  LescaleController.setProfiles(const []);
  LescaleController.selectProfile(null);
  LescaleController.autoPickToleranceKg = 5.0;
}

void main() {
  group('LescaleUserProfile.fromFamilyMember', () {
    test('round-trips a fully-populated FamilyMember.toJson() map', () {
      // Mirror the exact shape `FamilyMember.toJson()` emits in the
      // patient app — id/name/dob/gender/weightKg/heightCm.
      final p = LescaleUserProfile.fromFamilyMember({
        'id': 'mem-123',
        'name': 'Alice Example',
        'dob': '1990-06-15',
        'gender': 'female',
        'weightKg': 62.4,
        'heightCm': 167.0,
      })!;
      expect(p.id, 'mem-123');
      expect(p.name, 'Alice Example');
      expect(p.heightCm, 167.0);
      expect(p.isMale, isFalse);
      expect(p.expectedWeightKg, 62.4);
      // Age is derived from dob (1990-06-15) against today.
      // Tests run during 2026 so age should be 35 or 36 depending on
      // the day-of-year — accept the inclusive range.
      expect(p.age, inInclusiveRange(34, 40));
    });

    test('biometric override beats both family fields and defaults', () {
      // FamilyMember height/dob/gender are present but the per-member
      // MemberBiometricProfile is the canonical source of truth.
      final p = LescaleUserProfile.fromFamilyMember(
        {
          'id': 'x',
          'name': 'Bob',
          'dob': '1980-01-01',
          'gender': 'male',
          'weightKg': 100.0,
          'heightCm': 165.0,
        },
        biometric: {
          'heightCm': 182.5,
          'age': 30,
          'isMale': false,
          'targetWeightKg': 75.0,
        },
      )!;
      expect(p.heightCm, 182.5);
      expect(p.age, 30);
      expect(p.isMale, isFalse);
      expect(p.expectedWeightKg, 75.0);
    });

    test('falls back to defaults when fields are missing', () {
      // Bare-minimum record: only id + name set. Everything else
      // defaults so the BIA math still runs.
      final p = LescaleUserProfile.fromFamilyMember({
        'id': 'm',
        'name': 'Anon',
      })!;
      expect(p.heightCm, 170.0);
      expect(p.age, 25);
      expect(p.isMale, isTrue);
      expect(p.expectedWeightKg, isNull);
    });

    test('returns null on missing id / name', () {
      expect(LescaleUserProfile.fromFamilyMember(const {}), isNull);
      expect(
        LescaleUserProfile.fromFamilyMember({'id': 'x'}),
        isNull,
      );
      expect(
        LescaleUserProfile.fromFamilyMember({'name': 'Anon'}),
        isNull,
      );
      // Whitespace-only name is treated as empty.
      expect(
        LescaleUserProfile.fromFamilyMember({'id': 'x', 'name': '  '}),
        isNull,
      );
    });

    test('"other" gender falls back to default isMale=true', () {
      final p = LescaleUserProfile.fromFamilyMember({
        'id': 'x',
        'name': 'NB',
        'gender': 'other',
      })!;
      expect(p.isMale, isTrue);
    });

    test('tolerates int-typed weight/height (pre-decimal cache)', () {
      // Older patient-app cache entries persisted weight/height as
      // ints (before the decimal rollout). FromFamilyMember should
      // coerce them via num.toDouble().
      final p = LescaleUserProfile.fromFamilyMember({
        'id': 'x',
        'name': 'Old',
        'weightKg': 70,    // int, not double
        'heightCm': 175,   // int, not double
      })!;
      expect(p.heightCm, 175.0);
      expect(p.expectedWeightKg, 70.0);
    });
  });

  group('LescaleController auto-pick + manual select', () {
    setUp(_resetController);

    test('falls back to first profile when no expectedWeightKg set', () {
      LescaleController.setProfiles([
        const LescaleUserProfile(
          id: 'a', name: 'Alice', heightCm: 165, age: 30, isMale: false,
        ),
        const LescaleUserProfile(
          id: 'b', name: 'Bob', heightCm: 180, age: 35, isMale: true,
        ),
      ]);
      final p = LescaleController.resolveProfile(measuredWeightKg: 72);
      expect(p.id, 'a');
    });

    test('auto-picks the closest expectedWeightKg within tolerance', () {
      LescaleController.setProfiles(const [
        LescaleUserProfile(
          id: 'mum', name: 'Mum', heightCm: 162, age: 45, isMale: false,
          expectedWeightKg: 58,
        ),
        LescaleUserProfile(
          id: 'dad', name: 'Dad', heightCm: 178, age: 47, isMale: true,
          expectedWeightKg: 82,
        ),
        LescaleUserProfile(
          id: 'kid', name: 'Kid', heightCm: 140, age: 12, isMale: true,
          expectedWeightKg: 38,
        ),
      ]);
      expect(LescaleController.resolveProfile(measuredWeightKg: 60).id, 'mum');
      expect(LescaleController.resolveProfile(measuredWeightKg: 80).id, 'dad');
      expect(LescaleController.resolveProfile(measuredWeightKg: 40).id, 'kid');
    });

    test('falls back to first profile when no candidate is within tolerance',
        () {
      LescaleController.setProfiles(const [
        LescaleUserProfile(
          id: 'dad', name: 'Dad', heightCm: 178, age: 47, isMale: true,
          expectedWeightKg: 82,
        ),
      ]);
      // Measurement is 25 kg off — way outside the default 5 kg
      // tolerance, so the picker returns the first profile rather
      // than misattributing.
      final p = LescaleController.resolveProfile(measuredWeightKg: 50);
      expect(p.id, 'dad');
    });

    test('autoPickToleranceKg is respected', () {
      LescaleController.setProfiles(const [
        LescaleUserProfile(
          id: 'a', name: 'A', heightCm: 170, age: 30, isMale: true,
          expectedWeightKg: 70,
        ),
        LescaleUserProfile(
          id: 'b', name: 'B', heightCm: 170, age: 30, isMale: true,
          expectedWeightKg: 90,
        ),
      ]);
      LescaleController.autoPickToleranceKg = 15.0;
      // Δ=12 vs A, Δ=8 vs B — both within 15 kg, B wins (closer).
      expect(LescaleController.resolveProfile(measuredWeightKg: 82).id, 'b');
      LescaleController.autoPickToleranceKg = 1.0;
      // Now neither is within 1 kg — fallback to first profile.
      expect(LescaleController.resolveProfile(measuredWeightKg: 82).id, 'a');
    });

    test('selectProfile pins one and bypasses auto-pick', () {
      LescaleController.setProfiles(const [
        LescaleUserProfile(
          id: 'mum', name: 'Mum', heightCm: 162, age: 45, isMale: false,
          expectedWeightKg: 58,
        ),
        LescaleUserProfile(
          id: 'dad', name: 'Dad', heightCm: 178, age: 47, isMale: true,
          expectedWeightKg: 82,
        ),
      ]);
      LescaleController.selectProfile('dad');
      expect(LescaleController.pinnedProfileId, 'dad');
      // 58 kg measurement would normally pick mum, but the pin wins.
      expect(LescaleController.resolveProfile(measuredWeightKg: 58).id, 'dad');
      // Clear the pin → back to auto-pick.
      LescaleController.selectProfile(null);
      expect(LescaleController.pinnedProfileId, isNull);
      expect(LescaleController.resolveProfile(measuredWeightKg: 58).id, 'mum');
    });

    test('selectProfile with unknown id is a no-op', () {
      LescaleController.setProfiles(const [
        LescaleUserProfile(
          id: 'a', name: 'A', heightCm: 170, age: 30, isMale: true,
        ),
      ]);
      LescaleController.selectProfile('does-not-exist');
      expect(LescaleController.pinnedProfileId, isNull);
    });

    test('removing the pinned profile auto-clears the pin', () {
      LescaleController.setProfiles(const [
        LescaleUserProfile(
          id: 'a', name: 'A', heightCm: 170, age: 30, isMale: true,
        ),
        LescaleUserProfile(
          id: 'b', name: 'B', heightCm: 175, age: 30, isMale: true,
        ),
      ]);
      LescaleController.selectProfile('a');
      // Re-register a list without 'a' — the pin must clear so future
      // measurements don't silently fall through.
      LescaleController.setProfiles(const [
        LescaleUserProfile(
          id: 'b', name: 'B', heightCm: 175, age: 30, isMale: true,
        ),
      ]);
      expect(LescaleController.pinnedProfileId, isNull);
    });

    test('empty list installs the safety-default profile', () {
      LescaleController.setProfiles(const []);
      expect(LescaleController.profiles.length, 1);
      expect(LescaleController.profiles.first.id, '_default');
      // resolveProfile must still hand back something usable.
      final p = LescaleController.resolveProfile(measuredWeightKg: 70);
      expect(p.id, '_default');
    });

    test('legacy setProfile is back-compat-equivalent to a one-member set',
        () {
      LescaleController.setProfile(heightCm: 168, age: 28, isMale: false);
      expect(LescaleController.profiles.length, 1);
      final only = LescaleController.profiles.single;
      expect(only.id, '_default');
      expect(only.heightCm, 168);
      expect(only.age, 28);
      expect(only.isMale, isFalse);
    });
  });

  group('LescaleController.setProfilesFromFamilyMembers', () {
    setUp(_resetController);

    test('registers one profile per FamilyMember and skips invalid rows',
        () {
      final registered = LescaleController.setProfilesFromFamilyMembers(
        members: [
          {
            'id': 'p-1',
            'name': 'Mum',
            'gender': 'female',
            'heightCm': 162.0,
            'weightKg': 58.0,
            'dob': '1980-03-12',
          },
          {
            'id': 'p-2',
            'name': 'Dad',
            'gender': 'male',
            'heightCm': 178.0,
            'weightKg': 82.0,
            'dob': '1978-11-04',
          },
          // Invalid — missing name; should be skipped silently.
          {'id': 'p-3'},
        ],
      );
      expect(registered, 2);
      expect(LescaleController.profiles.length, 2);
      expect(LescaleController.profiles[0].id, 'p-1');
      expect(LescaleController.profiles[1].id, 'p-2');
      // Auto-pick still works on the registered set.
      expect(LescaleController.resolveProfile(measuredWeightKg: 60).id, 'p-1');
      expect(LescaleController.resolveProfile(measuredWeightKg: 80).id, 'p-2');
    });

    test('activeMemberId moves the matching profile to position [0]', () {
      LescaleController.setProfilesFromFamilyMembers(
        members: [
          {'id': 'a', 'name': 'A', 'heightCm': 170, 'weightKg': 70},
          {'id': 'b', 'name': 'B', 'heightCm': 170, 'weightKg': 70},
          {'id': 'c', 'name': 'C', 'heightCm': 170, 'weightKg': 70},
        ],
        activeMemberId: 'c',
      );
      expect(LescaleController.profiles.first.id, 'c');
      // No hard-pin — auto-pick still wins when weight matches.
      expect(LescaleController.pinnedProfileId, isNull);
    });

    test('activeMemberId == null preserves the original order', () {
      LescaleController.setProfilesFromFamilyMembers(
        members: [
          {'id': 'a', 'name': 'A', 'heightCm': 170},
          {'id': 'b', 'name': 'B', 'heightCm': 170},
        ],
      );
      expect(
        LescaleController.profiles.map((p) => p.id).toList(),
        ['a', 'b'],
      );
    });

    test('unknown activeMemberId is silently ignored (does not reorder)', () {
      LescaleController.setProfilesFromFamilyMembers(
        members: [
          {'id': 'a', 'name': 'A', 'heightCm': 170},
          {'id': 'b', 'name': 'B', 'heightCm': 170},
        ],
        activeMemberId: 'nope',
      );
      expect(
        LescaleController.profiles.map((p) => p.id).toList(),
        ['a', 'b'],
      );
    });

    test('per-member biometricProfiles overrides height/age/gender/target',
        () {
      LescaleController.setProfilesFromFamilyMembers(
        members: [
          // Family record claims 170 cm but the saved biometric profile
          // for this member overrides to 165 cm — the override wins.
          {'id': 'a', 'name': 'A', 'heightCm': 170.0, 'weightKg': 70.0},
        ],
        biometricProfiles: {
          'a': {
            'heightCm': 165.0,
            'age': 28,
            'isMale': false,
            'targetWeightKg': 60.0,
          },
        },
      );
      final p = LescaleController.profiles.single;
      expect(p.heightCm, 165.0);
      expect(p.age, 28);
      expect(p.isMale, isFalse);
      expect(p.expectedWeightKg, 60.0);
    });

    test('empty member list installs the safety-default profile', () {
      final registered = LescaleController.setProfilesFromFamilyMembers(
        members: const [],
      );
      expect(registered, 0);
      expect(LescaleController.profiles.length, 1);
      expect(LescaleController.profiles.first.id, '_default');
    });
  });
}
