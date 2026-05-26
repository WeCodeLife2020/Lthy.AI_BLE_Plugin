## Unreleased

* **LeScale F4 multi-user family picker.**
  * New `LescaleUserProfile` class (exported from package root) with a
    `fromFamilyMember(map, {biometric})` static factory that consumes
    the `FamilyMember.toJson()` + `MemberBiometricProfile.toJson()`
    shapes from the patient app directly — no manual field mapping.
  * `LescaleController.setProfilesFromFamilyMembers(members, biometricProfiles, activeMemberId)` — one-call replacement for `setProfile`. Mirrors ViHealth's weight-bracket auto-detection: the member whose `expectedWeightKg` / `weightKg` is closest to the locked reading (within `autoPickToleranceKg`, default 5 kg) is selected automatically; the active member is placed at position [0] as fallback without hard-pinning.
  * `LescaleController.selectProfile(id)` / `selectProfile(null)` — manual override / clear.
  * Every `rtData` event now carries `userId`, `userName`, and `pinned` so the UI can show whose result just landed.
  * `setProfile(heightCm, age, isMale)` remains fully back-compatible.
  * 21 new unit tests in `test/lescale_profile_test.dart`.


* **iOS Dart decoders for oxy / oxyII / pf10aw1 (ViHealth feature gap item #9).**
  * New `OxyFile`, `OxyEachData`, `OxyIIFile`, `Pf10aw1File` classes
    under `package:flutter_ble_devices/flutter_ble_devices.dart`.
  * `FileReadCompleteEvent.decoded` now dispatches `oxy` → `OxyFile`,
    `oxyII` → `OxyIIFile`, `pf10aw1` → `Pf10aw1File`. Decoder runs
    identically on Android & iOS — the on-flash format is the same
    across platforms, only the iOS side used to lack a Dart parser.
  * `OxyEachData` exposes a corrected `warningSignXxx` decode plus an
    SDK-buggy `warningSignXxxSdk` for callers who need byte-for-byte
    parity with the lepu-blepro Java `OxyFile.EachData` object.
  * Round-trip tests pin every field for the three formats.
* **Scale multi-user + units (ViHealth feature gap item #6).**
  * `BluetodevController.setScaleUserProfile` /
    `setScaleUserList` push a rich `ScaleUserProfile` (incl. nickname,
    W-series `userId`, per-measurement-feature flags).
  * `BluetodevController.setScaleWeightUnit` /
    `setScaleRulerUnit` / `setKitchenScaleUnit` wrap the iComon
    `settingManager` setters on both platforms.
  * Reflected changes surface as `scaleUnitChanged`, `scaleUserInfo`,
    `scaleUserList` events on the existing event stream.
* **Device control parity (ViHealth feature gap items #1 / #2 / #4 / #12 / #13).**
  * `BluetodevController.syncTime` — push phone time to the device so
    recordings carry an accurate timestamp. Universal on iOS (URAT +
    legacy O2); Android uses `BleServiceHelper.syncTime(model)` which
    ignores the `time` argument by SDK design.
  * `BluetodevController.connectKnown` — direct-connect by MAC without
    a fresh scan. iOS uses `retrievePeripheralsWithIdentifiers:`;
    Android uses `BluetoothAdapter.getRemoteDevice`. Both fall back to
    a short rescan on cache-miss.
  * `BluetodevController.getBattery` + `batteryStream`. Universal on
    iOS; Android limited to OxyII / BP3 (and AirBP / AP20 / SP20 / LEM
    / PC80B when those families land) because the Lepu SDK only
    exposes on-demand battery for those.
  * `BluetodevController.getDeviceConfig` / `setDeviceConfig` +
    `deviceConfigStream` typed event. Models `BatteryInfo`,
    `DeviceConfigEvent`, `ConfigField` exported from
    `package:flutter_ble_devices/flutter_ble_devices.dart`.
  * iOS BP2 setConfig caches the device's `VTMBPConfig` snapshot before
    every write so calibration constants are never zeroed.

## 0.0.1

* TODO: Describe initial release.
