# ViHealth ↔ `flutter_ble_devices` feature‑gap audit

Source: ViHealth (Shenzhen Viatom Technology) consumer app on iOS / Android
that drives the same Lepu/Viatom devices this plugin wraps. This document
catalogues only the **device‑protocol** capabilities ViHealth exercises —
i.e. things that have to live in this plugin, not in an app on top of it.
Account / cloud / Apple Health / charts / PDFs / localization are
deliberately out of scope.

The plugin's current method‑channel surface (cross‑checked against
`@/Users/richie/StudioProjects/flutter_ble_devices/android/src/main/kotlin/com/wecodelife/flutter_ble_devices/FlutterBleDevicesPlugin.kt:507-530`
and `@/Users/richie/StudioProjects/flutter_ble_devices/ios/Classes/FlutterBleDevicesPlugin.m:300-329`):

```
initService, isServiceReady, checkPermissions, requestPermissions,
scan, stopScan, connect, connectKnown, disconnect, getConnectedModel,
syncTime, getBattery, getDeviceConfig, setDeviceConfig,
startMeasurement, stopMeasurement,
getDeviceInfo, getFileList, readFile, cancelReadFile,
pauseReadFile, continueReadFile, readHistoryData,
factoryReset, updateUserInfo
```

`connectKnown`, `syncTime`, `getBattery`, `getDeviceConfig` /
`setDeviceConfig` were added by the "device control parity" PR — see
the status table at the bottom of this file. Everything else below
this line is **still missing** from that surface.

---

## 1. Device clock sync (all Lepu/Viatom families)

ViHealth pushes phone time to the device on every connect so recorded
files have a correct timestamp. Without it, BP2/ER1/ER2/O2Ring records
drift after each battery change.

- **Android (Lepu SDK)** — `BleServiceHelper.syncTime(model)` /
  `bp2SyncUtcTime(model, ts)` / `er1SyncUtcTime(...)` / `oxySyncTime(...)`.
- **iOS (VTMProductLib)** — `VTMURATUtils requestSyncUTCTime:tzOffset:` for
  URAT‑family devices, `VTO2Communicate setRtcTime:` for legacy O2.

**Proposed Dart API**

```dart
static Future<bool> syncTime({
  int? model,
  DateTime? time,    // defaults to DateTime.now()
});
```

Add `"syncTime"` handler on both platforms; route by `family` to the
correct util. **Priority: HIGH** — silently broken timestamps are the
single most common ViHealth support ticket.

---

## 2. Device configuration read/write (BP, WOxi, FOxi families)

The iOS plugin **already parses** `deviceConfig` events from
`VTMBPCmdGetConfig`, `VTMWOxiCmdGetConfig`, `VTMFOxiCmdGetConfig`
(`@/Users/richie/StudioProjects/flutter_ble_devices/ios/Classes/FlutterBleDevicesPlugin.m:1957-2122`),
but there is **no method‑channel command to request them** and **no
`setConfig` to push them back**. Android has zero handling for any of
these. A consumer can therefore not change a single device setting today.

### 2a. BP2 / BP2A / BP2T config

ViHealth screens that map to these fields (parsed already as
`calibZero`, plus `device_switch`, `volume`, `bright`, `mode`,
`avgMeasure`, `language` in `VTMBLEParser parseBPConfig:`):

- Screen brightness
- Buzzer/sound volume
- Auto‑shutdown timer
- Average‑mode (1 / 3 / 5 measurement averaging)
- Display language
- Tare/zero‑calibrate cuff (`calibZero` bit)

**Proposed Dart API**

```dart
class Bp2Config {
  final int brightness;       // 1..3
  final int volume;            // 0..3
  final int avgMeasure;        // 1, 3, 5
  final int language;          // enum LangEN, LangCN, ...
  final Duration autoOff;
}

static Future<Bp2Config> getBp2Config({int? model});
static Future<bool>      setBp2Config(Bp2Config cfg, {int? model});
```

