import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'lescale_bia_calculator.dart';

/// One household member registered against the LeScale F4.
///
/// The F4 firmware itself only stores a single profile slot — the
/// multi-user UX in vendor apps like ViHealth is implemented entirely
/// on the phone side by picking the closest [expectedWeightKg] match
/// against each final-weight reading.  The plugin reproduces that
/// behaviour so consumers can mirror ViHealth's mother/father/child
/// auto-detection without writing the picker themselves.
class LescaleUserProfile {
  /// Stable id surfaced on every `rtData` event so the consumer can
  /// render whose measurement just landed.  Free-form — typically a
  /// row id from the consumer's own user database.
  final String id;

  /// Display name (also surfaced on `rtData`).
  final String name;
  final double heightCm;
  final int age;
  final bool isMale;

  /// Last-known weight for this profile in kg.  Used to auto-pick the
  /// profile when more than one is registered: the picker chooses the
  /// profile whose [expectedWeightKg] is closest to the measured
  /// weight (within [LescaleController.autoPickToleranceKg]).  Leave
  /// null to opt this profile out of auto-pick.
  final double? expectedWeightKg;

  const LescaleUserProfile({
    required this.id,
    required this.name,
    required this.heightCm,
    required this.age,
    required this.isMale,
    this.expectedWeightKg,
  });

  LescaleUserProfile copyWith({double? expectedWeightKg}) => LescaleUserProfile(
    id: id,
    name: name,
    heightCm: heightCm,
    age: age,
    isMale: isMale,
    expectedWeightKg: expectedWeightKg ?? this.expectedWeightKg,
  );

  /// Build a [LescaleUserProfile] from a `FamilyMember.toJson()` map
  /// (the patient-app shape — `id` / `name` / `dob` / `gender` /
  /// `weightKg` / `heightCm`).  Optionally merge a biometric override
  /// map (`heightCm` / `age` / `isMale` / `targetWeightKg`) so
  /// consumers that maintain a separate `MemberBiometricProfile` per
  /// member get a one-line path into the picker.
  ///
  /// The picker only cares about height (BIA), age + gender (calorie
  /// reference values) and weight (auto-pick) — so this factory tries
  /// the biometric override first, then falls back to fields on the
  /// raw `FamilyMember`:
  ///
  ///  * `heightCm` — biometric > family > **170 cm** (typical adult
  ///    default keeps BIA running even when a member record is
  ///    incomplete).
  ///  * `age` — biometric > computed from family `dob` > **25**.
  ///  * `isMale` — biometric > family `gender` == `"male"` > **true**.
  ///  * `expectedWeightKg` — biometric `targetWeightKg` > family
  ///    `weightKg` > **null** (null opts that member out of
  ///    auto-pick).
  ///
  /// Returns `null` when the map has no usable `id` / `name`.
  static LescaleUserProfile? fromFamilyMember(
    Map<String, dynamic> familyMember, {
    Map<String, dynamic>? biometric,
  }) {
    final id = (familyMember['id'] ?? '').toString();
    final name = (familyMember['name'] as String? ?? '').trim();
    if (id.isEmpty || name.isEmpty) return null;

    double? readDouble(Map<String, dynamic>? src, String key) {
      final v = src?[key];
      return v is num ? v.toDouble() : null;
    }

    int? readInt(Map<String, dynamic>? src, String key) {
      final v = src?[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return null;
    }

    int? ageFromDob() {
      final s = familyMember['dob'];
      if (s is! String || s.isEmpty) return null;
      final datePart = s.length >= 10 ? s.substring(0, 10) : s;
      final parts = datePart.split('-');
      if (parts.length != 3) return null;
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      if (y == null || m == null || d == null) return null;
      final now = DateTime.now();
      var age = now.year - y;
      if (now.month < m || (now.month == m && now.day < d)) age -= 1;
      return age < 0 ? 0 : age;
    }

    bool? maleFromGender() {
      final g = (familyMember['gender'] as String?)?.toLowerCase();
      if (g == null || g.isEmpty) return null;
      if (g == 'male' || g == 'm') return true;
      if (g == 'female' || g == 'f') return false;
      return null; // "other" / unknown → fall through to default
    }

    return LescaleUserProfile(
      id: id,
      name: name,
      heightCm:
          readDouble(biometric, 'heightCm') ??
          readDouble(familyMember, 'heightCm') ??
          170.0,
      age: readInt(biometric, 'age') ?? ageFromDob() ?? 25,
      isMale: (biometric?['isMale'] as bool?) ?? maleFromGender() ?? true,
      expectedWeightKg:
          readDouble(biometric, 'targetWeightKg') ??
          readDouble(familyMember, 'weightKg'),
    );
  }

  @override
  String toString() =>
      'LescaleUserProfile($id $name ${heightCm}cm/${age}y/'
      '${isMale ? "M" : "F"}'
      '${expectedWeightKg != null ? " ~${expectedWeightKg}kg" : ""})';
}

/// Controller to handle LESCALE F4 (FI2016LB) logic entirely in Flutter
/// using the flutter_blue_plus package, decoding the proprietary Fitdays protocol.
class LescaleController {
  LescaleController._();

