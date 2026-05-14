# flutter_ble_devices

Flutter plugin for Viatom / Lepu BLE medical devices (ECG, Oximeter, Blood
Pressure, body scale). It wraps the official vendor SDKs so that one Dart
API works on both platforms:

| Platform | Native SDK used |
| --- | --- |
| Android | `lepu-blepro` (Lepu/Viatom AAR) + `ICDeviceManager` (iComon scales) |
| iOS     | [`VTMProductLib`](https://github.com/viatom-dev/VTProductLib) (CocoaPods) + `ICDeviceManager.xcframework` (iComon scales, vendored under `ios/Frameworks/`) |

The Dart API is exposed from `lib/flutter_ble_devices.dart` — the same
`BluetodevController.scan()`, `.connect()`, `.startMeasurement()`, and event
streams work on both platforms.

---

## Supported devices

### ECG
- ER1 / ER1-N / ER1-S / ER1-H / ER1-W / ER1-L / ER1-LW / VBeat (`family = "er1"`)
  - ER1-LW (ER1-L with WiFi) advertises as `ER1-LW` / `ER1LW` and shares
    `MODEL_ER1_L = 148` with ER1-L.
- ER2 / ER2-S / DuoEK / DuoEK-S (`family = "er2"`)
- Lepod / Lepod Pro (`family = "er3"`)
- M12 / M5 (`family = "mseries"`)

### Oximeter
- O2Ring / O2M / BabyO2 / CheckO2 / SleepO2 / SnoreO2 / SleepU / OxyLink /
  KidsO2 / Oxyfit / OxyRing / BBSM-S1/S2 (`family = "oxy"` — legacy AA
  header, uses `VTO2Communicate` on iOS)
- O2Ring S (`family = "woxi"`)
- PF-10AW / PF-10AW1 / PF-10AW_1 / PF-10BW / PF-10BW1 / PF-10BWS
  (`family = "foxi"`) — each advertised name maps to the exact Lepu
  `MODEL_PF_10*` id listed in [`ios/Classes/VTMDeviceTypeMapper.m`](ios/Classes/VTMDeviceTypeMapper.m).

### Blood pressure
- BP2 / BP2A / BP2T / BP2W / BP2 Pro (`family = "bp2"`)
- BP3 family (`family = "bp3"`)
- **AirBP / SmartBP** (`family = "airbp"`, `sdk = "airbp"`) — structured `sys`/`dia`/`mean`/`pr` on both platforms via the [viatom-dev/iOSAirBP](https://github.com/viatom-dev/iOSAirBP) protocol (no external SDK needed; parsers live in `ios/Classes/VTAirBPPacket.*`)

### Scale
- Viatom S1 body-composition scale (iOS only — `family = "scale"`, VTProductLib)
- iComon / Welland body-composition scales (**both platforms** — Android AAR / iOS `ICDeviceManager.xcframework`)
- **LESCALE F4** and other Fitdays-protocol scales — handled by the
  cross-platform [`LescaleController`](lib/src/lescale_controller.dart)
  which drives the peripheral with `flutter_blue_plus` directly and does
  not rely on the Lepu or iComon native bridges. Advertises model id
  `DeviceModels.lescaleF4` (`9999`).

---

## Install

```yaml
dependencies:
  flutter_ble_devices:
    path: ../flutter_ble_devices   # or the published version
```

### Android

The AARs are already vendored in `android/libs/`. Nothing else is required.

#### Updating the Lepu AAR

The vendored `lepu-blepro-1.2.0.aar` has been post-processed so that every
`Log.d` / `toString()` / error-message string embedded in the compiled
classes reads in English rather than Chinese. Our plugin's own logs, and
the iOS `VTMProductLib`, are already English-only; the Android patcher
closes the last gap.

When Lepu ships a new AAR, re-run the patcher:

```sh
# 1. Drop the new vendor AAR into android/libs/, overwriting the old one.
cp <new>/lepu-blepro-X.Y.Z.aar android/libs/lepu-blepro-1.2.0.aar

# 2. Run the patcher (idempotent; creates a .orig backup on first run).
python3 tools/translate_lepu_aar.py
```

The script walks every `CONSTANT_Utf8` entry in every `.class` file inside
the AAR's `classes.jar`, replaces each Chinese literal with its English
translation, and re-packs the AAR in place. It fails loudly if a new
Chinese literal shows up with no mapping, so you'll get a list of strings
to translate before the AAR is considered clean.

### iOS

The iOS plugin ships as two CocoaPods subspecs:

| Subspec | What it pulls in | Devices it enables |
| --- | --- | --- |
| **`Core`** *(default)* | `VTMProductLib` (Obj-C xcframework from CocoaPods) + the AirBP Nordic-UART parser baked into this repo | ECG (ER1/ER2/ER3/M-series), BP2/BP3, Viatom oximeters (legacy `0xAA` **and** URAT/FOxi/WOxi), Viatom S1 scale, AirBP / SmartBP |
| **`IComon`** *(opt-in)* | Everything in `Core` plus the four vendored iComon xcframeworks (`ICDeviceManager`, `ICBleProtocol`, `ICBodyFatAlgorithms`, `ICLogger`) | iComon / Welland body-composition scales |

The **IComon subspec is opt-in on purpose**. Those xcframeworks register
Obj-C classes named `ICDevice`, `ICDeviceManager`, and `ICDeviceInfo`,
which **collide with Apple's own `ImageCaptureCore.framework`** and the
private `iTunesCloud.framework`. Apps that don't need scale support
should stay on `Core` to avoid the runtime warning:

```
objc[…]: Class ICDeviceManager is implemented in both
  /System/Library/Frameworks/ImageCaptureCore.framework/ImageCaptureCore
  AND /path/to/Runner.app/Runner.debug.dylib
  This may cause spurious casting failures and mysterious crashes.
```

#### Default install (ECG/BP/Oximeter/AirBP only)

```sh
cd ios && pod install
```

That's it — the default `Core` subspec is selected automatically.

#### Opting into iComon scale support

Edit your app's `ios/Podfile` and declare the subspecs explicitly:

```ruby
target 'Runner' do
  use_frameworks!
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))

  # Pull both subspecs so body-composition scales work.
  pod 'flutter_ble_devices',
      :path     => '.symlinks/plugins/flutter_ble_devices/ios',
      :subspecs => ['Core', 'IComon']
end
```

Then `pod install --repo-update`. The iComon SDK is linked, and
`FlutterBleDevicesPlugin.m` automatically picks up the iComon code paths
via `__has_include(<ICDeviceManager/ICDeviceManager.h>)` — no manual
flags needed.

If a call to `connect(sdk: 'icomon', …)` reaches an app built without the
`IComon` subspec, the plugin returns a clean `UNSUPPORTED` method-channel
error instead of crashing.

#### `Info.plist` keys

Required on **both** subspec configurations:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>We use Bluetooth to communicate with your medical device.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>We use Bluetooth to communicate with your medical device.</string>
```

Minimum iOS deployment target: **iOS 11**. All vendored xcframeworks are
device-only arm64 (no `ios-arm64-simulator` slice), so the podspec excludes
`arm64` from the simulator build — run on a **physical device**.

#### iOS connect lifecycle

The plugin emits `connectionState` events in a strict order so the
consumer can drive a deterministic UI:

```
scan() → deviceFound (1..N)
connect(mac) → connectionState{state: "connecting"}
            → connectionState{state: "connected", model, family, deviceType}
            → (commands now permitted; ensureReady passes)
```

If service discovery doesn't complete within **15 s** (peripheral
powered off mid-connect, GATT stall on a flaky device, etc.) the
plugin cancels the connection and emits:

```
connectionState{state: "disconnected", reason: "deploy_timeout"}
```

Other failure reasons surfaced on the `disconnected` event include
`service_discovery_failed`, `airbp_service_not_found`,
`subscribe_failed`, `connect_failed`, `bluetooth_off`, and
`device_disconnected` (iComon).

#### Troubleshooting "device not connecting" on iOS

1. **Permissions** — confirm `NSBluetoothAlwaysUsageDescription` (and
   the legacy `NSBluetoothPeripheralUsageDescription` for iOS 12 and
   below) are in your app's `Info.plist`. Without them
   `CBCentralManager` silently stays in `unauthorized` state and
   neither scan nor connect will work — and there's no visible error.
2. **Bluetooth permission alert** — first launch on iOS 13+ shows the
   permission prompt the first time `CBCentralManager` is allocated;
   `initService()` triggers that. If the user taps "Don't Allow", scan
   returns nothing forever. `requestPermissions()` returns the live
   permission status — gate your "scan" button on that.
3. **Run on a physical device** — every vendored xcframework
   (`VTMProductLib`, `ICDeviceManager`, `ICBleProtocol`,
   `ICBodyFatAlgorithms`, `ICLogger`) is arm64-only. Simulator
   builds will link-fail; even a successful simulator link won't
   actually drive a BLE radio.
4. **Mid-debug-session stale peripheral** — Xcode reattaches don't
   reset CoreBluetooth's peripheral cache, but iOS does evict
   peripherals after long idle. If `connect()` returns
   `UNKNOWN_DEVICE`, call `scan()` again — the `cacheSize` field on
   the error details tells you how many peripherals are currently
   discovered.
5. **`deploy_timeout` reason** — almost always a peripheral that
   advertised the right name but couldn't complete GATT service
   discovery. Power-cycle the device, increase RSSI by moving closer,
   and retry. The plugin auto-cancels the connection on timeout so
   you can immediately call `connect()` again.
6. **Verbose logging** — the plugin emits structured `[FBDevices]`
   `NSLog` lines for every scan, connect, didConnect, deploy
   complete / failed, and disconnect transition. Tail them in Xcode's
   "Devices and Simulators" console window, or
   `idevicesyslog | grep FBDevices` on a tethered device.

#### Updating the iComon SDK

The iComon SDK currently vendored is `iOS_1.3.0_b1312`. When the vendor
ships a new version, drop it somewhere outside the repo and copy the four
xcframeworks over the old ones, then re-run pod install:

```sh
cp -R <new-sdk-drop>/SDK/ICDeviceManager.xcframework     ios/Frameworks/
cp -R <new-sdk-drop>/SDK/ICBleProtocol.xcframework       ios/Frameworks/
cp -R <new-sdk-drop>/SDK/ICBodyFatAlgorithms.xcframework ios/Frameworks/
cp -R <new-sdk-drop>/SDK/ICLogger.xcframework            ios/Frameworks/
cd ios && pod install
```

---

## Quick start

```dart
import 'package:flutter_ble_devices/flutter_ble_devices.dart';

// 1. Permissions + service init
await BluetodevController.requestPermissions();
await BluetodevController.initService();

// 2. Listen
BluetodevController.scanStream.listen((dev) {
  print('found ${dev.name} (${dev.mac}) model=${dev.model}');
});
BluetodevController.measurementStream.listen((m) {
  print('hr=${m.hr} spo2=${m.spo2} sys=${m.sys}/${m.dia}');
});

// 3. Scan → connect → measure
await BluetodevController.scan();
// ... user picks a device ...
await BluetodevController.connect(model: device.model, mac: device.mac);
await BluetodevController.startMeasurement();               // default mode
// BP2/BP2A/BP2T/BP2W → `mode` selects the device state first
await BluetodevController.startMeasurement(mode: 'bp');     // or 'ecg' / 'history' / 'ready' / 'off'
```

---

## iOS ↔ Android compatibility notes

| Concept | Android | iOS |
| --- | --- | --- |
| `mac` string | Real BT MAC (`AA:BB:CC:...`) | VT path: CBPeripheral `UUID` string. iComon path: MAC-style string synthesised by `ICDeviceManager` from the peripheral UUID. Both are opaque identifiers you can pass straight back to `connect(mac:...)`. |
| `model` integer | `Bluetooth.MODEL_*` from Lepu SDK | Same ids — mapped from the advertised name by `VTMDeviceTypeMapper` |
| Scanning filter | Lepu native filter by model | Client-side filter by model after name classification |
| iComon scales | Supported (`sdk: 'icomon'`) | Supported (`sdk: 'icomon'`) via `ICDeviceManager.xcframework` |
| Real-time ECG (ER1/ER2) | Structured `ecgFloats`/`ecgShorts` | Structured `ecgFloats`/`ecgShorts` via `VTMBLEParser` |
| Real-time O2 (AA path) | Structured | Structured, via `VTO2Parser` |
| Real-time BP2 / BP2A / BP2T / BP2W | Structured (`measureType`, `sys`, `dia`, `mean`, `pr`, `pressure`, `ecgFloats`, …) | **Structured** via `VTMBLEParser (BP)` — same field names as Android. `startMeasurement(mode: 'bp'/'ecg')` drives the device-side state switch that Android's `BleServiceHelper.startRtTask` does internally. |
| Real-time WOxi (O2Ring S) | Structured (`spo2`, `pr`, `pi`, `waveData`, …) | **Structured** via `VTMBLEParser.woxi_parseRealData:` |
| Real-time FOxi (PF-10BWS family) | Structured | **Structured** via `VTMBLEParser.foxi_parseMeasureInfo:` / `foxi_parseMeasureWave:` |
| Real-time Scale (S1 / F4) | Structured | **Structured** via `VTMBLEParser (Scale)` |
| Real-time ER3 / M-series | Structured | **Structured** via `VTMBLEParser.parseER3RealTimeData:` / `parseMSeriesRunParams:` (compressed waveform surfaced as base64) |
| Real-time AirBP | Scan-only — no AirBP-specific handler wired in the Android plugin yet. | Fully wired: structured `sys`/`dia`/`mean`/`pr` + live `pressure` via `VTAirBPPacket` (plain Nordic UART, no external SDK). |

### Polling vs push

The Android Lepu SDK's `BleServiceHelper.startRtTask(model)` drives the
real-time command pipe internally, so Dart just sees events flow. On iOS
most URAT commands (`requestECGRealData`, `requestBPRealData`,
`requestScaleRealData`, `requestER3ECGRealData`, `baby_requestRunParams`)
are one-shot GETs, so the plugin runs a light `NSTimer`-based poll at
300–500 ms cadence for those families. `WOxi` and `FOxi` use push
subscriptions (`observeParameters:` / `foxi_makeInfoSend:`), so those are
**not** polled. `stopMeasurement` and `disconnect` tear the timer down.

### Model-id mapping (summary)

The iOS side deliberately re-uses the same integer ids as the Lepu Android
SDK so the Dart layer doesn't need to branch per platform. Mapping lives in
`ios/Classes/VTMDeviceTypeMapper.m`.

---

## Event schema (both platforms)

Emitted on `BluetodevController.eventStream`:

```
{ 'event': 'serviceReady' }
{ 'event': 'deviceFound', 'name', 'mac', 'model', 'rssi', 'sdk', 'deviceType', 'family' }
{ 'event': 'connectionState', 'state': 'connected'|'disconnected', 'model', ... }
{ 'event': 'rtData', 'deviceType', 'deviceFamily', 'model', <fields> }
{ 'event': 'rtWaveform', 'deviceType', 'deviceFamily', 'model', <fields> }
{ 'event': 'deviceInfo', 'model', ... }
{ 'event': 'fileList',  'model', 'deviceFamily'?, 'files': [String] }
{ 'event': 'fileReadProgress', 'model', 'deviceFamily', 'fileName'?, 'progress': 0..1 }
{ 'event': 'fileReadComplete', 'model', 'deviceFamily', 'fileName',
                                'size', 'content': <base64>?, 'parsed'?: {...} }
{ 'event': 'fileReadError',    'model', 'deviceFamily', 'fileName'?, 'error' }
{ 'event': 'recordingFinished', 'model', 'deviceFamily' }
{ 'event': 'historyData', 'kind': 'weight'|'kitchenScale'|'ruler'|'skip',
                           'deviceFamily': 'icomon', 'mac', 'time', ...kind-specific }
{ 'event': 'battery',   'state', 'percent', 'voltage' }
```

### `rtData` fields per family

| `deviceFamily` | Fields |
| --- | --- |
| `er1`, `er2` | `hr`, `battery`, `batteryState`, `recordTime`, `curStatus`, `ecgFloats` (mV), `ecgShorts`, `samplingRate`, `mvConversion` |
| `bp2`, `bp3` | `deviceStatus`, `batteryState`, `batteryPercent`, `paramDataType`, `measureType` ∈ {`bp_measuring`, `bp_result`, `ecg_measuring`, `ecg_result`, `idle`, `bp_status`, `bp_pressure`}, plus per-measureType fields: **bp_measuring** `pressure`, `pr`, `isDeflate`, `isPulse`; **bp_result** `sys`, `dia`, `mean`, `pr`, `result`, `stateCode`; **ecg_measuring** `hr`, `curDuration`, `isLeadOff`, `isPoolSignal`, `ecgFloats`, `ecgShorts`, `samplingRate`, `mvConversion`; **ecg_result** `hr`, `qrs`, `pvcs`, `qtc`, `result` |
| `airbp` | `measureType` ∈ {`bp_measuring`, `bp_result`, `bp_status`}, `pressure`, `pulseWave`, `sys`, `dia`, `mean`, `pr`, `state`, `timestamp` |
| `oxy` (legacy) | `spo2`, `pr`, `pi`, `battery`, `batteryState`, `state`, `vector` |
| `woxi` | `spo2`, `pr`, `pi`, `battery`, `batteryState`, `state`, `sensorState`, `motion`, `recordTime`, `waveData` |
| `foxi` | `spo2`, `pr`, `pi`, `status`, `batLevel`, `probeOff` |
| `scale` (S1) | `weightKg`, `impedance`, `heartRate`, `runStatus`, `leadStatus` |
| `icomon` | `weightKg`, `bmi`, `fat`, `fat_mass`, `muscle`, `musclePercent`, `water`, `bone`, `protein`, `bmr`, `visceral`, `skeletal_muscle`, `subcutaneous`, `body_age`, `body_score`, `heartRate`, `impedance` |
| `er3`, `mseries` | `hr`, `spo2`, `pr`, `pi`, `temperature`, `respRate`, `battery`, `batteryState`, `runStatus`, `leadMode`, `leadState`, `samplingNum`, `waveInfo` |
| `baby` | `runStatus`, `attitude`, `wearStatus`, `rr`, `alarmTypeRR`, `temperature`, `alarmTypeTemp`, `battery`, `batteryState`, `startupTime`, `gestureAlarm` |

On iOS, unstructured device responses (unmapped cmdTypes) are emitted as:

```
{ 'event': 'raw', 'cmdType', 'deviceType', 'data': '<base64>' }
```

---

## Fetching on-device history (file transfer)

Most Lepu/Viatom devices store their measurement records on internal
flash. The plugin exposes a single cross-platform API to enumerate that
storage and pull every record onto the phone.

### Supported families

| Family       | List | Download | Pause / Resume / Cancel | Auto-fetch on recording-finish |
| ---          | ---  | ---      | ---                     | ---                            |
| `bp2`        | yes  | yes      | cancel only             | yes (`ecg_result`/`bp_result`) |
| `er1`        | yes  | yes      | **all three** (Android) | yes (`curStatus == 4`)         |
| `er2`        | yes  | yes      | cancel only             | yes (`curStatus == 4`)         |
| `oxy`        | yes (via `getDeviceInfo`) | yes | cancel only | via new file on list diff |
| `oxyII`      | yes  | yes (Android only — iOS lumps OxyII into `woxi`) | cancel only | via new file on list diff |
| `pf10aw1`    | yes  | yes      | cancel only             | via new file on list diff      |
| `airbp`      | n/a  | n/a — devices have no flash storage             | n/a | n/a              |
| `icomon`     | [`readHistoryData()`](#pulling-everything-stored-on-an-icomon-scale) | offline-replay via `historyData` | n/a | n/a |

### One-shot helper

```dart
import 'package:flutter_ble_devices/flutter_ble_devices.dart';

await for (final file in BluetodevController.downloadAllFiles()) {
  print('Downloaded ${file.fileName} (${file.size} bytes)');
  final bp2 = file.parsed; // SDK-parsed fields, family-specific
  await persist(file.fileName, file.content, parsed: bp2);
}
```

### Manual driving

```dart
// 1. Listen for the file list and the per-file events.
final list = await BluetodevController.fileListEventStream.first;
final progressSub = BluetodevController.fileReadProgressStream.listen((p) {
  print('${p.fileName}: ${(p.progress * 100).toStringAsFixed(0)}%');
});

// 2. Pull each file sequentially.
for (final name in list.files) {
  await BluetodevController.readFile(fileName: name);
  final done = await BluetodevController.fileReadCompleteStream
      .firstWhere((e) => e.fileName == name)
      .timeout(const Duration(seconds: 60));
  await persist(done.fileName, done.content);
}

// 3. Optional: cancel mid-download (ER1 family natively, others via
//    BluetodevController.disconnect()).
await BluetodevController.cancelReadFile();

await progressSub.cancel();
```

### Decoding recorded files in Dart

ER1 / ER2 / BP2 recordings are emitted as raw bytes in the
`fileReadComplete` event. The plugin ships pure-Dart decoders for
those three families that are byte-for-byte compatible with the
official Lepu Android SDK — both platforms run **the same parser**.

```dart
BluetodevController.fileReadCompleteStream.listen((file) {
  switch (file.decoded) {
    case Bp2BpFile bp:
      print('BP at ${bp.measuredAt}: ${bp.sys}/${bp.dia} mmHg, '
            'pr=${bp.pr}${bp.arrhythmia ? " (arrhythmia)" : ""}');
    case Bp2EcgFile ecg:
      print('ECG ${ecg.duration}: hr=${ecg.hr} qrs=${ecg.qrs}ms '
            'findings=${ecg.diagnosis.findings.join(", ")}, '
            '${ecg.waveShortData.length} samples @ ${kBp2EcgSamplingRate} Hz');
    case Er1EcgFile ecg:
      print('${ecg.family} ECG ${ecg.duration}: '
            '${ecg.sampleCount} samples @ ${kEr1EcgSamplingRate} Hz');
  }
});
```

The decoder returns `null` for any other family or when `content` is
empty (in which case the SDK only filled `parsed` — see below).

| Family       | `decoded` type | Header / fields exposed |
| ---          | ---            | ---                     |
| `bp2` (type=1) | [`Bp2BpFile`]  | `sys` / `dia` / `mean` / `pr` / `arrhythmia` / `measuredAt` |
| `bp2` (type=2) | [`Bp2EcgFile`] | `hr` / `qrs` / `pvcs` / `qtc` / `diagnosis` (12-bit findings bitmask) / `waveShortData` (Int16) / `waveFloatData` (mV) / `connectCable` / `recordingTime` / `measuredAt` |
| `er1`, `er2` | [`Er1EcgFile`] | `recordingTime` / `dataCrc` / `magic` / `waveShortData` (Int16) / `waveFloatData` (mV) |

Sampling rates and mV conversion factors are exposed as top-level
constants — `kBp2EcgSamplingRate` (250 Hz), `kBp2EcgMvConversion`
(0.003098), `kEr1EcgSamplingRate` (125 Hz), `kEr1EcgMvConversion`
(≈0.002467). They're identical to what the plugin emits on the
real-time `rtData` stream so a downstream signal-processing pipeline
can use the same code path for both live and recorded data.

The `EcgDiagnosis` class decodes BP2's 32-bit diagnosis bit-mask
(also useful when handling the BP2 RT `ecg_result` measureType).
Sentinel values map verbatim to the Lepu SDK:

- `0` → normal sinus rhythm (`isRegular`)
- `-1` → poor signal (`isPoorSignal`)
- `-2` → lead-off (`isLeadOff`)
- otherwise the low nine bits flag fast / slow / irregular HR, PVCs,
  pause, AFib, wide QRS, prolonged QTc, short QTc.

### `parsed` field reference per family

The `parsed` map on `fileReadComplete` carries the typed fields the
vendor SDK has already decoded for you. On iOS only the legacy O2 path
populates `parsed`; URAT-protocol families (BP2, ER1/ER2, WOxi, FOxi,
ER3, M-series) deliver the raw bytes via `content` and Dart-side
parsing is up to you (or use the decoders above).

| `deviceFamily` | `parsed` keys                                                                                |
| ---            | ---                                                                                          |
| `bp2`          | `fileName`, `type`, `content` (base64) — Android only; use `decoded` for typed fields        |
| `er1`, `er2`   | `fileName`, `content` (base64) — Android only; use `decoded` for typed fields                |
| `oxy`          | `fileType`, `fileVersion`, `recordingTime`, `spo2List`, `prList`, `motionList`, `avgSpo2`, `asleepTime`, `asleepTimePercent` |
| `oxyII`        | `fileType`, `fileVersion`, `deviceModel`, `startTime`, `interval`, `spo2List`, `prList`, `motionList`, `avgSpo2`, `minSpo2`, `avgHr`, `stepCounter`, `o2Score`, `dropsTimes3Percent`, `dropsTimes4Percent`, `dropsTimes90Percent`, `durationTime90Percent`, `percentLessThan90`, `remindHrs`, `remindsSpo2`, `checkSum`, `magic`, `size`, `channelType`, `channelBytes`, `pointBytes` |
| `pf10aw1`      | `fileType`, `fileVersion`, `deviceModel`, `startTime`, `endTime`, `interval`, `spo2List`, `prList`, `checkSum`, `magic`, `size`, `channelType`, `channelBytes`, `pointBytes` |

### Pause / resume / cancel semantics

- **Cancel** – Android sends the ER1-only `er1CancelReadFile` for the
  ER1 family; for every other family the plugin returns `UNSUPPORTED`.
  iOS calls `endReadFile` on the URAT util, which gracefully ends the
  three-step protocol. In all cases [`disconnect()`](#) is the
  guaranteed-clean way to abort.
- **Pause / Resume** – ER1 family on Android only.
  `pauseReadFile()` / `continueReadFile()` map to `er1PauseReadFile`
  / `er1ContinueReadFile`. iOS returns `UNSUPPORTED`.

### Mid-recording catch-up (Lepu ECG / BP devices)

If the phone connects to an ER1 / ER2 / BP2 that is **already in the
middle of a recording** — e.g. the user started the measurement
yesterday — the live `rtData` stream can only carry samples captured
from the moment the subscription attaches. The **full** recording —
including every pre-connection sample — is persisted to the device's
flash the instant the device's `curStatus` transitions into the
"saving succeed" terminal state.

The plugin detects that transition automatically and reacts as follows
(behaviour controlled by the `autoFetchOnFinish` flag on
[`connect()`](#connect), defaulting to `true`):

1. Emits a `recordingFinished` event (observe via
   `recordingFinishedStream`) as soon as the transition fires.
2. Re-issues the family's file-list command.
3. Diffs the fresh list against the baseline captured at connect time
   and auto-pulls every new entry.
4. Each auto-pull fires the usual `fileReadProgress` + `fileReadComplete`
   events, giving the consumer the full recording bytes + SDK-parsed
   fields.

```dart
await BluetodevController.connect(
  model: device.model,
  mac:   device.mac,
  autoFetchOnFinish: true,                  // default
);

BluetodevController.recordingFinishedStream.listen((e) {
  print('${e.deviceFamily} just saved a recording — pulling now…');
});

BluetodevController.fileReadCompleteStream.listen((file) {
  // Fires for both user-initiated readFile() *and* auto-fetched files.
  persist(file.fileName, file.content);
});
```

**Transitions watched**

- ER1 / ER2 — `curStatus == 4` ("saving succeed"), matches Lepu's SDK
  contract verbatim ([source][LepuDemo-ER1]).
- BP2 / BP2A / BP2T — `paramDataType == 1` (`bp_result`) or `3`
  (`ecg_result`).
- Oxy / OxyII / PF10AW1 — delta-detection on the file list itself, so
  any new entry appearing during the session is auto-pulled.

[LepuDemo-ER1]: https://github.com/viatom-develop/LepuDemo#er1-family

### Pulling everything stored on an iComon scale

iComon body-composition scales (Welland, QN-Scale, Adore, Chipsea, and
friends) buffer every measurement taken without the phone present in
their internal flash. Two things happen automatically on BLE
reconnect:

1. The scale replays every buffered record through its normal data
   callbacks — the plugin forwards those as `historyData` events.
2. The same callbacks also fire for kitchen-scale, tape-measure, and
   jump-rope devices, with the `kind` field distinguishing payload
   shapes (`weight` / `kitchenScale` / `ruler` / `skip`).

Listen via `historyDataStream`:

```dart
await BluetodevController.connect(
  sdk: 'icomon',
  mac: scale.mac,
);

BluetodevController.historyDataStream.listen((e) {
  switch (e.kind) {
    case 'weight':
      final ts = e.timestamp;
      print('${ts ?? "unknown time"}: ${e.weightKg} kg'
            ' (impedance ${e.fields["impedance"]})');
      break;
    case 'kitchenScale':
      print('${e.fields["weight_g"]} g');
      break;
  }
});

// Re-trigger the replay explicitly (e.g. after a retry button).
await BluetodevController.readHistoryData();
```

**Notes**

- Firmware keeps roughly the most-recent **~64 records**; older ones
  are discarded silently. There's no way to paginate beyond that.
- `readHistoryData` is a no-op on non-iComon devices and returns
  `UNSUPPORTED` — Lepu/Viatom devices expose their history via the
  file-transfer pipeline instead.
- `onReceiveDeviceInfo` on the iComon SDK carries `isSupportHistoryData`
  for a runtime check if your specific firmware drops the feature.

### Wire format

The native plugins emit four events. Wire keys are stable across
platforms; both Kotlin (`FlutterBleDevicesPlugin.kt`) and Obj-C
(`FlutterBleDevicesPlugin.m`) build the same dictionaries.

```jsonc
{
  "event": "fileList",
  "model": 19,
  "deviceFamily": "bp2",
  "files": ["20240501-093015.bin", ...]
}
{
  "event": "fileReadProgress",
  "model": 19, "deviceFamily": "bp2",
  "fileName": "20240501-093015.bin",
  "progress": 0.42
}
{
  "event": "fileReadComplete",
  "model": 19, "deviceFamily": "bp2",
  "fileName": "20240501-093015.bin",
  "size": 14380,
  "content": "<base64>",          // raw file bytes (when SDK exposes them)
  "parsed":  { "fileName": "...", "type": 1, "content": "<base64>" }
}
{
  "event": "fileReadError",
  "model": 19, "deviceFamily": "bp2",
  "fileName": "20240501-093015.bin",
  "error": "disconnected"
}
{
  "event": "recordingFinished",
  "model": 7, "deviceFamily": "er1"
}
{
  "event": "historyData",
  "kind": "weight",
  "deviceFamily": "icomon",
  "mac": "AA:BB:CC:DD:EE:FF",
  "time": 1714557600,              // Unix seconds (0 if missing)
  "userId": 0,
  "weight_kg": 72.4, "weight_g": 72400,
  "weight_lb": 159.6,
  "precision_kg": 1, "precision_lb": 1,
  "impedance": 487.3
}
```

---

## License

MIT — see [`LICENSE`](./LICENSE). `VTMProductLib` and `lepu-blepro` are
licensed separately by their respective vendors.