Native: `VTMURATUtils requestGetConfig` / `requestSetConfig:` already
exists in `VTMProductLib` — only needs a method‑channel hop. Android:
`Bp2BleInterface.getConfig()` / `setConfig(Bp2Config)`.

### 2b. WOxi (O2Ring S) config

`VTMWOxiInfo` parses `spo2_thr`, `pulse_thr_low`, `pulse_thr_high`,
`vibrate`, `vibrate_level`, `record_period`, `language` already.
ViHealth surfaces all of these as the **Alarm** screen.

**Proposed Dart API**

```dart
class WoxiConfig {
  final int spo2Threshold;     // 80..95 %
  final int prLow;             // bpm
  final int prHigh;            // bpm
  final bool vibrationEnabled;
  final int  vibrationLevel;   // 0..3
  final Duration recordPeriod;
}

static Future<WoxiConfig> getWoxiConfig({int? model});
static Future<bool>       setWoxiConfig(WoxiConfig cfg, {int? model});
```

### 2c. FOxi (PF‑10BWS family) config

`VTMFOxiConfig` parses `spo2Low`, `prLow`, `prHigh`, `motorSwitch`,
`motorThreshold`. Same write‑back gap.

**Priority: HIGH** — without these, users can't turn off the wrist
buzzer or change desat thresholds, which is the #1 ViHealth setting.

---

## 3. Firmware OTA / DFU update

ViHealth ships firmware updates for **every** Viatom device. None of
that exists in this plugin.

- **Android** — Lepu's `DfuFile` + `DfuPresenter` / `DfuActivity` flow
  in `lepu-blepro` exposes `dfuUpgrade(file, model, callback)`. The
  vendored AAR already contains the classes; the plugin just doesn't
  bridge them.
- **iOS** — `VTMUpgraderUtils` (URAT) + Nordic's `iOSDFULibrary` (which
  the BP2 / ER1‑LW SoCs use). The CocoaPods spec doesn't currently pull
  Nordic DFU.

**Proposed Dart API**

```dart
static Future<bool> startFirmwareUpgrade({
  int? model,
  required Uint8List firmware,   // .zip (Nordic) or .bin (NRF52)
  String? firmwareVersion,
});

// Push events on a new typed stream.
static Stream<FirmwareUpgradeEvent> get firmwareUpgradeStream;
//   FirmwareUpgradeState: validating, transferring, verifying, rebooting,
//   completed, failed; plus `progress: 0..1`.
```

**Priority: MEDIUM** — required for parity with ViHealth, but the
underlying infra is the most invasive piece (extra Pod, extra entitlement).

---

## 4. Battery query (on‑demand)

The wire schema documents a `battery` event
(`@/Users/richie/StudioProjects/flutter_ble_devices/README.md:317`)
but there is **no `getBattery` method** — battery only arrives as a
side‑effect of an active measurement. ViHealth shows live battery on
its connect screen the moment you pair.

- **Android** — `bp2GetBattery(model)` / `oxyGetBattery(model)` /
  `er1GetBattery(model)`.
- **iOS** — `VTMURATUtils requestBattery` / `VTO2Communicate
  requestBatteryInfo`.

**Proposed Dart API**

```dart
static Future<BatteryInfo> getBattery({int? model});
```

**Priority: MEDIUM** — small surface, big UX win.

---

## 5. Explicit power‑off / shutdown command

ViHealth's "Turn off device" button. iOS already exposes the
`VTMBPTargetStatusEnd` value via `startMeasurement(mode: 'off')`
(`@/Users/richie/StudioProjects/flutter_ble_devices/ios/Classes/FlutterBleDevicesPlugin.m:741`)
but only as a side‑effect of `startMeasurement`, and only for BP2.
ER1/ER2/O2Ring have their own shutdown commands that aren't wired.

**Proposed Dart API**