  static final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of Lescale events mapped to look like `BluetodevController.eventStream`
  static Stream<Map<String, dynamic>> get eventStream =>
      _eventController.stream;

  static BluetoothDevice? _connectedDevice;
  static StreamSubscription<List<ScanResult>>? _scanSub;
  static StreamSubscription<List<int>>? _ffb2Sub;
  static StreamSubscription<List<int>>? _ffb3Sub;

  // Internal state for BIA unlock
  static double? _pendingWeight;

  // Multi-user state.  Always at least one entry — the legacy single-
  // profile API funnels into _profiles[0] so existing consumers keep
  // working unchanged.
  static List<LescaleUserProfile> _profiles = const [
    LescaleUserProfile(
      id: '_default',
      name: 'Default',
      heightCm: 180.0,
      age: 25,
      isMale: true,
    ),
  ];

  /// Manual override id from [selectProfile].  When non-null the
  /// picker stops auto-detecting and always uses this profile.
  static String? _pinnedProfileId;

  /// Tolerance (kg) used when auto-picking a profile from
  /// [setProfiles].  A measurement within ±[autoPickToleranceKg] of a
  /// profile's `expectedWeightKg` will trigger that profile.
  static double autoPickToleranceKg = 5.0;

  /// Returns the profile that will be used for the next BIA
  /// computation, given [measuredWeightKg] (or any pending weight if
  /// null).  Exposed for tests and UIs that want to preview the
  /// picker decision before a measurement lands.
  static LescaleUserProfile resolveProfile({double? measuredWeightKg}) {
    if (_pinnedProfileId != null) {
      for (final p in _profiles) {
        if (p.id == _pinnedProfileId) return p;
      }
    }
    final w = measuredWeightKg ?? _pendingWeight;
    if (w != null) {
      LescaleUserProfile? best;
      double bestDelta = double.infinity;
      for (final p in _profiles) {
        final ew = p.expectedWeightKg;
        if (ew == null) continue;
        final d = (ew - w).abs();
        if (d < bestDelta) {
          bestDelta = d;
          best = p;
        }
      }
      if (best != null && bestDelta <= autoPickToleranceKg) return best;
    }
    return _profiles.first;
  }

  /// Update the (single) user profile for accurate BIA calculation.
  ///
  /// Backward-compatible shim that funnels into [setProfiles] with a
  /// single anonymous entry.  Prefer [setProfiles] for multi-user
  /// households.
  static void setProfile({
    required double heightCm,
    required int age,
    required bool isMale,
  }) {
    setProfiles([
      LescaleUserProfile(
        id: '_default',
        name: 'Default',
        heightCm: heightCm,
        age: age,
        isMale: isMale,
      ),
    ]);
  }

  /// Register a household.  The picker will auto-select whichever
  /// profile's [LescaleUserProfile.expectedWeightKg] is closest to
  /// each measurement (within [autoPickToleranceKg]) — matches the
  /// way ViHealth's family screen works.  Pass an empty list to clear
  /// (which falls back to a default 180 cm/25 y/male profile).
  ///
  /// Call [selectProfile] to manually pin one profile and bypass
  /// auto-pick entirely.
  static void setProfiles(List<LescaleUserProfile> profiles) {
    _profiles = profiles.isEmpty
        ? const [
            LescaleUserProfile(
              id: '_default',
              name: 'Default',
              heightCm: 180.0,
              age: 25,
              isMale: true,
            ),
          ]
        : List.unmodifiable(profiles);
    // Clear stale pin if the previously-pinned id no longer exists.
    if (_pinnedProfileId != null &&
        !_profiles.any((p) => p.id == _pinnedProfileId)) {
      _pinnedProfileId = null;
    }
  }

  /// Wire the patient-app's family-member service into the picker in
  /// one call.  Accepts the raw JSON shapes already produced by the
  /// consumer's `FamilyMember.toJson()` (and the optional per-member
  /// `MemberBiometricProfile.toJson()`), so the patient app can do:
  ///
  /// ```dart
  /// LescaleController.setProfilesFromFamilyMembers(
  ///   members: FamilyMemberService.instance.members
  ///       .map((m) => m.toJson()).toList(),
  ///   biometricProfiles: { for (final id in ids) id: bios[id]!.toJson() },
  ///   activeMemberId: FamilyMemberService.instance.activeMember?.id,
  /// );
  /// ```
  ///
  /// Members without a usable `id` / `name` are skipped.  When
  /// [activeMemberId] resolves to one of the supplied members it's
  /// moved to position `[0]` so it becomes the default fallback for
  /// the picker without hard-pinning it — auto-pick by weight still
  /// wins when another member of the household steps on the scale.
  ///
  /// Returns the number of profiles registered.
  static int setProfilesFromFamilyMembers({
    required List<Map<String, dynamic>> members,
    Map<String, Map<String, dynamic>>? biometricProfiles,
    String? activeMemberId,
  }) {
    final built = <LescaleUserProfile>[];
    for (final m in members) {
      final id = (m['id'] ?? '').toString();
      final bio = biometricProfiles?[id];
      final p = LescaleUserProfile.fromFamilyMember(m, biometric: bio);
      if (p != null) built.add(p);
    }
    if (built.isEmpty) {
      setProfiles(const []);
      return 0;
    }
    if (activeMemberId != null) {
      final idx = built.indexWhere((p) => p.id == activeMemberId);
      if (idx > 0) {
        final active = built.removeAt(idx);
        built.insert(0, active);
      }
    }
    setProfiles(built);
    return built.length;
  }

  /// Pin one profile id to be used for every subsequent measurement,
  /// or pass null to resume auto-pick.  An unknown id is ignored
  /// (auto-pick continues).
  static void selectProfile(String? id) {
    if (id == null) {
      _pinnedProfileId = null;
      return;
    }
    if (_profiles.any((p) => p.id == id)) {
      _pinnedProfileId = id;
    }
  }

  /// Currently registered household, in the order passed to
  /// [setProfiles].  Always has at least one entry.
  static List<LescaleUserProfile> get profiles => List.unmodifiable(_profiles);

  /// Currently pinned profile id, or null when in auto-pick mode.
  static String? get pinnedProfileId => _pinnedProfileId;

  /// Start scanning for LESCALE F4 devices
  static Future<void> scan() async {
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first;

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (var r in results) {
        final name = r.device.platformName.toLowerCase();
        final advName = r.advertisementData.advName.toLowerCase();
        if (name.contains('lescale') ||
            name.contains('fi2016') ||
            name.contains('f4') ||
            advName.contains('lescale') ||
            advName.contains('fi2016') ||
            advName.contains('f4')) {
          _eventController.add({
            'event': 'deviceFound',
            'mac': r.device.remoteId.str,
            'name': r.device.platformName.isNotEmpty
                ? r.device.platformName
                : r.advertisementData.advName,
            'model': 9999, // Custom model ID for Lescale
            'rssi': r.rssi,
            'sdk': 'lescale',
            'deviceType': 'scale', // custom type, can be handled in UI
          });
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  }

  /// Stop scanning
  static Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  /// Connect to the discovered Bluetooth device object
  static Future<bool> connect(String mac) async {
    try {
      final device = BluetoothDevice.fromId(mac);

      // Preemptively attempt to disconnect to clear any ghost GATT connections
      try {
        await device.disconnect();
      } catch (_) {}

      // Connect and establish GATT
      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 10),
      );
      _connectedDevice = device;

      // CRITICAL: Give Android GATT stack time to settle before querying services
      await Future.delayed(const Duration(milliseconds: 600));

      _eventController.add({
        'event': 'connectionState',
        'state': 'connected',
        'model': 'Lescale F4',
      });

      // Clear old subs just in case
      _ffb2Sub?.cancel();
      _ffb3Sub?.cancel();

      // Discover services and hook to ffb2/ffb3
      final services = await device.discoverServices();
      for (var s in services) {
        for (var c in s.characteristics) {
          final uuid = c.uuid.str.toLowerCase();
          if (uuid.contains('ffb2')) {
            await Future.delayed(const Duration(milliseconds: 200));
            await c.setNotifyValue(true);
            _ffb2Sub = c.lastValueStream.listen(
              (data) => _decodePayload(data, isLocked: false),
            );
          } else if (uuid.contains('ffb3')) {
            await Future.delayed(const Duration(milliseconds: 200));
            await c.setNotifyValue(true);
            _ffb3Sub = c.lastValueStream.listen(
              (data) => _decodePayload(data, isLocked: true),
            );
          } else if (uuid.contains('ffb1')) {
            // Store or use FFB1 for writing if needed
          }
        }
      }

      // Automatically unlock BIA by sending the current user profile
      await _unlockBia(device);

      return true;
    } catch (e) {
      _eventController.add({
        'event': 'connectionState',
        'state': 'disconnected',
        'reason': e.toString(),
      });
      return false;
    }
  }