```dart
static Future<bool> shutdown({int? model});
```

**Priority: LOW** — convenience.

---

## 6. User profile / multi‑user (scales)

`updateUserInfo` exists today but only writes to the **iComon** SDK's
internal user object
(`@/Users/richie/StudioProjects/flutter_ble_devices/android/src/main/kotlin/com/wecodelife/flutter_ble_devices/FlutterBleDevicesPlugin.kt:526`).
ViHealth manages up to **10 user slots** on the Viatom S1 and on iComon
scales, with per‑slot height/age/sex/athlete‑mode and a "guest" mode.
None of that is exposed:

- No way to enumerate / select / delete user slots.
- No athlete‑mode flag.
- No measurement‑unit toggle (kg / lb / 斤).
- `LescaleController` similarly hard‑codes a single profile
  (`@/Users/richie/StudioProjects/flutter_ble_devices/lib/src/lescale_controller.dart`).

**Proposed Dart API**

```dart
class ScaleUser {
  int slot;             // 1..10
  String name;
  int    ageYears;
  bool   isMale;
  double heightCm;
  bool   athleteMode;
}

static Future<List<ScaleUser>> listScaleUsers();
static Future<bool> upsertScaleUser(ScaleUser u);
static Future<bool> deleteScaleUser(int slot);
static Future<bool> setScaleUnit(WeightUnit u);   // kg, lb, jin
```

**Priority: MEDIUM** if you ship to households; LOW for clinical use.

---

## 7. AirBP / SmartBP — Android parity

Today AirBP is **iOS‑only for measurement**; Android merely scans
(`@/Users/richie/StudioProjects/flutter_ble_devices/README.md:277`).
ViHealth supports AirBP on both platforms. The Nordic‑UART parser
already lives in `ios/Classes/VTAirBPPacket.m` and is pure protocol —
porting it to Kotlin is mechanical and means AirBP gets first‑class
support on both platforms.

**Priority: HIGH** if any of your users are on Android with an AirBP.

---

## 8. ER1 OxyII pause/resume — iOS parity (and oxy/foxi)

`pauseReadFile` / `continueReadFile` work on Android ER1 only and
return `UNSUPPORTED` everywhere else
(`@/Users/richie/StudioProjects/flutter_ble_devices/ios/Classes/FlutterBleDevicesPlugin.m:318-326`).
The URAT protocol does not natively support pause/continue, but
ViHealth simulates it by stopping the read at the next chunk boundary
and resuming with `requestReadFileStartIdx:`. Mechanical to add.

**Priority: LOW** — you can already work around with disconnect/reconnect.

---

## 9. ECG / Oxy / BP file decoders for the missing families

The Dart‑side decoders cover `bp2`, `er1`, `er2`
(`@/Users/richie/StudioProjects/flutter_ble_devices/lib/src/parsers/`),
but `parsed` for `oxy`/`oxyII`/`pf10aw1` is only populated **on
Android** (the SDK does it natively). On iOS, those families deliver
raw bytes and the consumer is on their own. ViHealth has the
parsers — port them to pure Dart and the README's "decoded" matrix
becomes complete:

- `Oxy*File`     — header + `spo2List` + `prList` + `motionList` +
                   `o2Score`, `dropsTimes3Percent`, etc.
- `OxyIIFile`    — same plus stepCounter / desat events.
- `Pf10aw1File`  — header + spo2List/prList.
- `Er3MseriesFile` — currently no decoder at all.

**Priority: MEDIUM** — needed for offline replay on iOS.

---

## 10. ER3 / M‑series live waveform decoding

`er3` / `mseries` real‑time data is forwarded today as a base64
`waveInfo` blob
(`@/Users/richie/StudioProjects/flutter_ble_devices/README.md:332`,
`@/Users/richie/StudioProjects/flutter_ble_devices/README.md:276`).
ViHealth runs Lepu's compressed‑waveform decoder client‑side — that
yields actual ECG mV samples rather than an opaque blob.