  static Future<void> disconnect() async {
    _ffb2Sub?.cancel();
    _ffb3Sub?.cancel();

    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
        // Give the adapter a tiny moment to clear its internal state cache
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (_) {}
      _connectedDevice = null;
    }

    _eventController.add({
      'event': 'connectionState',
      'state': 'disconnected',
      'reason': 'user requested',
    });
  }

  /// Write user profile to FFB1 to unlock impedance/BIA data
  static Future<void> _unlockBia(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      BluetoothCharacteristic? ffb1;
      for (var s in services) {
        for (var c in s.characteristics) {
          if (c.uuid.str.toLowerCase().contains('ffb1')) {
            ffb1 = c;
            break;
          }
        }
      }

      if (ffb1 != null) {
        // Protocol: AB 2A + [Timestamp 4b] + 00 + [Unit] + [Profile 7b] + D7 + [Checksum]
        // Default Profile: UserID 1, 180cm, 0kg last weight, Male (1), Age 25, 0 impedance
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final payload = List<int>.filled(20, 0);
        payload[0] = 0xAB;
        payload[1] = 0x2A;
        // Timestamp (Big Endian)
        payload[2] = (now >> 24) & 0xFF;
        payload[3] = (now >> 16) & 0xFF;
        payload[4] = (now >> 8) & 0xFF;
        payload[5] = now & 0xFF;
        payload[6] = 0x00; // Reserved
        payload[7] = 0x00; // Unit: KG

        // User Entry (7 bytes) — uses the currently-selected profile
        // so the device's on-board BIA computation (when available)
        // matches the demographics we'll use for the on-phone BIA
        // calculation.  We pick by `_pendingWeight` if set; otherwise
        // fall back to whichever profile is at the head of the list.
        final unlockProfile = resolveProfile();
        payload[8] = 0x01; // User Index
        payload[9] = unlockProfile.heightCm.round();
        payload[10] = 0; // Weight High
        payload[11] = 0; // Weight Low
        final int genderBit = unlockProfile.isMale ? 1 : 0;
        payload[12] = (genderBit << 7) | (unlockProfile.age & 0x7F);
        payload[13] = 0; // Impedance High
        payload[14] = 0; // Impedance Low

        payload[18] = 0xD7; // Command Footer

        // Checksum (Sum of bytes 2 to 18)
        int sum = 0;
        for (int i = 2; i <= 18; i++) {
          sum = (sum + payload[i]) & 0xFF;
        }
        // Custom quirk: remove impedance byte from sum (as seen in OneByoneNewHandler)
        sum = (sum - payload[13]) & 0xFF;

        payload[19] = sum;

        debugPrint(
          "Lescale: Sending BIA Unlock Command: ${payload.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}",
        );
        await ffb1.write(payload, withoutResponse: false);
      }
    } catch (e) {
      debugPrint("Lescale: Failed to unlock BIA: $e");
    }
  }

  /// Decode the payload: Fitdays/Icomon Protocol
  static void _decodePayload(List<int> data, {required bool isLocked}) {
    // Log the raw data for debugging
    final hexString = data
        .map((e) => e.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    debugPrint("Lescale: Received Data: $hexString");

    if (data.length < 9) return;

    // Standard Fitdays types
    // 0xA2 = Live Weight
    // 0xA3 = Locked Weight
    // 0x80 = Final Weight (OneByone variant)
    // 0x01 = Impedance (OneByone variant)

    int type = data[3];
    if (data.length > 2 && (data[2] == 0x01 || data[2] == 0x80)) {
      type = data[2];
    }

    if (type == 0xA2) {
      // Live weight
      int weightRaw = (data[6] << 16) | (data[7] << 8) | data[8];
      _emitRtData(weightRaw / 1000.0, false);
    } else if (type == 0xA3) {
      // Locked weight (Standard)
      double weight = ((data[5] << 16) | (data[6] << 8) | data[7]) / 1000.0;
      _pendingWeight = weight;

      // Reset HR for new measurement, don't use the checksum byte (index 10)
      int heartRate = 0;

      // IMPEDANCE: Big Endian at 8, 9. Some F4 firmware variants do not
      // include impedance in the 0xa3 frame (the BIA unlock handshake is
      // either rejected or the firmware never measures impedance at all).
      // In that case the bytes are zero and we still emit a BIA payload
      // — the calculator degrades gracefully to weight+demographics
      // estimates so the page can leave the "Calculating body
      // composition" placeholder instead of hanging forever waiting for
      // a follow-up packet that will never arrive.
      int impedance = 0;
      if (data.length >= 10) {
        impedance = (data[8].toInt() << 8) | data[9].toInt();
      }

      _calculateAndEmitBia(
        weight,
        impedance,
        heartRate: heartRate,
        impedanceMeasured: impedance > 0,
      );
    } else if (type == 0x51) {
      // DEDICATED HEART RATE PACKET (F4 Variant)
      // Usually: AB 51 HR CS
      if (data.length >= 3) {
        int hr = data[2];
        if (hr > 30 && hr < 200) {
          // If we have a pending weight, emit it with the new HR
          _emitRtData(_pendingWeight ?? 0.0, true, heartRate: hr);
        }
      }
    } else if (type == 0x80) {
      // OneByone New: Final Weight
      int weightRaw =
          ((data[3] & 0xFF) << 16) | ((data[4] & 0xFF) << 8) | (data[5] & 0xFF);
      weightRaw &= 0x03FFFF;
      double weight = weightRaw / 1000.0;
      _pendingWeight = weight;
      _emitRtData(weight, true);
    } else if (type == 0x01) {
      // OneByone New: Impedance Packet
      int impedance = ((data[4] & 0xFF) << 8) | (data[5] & 0xFF);

      if (_pendingWeight != null && impedance > 0) {
        _calculateAndEmitBia(_pendingWeight!, impedance);
      }
    }
  }

  static void _calculateAndEmitBia(
    double weight,
    int impedance, {
    int? heartRate,
    bool impedanceMeasured = true,
  }) {
    // If impedance seems like it's swapped (too high), swap it
    if (impedance > 10000) {
      impedance = ((impedance & 0xFF) << 8) | ((impedance >> 8) & 0xFF);
    }

    final profile = resolveProfile(measuredWeightKg: weight);
    final calc = LescaleBiaCalculator(
      weight: weight,
      heightCm: profile.heightCm,
      age: profile.age,
      isMale: profile.isMale,
      impedance: impedance,
    );

    final report = calc.calculate();
    _eventController.add({
      'event': 'rtData',
      'deviceType': 'scale',
      'weightKg': weight.toStringAsFixed(2),
      'impedance': impedance,
      'impedanceMeasured': impedanceMeasured,
      if (heartRate != null && heartRate > 0) 'heartRate': heartRate,
      'isLocked': true,
      'userId': profile.id,
      'userName': profile.name,
      'pinned': _pinnedProfileId == profile.id,
      ...report,
    });
  }

  static void _emitRtData(double weight, bool locked, {int? heartRate}) {
    final profile = resolveProfile(measuredWeightKg: weight);
    _eventController.add({
      'event': 'rtData',
      'deviceType': 'scale',
      'weightKg': weight.toStringAsFixed(2),
      if (heartRate != null && heartRate > 0) 'heartRate': heartRate,
      'isLocked': locked,
      'userId': profile.id,
      'userName': profile.name,
      'pinned': _pinnedProfileId == profile.id,
    });
  }
}