**Priority: LOW** — most consumers don't have an ER3.

---

## 11. Measurement‑result events for AirBP on Android

Mentioned in §7 but worth calling out separately: even after the AirBP
parser lands on Android, ViHealth additionally emits a discrete
"final result" event distinct from the per‑pressure measuring events
(this exists on iOS today via `bp_result`). The Android port must keep
this distinction.

---

## 12. Cross‑cutting: `deviceConfig` event isn't surfaced in Dart

`@/Users/richie/StudioProjects/flutter_ble_devices/ios/Classes/FlutterBleDevicesPlugin.m:1959-2122`
emits `event: "deviceConfig"` but
`@/Users/richie/StudioProjects/flutter_ble_devices/lib/src/bluetodev_controller.dart`
has no typed stream for it (no `deviceConfigStream`). Add it once the
read/write methods in §2 land:

```dart
static Stream<DeviceConfigEvent> get deviceConfigStream;
```

Plus a `DeviceConfigEvent` model under
`@/Users/richie/StudioProjects/flutter_ble_devices/lib/src/models/`.

---

## 13. Bonded‑device persistence / auto‑reconnect

ViHealth re‑connects to the last paired device on app launch without
re‑scanning. Today every consumer must call `scan()` first because the
plugin discards the `CBPeripheral` / `BluetoothDevice` reference on
disconnect. Both SDKs support direct‑connect by identifier:

- **iOS** — `[centralManager retrievePeripheralsWithIdentifiers:@[uuid]]`
- **Android** — `BluetoothAdapter.getRemoteDevice(mac)` →
  `BleServiceHelper.connect(...)` works with a cached MAC.

**Proposed Dart API**

```dart
static Future<bool> connectKnown({
  required int model,
  required String mac,
});
```

**Priority: HIGH** — eliminates the worst UX regression vs. ViHealth.

---

## 14. Permission state on iOS

`requestPermissions` returns true/false but doesn't distinguish
**denied** from **not‑determined** vs **powered‑off**
(`@/Users/richie/StudioProjects/flutter_ble_devices/ios/Classes/FlutterBleDevicesPlugin.m:305`).
ViHealth shows three different dialogs for those three states. Easy
fix — return an enum.

```dart
enum BlePermissionState { granted, denied, notDetermined, poweredOff, unsupported }
static Future<BlePermissionState> getPermissionState();
```

**Priority: LOW** — quality‑of‑life.

---

## Summary — ranked TODO

| #  | Feature                                       | Priority | Estimated effort | Status |
| -- | --------------------------------------------- | -------- | ---------------- | ------ |
| 1  | Time sync                                     | **HIGH** | S (~1d)          | ✅ shipped (`syncTime`) |
| 2a | BP2 config get/set                            | **HIGH** | M (~3d)          | ✅ shipped — iOS rich, Android limited to `soundOn` (`Bp2Config` upstream is minimal) |
| 2b | WOxi config get/set                           | **HIGH** | M (~3d)          | ✅ shipped — iOS via per-field `VTMOxiParamsOption`, Android via `oxyII*` reflected wrappers |
| 2c | FOxi config get/set                           | **HIGH** | M (~3d)          | ✅ iOS shipped; Android pending — no `foxi*` methods in `lepu-blepro-1.2.0` (only `pf10Aw1*`) |
| 7  | AirBP on Android                              | **HIGH** | M (~2d)          | ✅ shipped — uses Lepu SDK's native `airBpStartBpTest` / `airBpGetConfig` / `airBpGetBattery` (audit was wrong: SDK does cover AirBP) |
| 13 | `connectKnown` / auto‑reconnect               | **HIGH** | S (~1d)          | ✅ shipped |
| 4  | `getBattery`                                  | MEDIUM   | S (~½d)          | ✅ shipped — iOS universal, Android only OxyII/BP3 (SDK limit) |
| 6  | Scale multi‑user + units                      | MEDIUM   | M (~3d)          | ✅ shipped — `setScaleUserProfile` / `setScaleUserList` push rich `ScaleUserProfile` (incl. nickname + W-series userId + measurement-feature flags). `setScaleWeightUnit` / `setScaleRulerUnit` / `setKitchenScaleUnit` wrap the iComon `settingManager` methods on both platforms. Reflected unit/profile changes surface as `scaleUnitChanged` / `scaleUserInfo` / `scaleUserList` events. |
| 9  | iOS Dart decoders for oxy/oxyII/pf10aw1       | MEDIUM   | M (~3d)          | ✅ shipped — pure-Dart parsers (`OxyFile`, `OxyIIFile`, `Pf10aw1File`) port the obfuscated lepu-blepro `doad.dofd` / `doad.dofe` / `doac.n` parsers byte-for-byte. `FileReadCompleteEvent.decoded` now dispatches to the right family. Round-trip tests pin every field. |
| 3  | Firmware OTA                                  | MEDIUM   | L (~1w, ext deps)| pending |
| 5  | `shutdown`                                    | LOW      | S (~½d)          | ✅ shipped — iOS BP2 (`VTMBPTargetStatusEnd`) + iComon kitchen scale (`powerOffKitchenScale:`); Android `UNSUPPORTED` for every family (lepu-blepro exposes no shutdown opcode) |
| 8  | URAT file pause/resume on iOS                 | LOW      | S (~1d)          | ✅ shipped — `pendingReadPaused` gates the next-chunk request; resume re-issues `readFile:offset` (URAT readFile is offset-keyed). Legacy O2 still returns `UNSUPPORTED` (no per-chunk hook). |
| 10 | ER3/M‑series waveform decode                  | LOW      | M (~2d)          | pending |
| 12 | `deviceConfigStream` + model class            | LOW      | S (~½d)          | ✅ shipped alongside #2 |
| 14 | Granular iOS permission state                 | LOW      | S (~½d)          | ✅ shipped — `getPermissionState()` returns `BlePermissionState` enum on both platforms; iOS maps `CBManagerState`, Android combines adapter.isEnabled with runtime grants. |

### "Device control parity" PR (shipped)

Bundle: **#1 + #2a/2b + #4 + #12 + #13**. Wire format and Dart API
documented in `README.md` § Device control. Per-side notes:

- Dart: `BluetodevController.syncTime`, `connectKnown`, `getBattery`,
  `getDeviceConfig`, `setDeviceConfig`, plus `batteryStream` and
  `deviceConfigStream` typed streams. Models `BatteryInfo`,
  `DeviceConfigEvent`, `ConfigField` live in
  `@/Users/richie/StudioProjects/flutter_ble_devices/lib/src/models/device_control.dart`.
- iOS: `handleSyncTime`/`handleConnectKnown`/`handleGetBattery`/
  `handleGetDeviceConfig`/`handleSetDeviceConfig` in
  `@/Users/richie/StudioProjects/flutter_ble_devices/ios/Classes/FlutterBleDevicesPlugin.m`.
  BP2 setConfig caches the device's `VTMBPConfig` snapshot first so
  calibration constants aren't zeroed.
- Android: same handler names in
  `@/Users/richie/StudioProjects/flutter_ble_devices/android/src/main/kotlin/com/wecodelife/flutter_ble_devices/FlutterBleDevicesPlugin.kt`.
  Config events reflected into the cross-platform flat map via
  `extractConfigFields` so an SDK upgrade that adds a field flows
  through to Dart without code changes.
- Tests: `@/Users/richie/StudioProjects/flutter_ble_devices/test/device_control_test.dart`
  pins the wire-format contract (battery, config, field).

Remaining recommended order: #7 (AirBP Android) as a standalone PR,
then #2c (FOxi Android — blocked on upstream SDK), then #3 (OTA)
once everything else is green.
