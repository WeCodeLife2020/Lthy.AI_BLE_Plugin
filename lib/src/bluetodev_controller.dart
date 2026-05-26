import 'dart:async';
import 'package:flutter/services.dart';
import 'models/device_control.dart';
import 'models/device_info.dart';
import 'models/file_transfer.dart';
import 'models/measurement_event.dart';

/// Main controller for Viatom/Lepu BLE medical devices.
///
/// Usage:
/// ```dart
/// // 1. Request permissions
/// await BluetodevController.requestPermissions();
///
/// // 2. Initialize BLE service
/// await BluetodevController.initService();
///
/// // 3. Listen to events
/// BluetodevController.eventStream.listen((event) { ... });
///
/// // 4. Start scanning
/// await BluetodevController.scan();
///
/// // 5. Connect to a device
/// await BluetodevController.connect(model: device.model, mac: device.mac);
///
/// // 6. Start real-time measurement
/// await BluetodevController.startMeasurement();
/// ```
class BluetodevController {
  BluetodevController._();

  static const MethodChannel _method = MethodChannel('viatom_ble');
  static const EventChannel _event = EventChannel('viatom_ble_stream');

  static Stream<Map<String, dynamic>>? _eventStream;

  // ════════════════════════════════════════════════════════════════════
  // Event stream
  // ════════════════════════════════════════════════════════════════════

  /// Raw event stream from the native SDK.
  ///
  /// Events have an `event` key indicating the type:
  /// - `serviceReady` — BLE service initialized
  /// - `deviceFound` — device discovered during scan
  /// - `connectionState` — connection state changed
  /// - `rtData` — real-time measurement data
  /// - `rtWaveform` — real-time waveform data
  /// - `deviceInfo` — device information response
  /// - `fileList` — file list response
  static Stream<Map<String, dynamic>> get eventStream {
    _eventStream ??= _event.receiveBroadcastStream().map(
      (event) => Map<String, dynamic>.from(event as Map),
    );
    return _eventStream!;
  }

  /// Stream of discovered devices during scanning.
  static Stream<LepuDeviceInfo> get scanStream => eventStream
      .where((e) => e['event'] == 'deviceFound')
      .map((e) => LepuDeviceInfo.fromMap(e));

  /// Stream of connection state changes.
  static Stream<Map<String, dynamic>> get connectionStream =>
      eventStream.where((e) => e['event'] == 'connectionState');

  /// Stream of real-time measurement data (vitals).
  static Stream<LepuMeasurementEvent> get measurementStream => eventStream
      .where((e) => e['event'] == 'rtData')
      .map((e) => LepuMeasurementEvent.fromMap(e));

  /// Stream of real-time waveform data (ECG, PPG, pleth).
  static Stream<LepuWaveformEvent> get waveformStream => eventStream
      .where((e) => e['event'] == 'rtWaveform')
      .map((e) => LepuWaveformEvent.fromMap(e));

  /// Stream of device info responses.
  static Stream<Map<String, dynamic>> get deviceInfoStream =>
      eventStream.where((e) => e['event'] == 'deviceInfo');

  /// Typed stream of [DeviceConfigEvent]s — emitted in response to
  /// [getDeviceConfig], or spontaneously by some devices after a
  /// `setDeviceConfig` write is acknowledged.
  ///
  /// The set of populated fields is family-dependent — see
  /// [DeviceConfigEvent] for the per-family field reference.
  static Stream<DeviceConfigEvent> get deviceConfigStream => eventStream
      .where((e) => e['event'] == 'deviceConfig')
      .map((e) => DeviceConfigEvent.fromMap(e));

  /// Stream of battery snapshots. Fires on every [getBattery] response,
  /// and also for devices that include battery info in their `rtData`
  /// payload (BP2 / ER1 / ER2 / Oxy / WOxi etc.) — useful for keeping
  /// a "battery" pill in sync without waiting on the next on-demand
  /// query.
  static Stream<BatteryInfo> get batteryStream => eventStream
      .where((e) => e['event'] == 'battery')
      .map((e) => BatteryInfo.fromMap(e));

  /// Raw stream of file-list responses (untyped map; for back-compat).
  static Stream<Map<String, dynamic>> get fileListStream =>
      eventStream.where((e) => e['event'] == 'fileList');

  /// Typed stream of [FileListEvent]s — emitted in response to
  /// [getFileList] when the device returns the list of stored records.
  static Stream<FileListEvent> get fileListEventStream => eventStream
      .where((e) => e['event'] == 'fileList')
      .map((e) => FileListEvent.fromMap(e));

  /// Per-chunk progress events during a [readFile] download.
  ///
  /// Progress is reported as a `0..1` fraction.  Several events are
  /// typically emitted per file (one per BLE chunk on iOS; a few
  /// percentage-step updates per file on Android).
  static Stream<FileReadProgressEvent> get fileReadProgressStream => eventStream
      .where((e) => e['event'] == 'fileReadProgress')
      .map((e) => FileReadProgressEvent.fromMap(e));

  /// Final event of a successful [readFile] call — carries the full
  /// decoded file bytes plus an optional `parsed` map of family-specific
  /// fields the SDK has already extracted.
  static Stream<FileReadCompleteEvent> get fileReadCompleteStream => eventStream
      .where((e) => e['event'] == 'fileReadComplete')
      .map((e) => FileReadCompleteEvent.fromMap(e));

  /// Emitted when a file download fails or is cancelled (e.g. on
  /// disconnect, CRC mismatch, vendor SDK error).
  static Stream<FileReadErrorEvent> get fileReadErrorStream => eventStream
      .where((e) => e['event'] == 'fileReadError')
      .map((e) => FileReadErrorEvent.fromMap(e));

  /// Emitted the moment a Lepu device reports a recording has just been
  /// saved to flash. See [RecordingFinishedEvent] for semantics.
  ///
  /// With `autoFetchOnFinish: true` (the default) the plugin will
  /// immediately issue the resulting `readFile` so you usually only need
  /// [fileReadCompleteStream]; subscribe here if you want to know
  /// *before* the download begins (e.g. to show a spinner).
  static Stream<RecordingFinishedEvent> get recordingFinishedStream =>
      eventStream
          .where((e) => e['event'] == 'recordingFinished')
          .map((e) => RecordingFinishedEvent.fromMap(e));

  /// Offline measurements replayed by iComon scales (body-composition,
  /// kitchen scale, tape measure, or jump rope) — either automatically
  /// right after BLE reconnection, or on demand in response to
  /// [readHistoryData].
  static Stream<HistoryDataEvent> get historyDataStream => eventStream
      .where((e) => e['event'] == 'historyData')
      .map((e) => HistoryDataEvent.fromMap(e));

  // ════════════════════════════════════════════════════════════════════
  // Permissions
  // ════════════════════════════════════════════════════════════════════

  /// Check if BLE permissions are granted.
  static Future<bool> checkPermissions() async {
    final result = await _method.invokeMethod<bool>('checkPermissions');
    return result ?? false;
  }

  /// Request BLE permissions. Returns true if all granted.
  static Future<bool> requestPermissions() async {
    final result = await _method.invokeMethod<bool>('requestPermissions');
    return result ?? false;
  }

  /// Granular permission state for the running OS. Use this when the
  /// boolean returned by [checkPermissions] isn't enough to drive UX
  /// — e.g. to distinguish "user has never been asked" from
  /// "permanently denied — open Settings", or "permissions OK but the
  /// Bluetooth radio is OFF".
  ///
  /// Maps to:
  ///  * **iOS** — `CBCentralManager.state` via
  ///    `[CBCentralManager authorization]` semantics:
  ///    `granted | denied | poweredOff | unsupported | notDetermined`.
  ///  * **Android** — combines `BluetoothManager.adapter.isEnabled`
  ///    with the runtime grant of `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT`
  ///    (S+) or `ACCESS_FINE_LOCATION` (pre-S).
  ///
  /// Returns [BlePermissionState.notDetermined] if the native side
  /// can't be reached (e.g. plugin not yet initialised on this
  /// platform).
  static Future<BlePermissionState> getPermissionState() async {
    try {
      final raw = await _method.invokeMethod<String>('getPermissionState');
      return BlePermissionState.fromWire(raw);
    } on PlatformException {
      return BlePermissionState.notDetermined;
    }
  }

  // ════════════════════════════════════════════════════════════════════
  // Service lifecycle
  // ════════════════════════════════════════════════════════════════════

  /// Initialize the BLE service. Must be called before any other method.
  static Future<bool> initService() async {
    final result = await _method.invokeMethod<bool>('initService');
    return result ?? false;
  }

  /// Check if the BLE service is ready.
  static Future<bool> isServiceReady() async {
    final result = await _method.invokeMethod<bool>('isServiceReady');
    return result ?? false;
  }

  /// Update the internal user profile for iComon scales. This is the
  /// **shorthand** form that mirrors the original 0.x API — accepts
  /// just height / age / sex and uses the documented iComon defaults
  /// for everything else (userIndex=1, peopleType=normal,
  /// weightUnit=kg, all measurement flags enabled).
  ///
  /// For multi-user setups or to override units, prefer
  /// [setScaleUserProfile] with a fully-populated [ScaleUserProfile].
  static Future<bool> updateUserInfo({
    required double height,
    required int age,
    required bool isMale,
  }) async {
    final result = await _method.invokeMethod<bool>('updateUserInfo', {
      'height': height,
      'age': age,
      'isMale': isMale,
    });
    return result ?? false;
  }

  /// Push a single, fully-populated [ScaleUserProfile] to the iComon
  /// SDK's *global* user context — equivalent to the iOS
  /// `[ICDeviceManager updateUserInfo:]` call. Use this **before**
  /// connecting if you want the first weigh-in to apply the correct
  /// BFA algorithm and unit.
  ///
  /// For W-series scales that store multiple profiles on-device, also
  /// call [setScaleUserList] with the full list.
  static Future<bool> setScaleUserProfile(ScaleUserProfile profile) async {
    final result = await _method.invokeMethod<bool>(
      'setScaleUserProfile',
      profile.toMap(),
    );
    return result ?? false;
  }

  /// Push the entire multi-user list to a W-series iComon scale —
  /// equivalent to `setUserList_W:` upstream. Older scales without
  /// multi-user storage will return `false` (the native layer
  /// reflects the SDK's `ICSettingCallBackCodeNotSupportFunction`).
  ///
  /// The list order does NOT have to match `userIndex` — the SDK
  /// reads `userIndex` off each entry to route the profile to the
  /// correct on-device slot.
  static Future<bool> setScaleUserList(List<ScaleUserProfile> profiles) async {
    final result = await _method.invokeMethod<bool>('setScaleUserList', {
      'profiles': profiles.map((p) => p.toMap()).toList(),
    });
    return result ?? false;
  }

  /// Change the weight unit shown on the connected body scale.
  /// Emits a `scaleUnitChanged` event with `subEvent: 'weight'` once
  /// the device acks (also fires when the user flips the unit on
  /// the device itself).
  static Future<bool> setScaleWeightUnit(ScaleWeightUnit unit) async {
    final result = await _method.invokeMethod<bool>('setScaleWeightUnit', {
      'unit': unit.wire,
    });
    return result ?? false;
  }

  /// Change the tape-measure unit on the connected iComon ruler.
  static Future<bool> setScaleRulerUnit(ScaleRulerUnit unit) async {
    final result = await _method.invokeMethod<bool>('setScaleRulerUnit', {
      'unit': unit.wire,
    });
    return result ?? false;
  }

  /// Change the unit on the connected iComon kitchen scale.
  static Future<bool> setKitchenScaleUnit(KitchenScaleUnit unit) async {
    final result = await _method.invokeMethod<bool>('setKitchenScaleUnit', {
      'unit': unit.wire,
    });
    return result ?? false;
  }

  // ════════════════════════════════════════════════════════════════════
  // Scanning
  // ════════════════════════════════════════════════════════════════════

  /// Start scanning for BLE devices.
  ///
  /// Optionally filter by [models] (Lepu SDK model constants).
  /// If not specified, scans for all supported devices.
  static Future<bool> scan({List<int>? models}) async {
    final result = await _method.invokeMethod<bool>('scan', {
      'models': ?models,
    });
    return result ?? false;
  }

  /// Stop scanning.
  static Future<bool> stopScan() async {
    final result = await _method.invokeMethod<bool>('stopScan');
    return result ?? false;
  }

  // ════════════════════════════════════════════════════════════════════
  // Connection
  // ════════════════════════════════════════════════════════════════════

  /// Connect to a device by [mac] address.
  ///
  /// For Lepu devices, [model] is required.
  /// For iComon devices, pass [sdk] = 'icomon'.
  /// The device must first be discovered via [scan].
  ///
  /// When [autoFetchOnFinish] is `true` (the default), the native layer
  /// watches for the "recording saved" transition on Lepu ER1/ER2/BP2
  /// devices and automatically pulls the resulting file. This gives the
  /// consumer the **full** recording — including samples captured before
  /// the phone connected — as a [FileReadCompleteEvent]. Set to `false`
  /// if you want to orchestrate the download yourself.
  static Future<bool> connect({
    int? model,
    required String mac,
    String sdk = 'lepu',
    bool autoFetchOnFinish = true,
  }) async {
    final result = await _method.invokeMethod<bool>('connect', {
      'model': ?model,
      'mac': mac,
      'sdk': sdk,
      'autoFetchOnFinish': autoFetchOnFinish,
    });
    return result ?? false;
  }

  /// Connect to a previously-paired device by [mac] without a fresh
  /// [scan] step.
  ///
  /// Use this on app launch to re-attach to the user's last device
  /// without forcing a UI scan. On both platforms the underlying SDK
  /// is asked for the peripheral by identifier:
  ///
  ///  * **iOS** — `[CBCentralManager retrievePeripheralsWithIdentifiers:]`
  ///  * **Android** — `BluetoothAdapter.getRemoteDevice(mac)`
  ///
  /// Falls back to a short (≤10 s) scan if the OS no longer remembers
  /// the peripheral (e.g. fresh install, BT cache cleared). The
  /// resulting connection is identical to one established via
  /// [connect] — same `connectionState` events, same `autoFetchOnFinish`
  /// semantics.
  ///
  /// For iComon scales, [model] is ignored and you should pass
  /// `sdk: 'icomon'`. For every other family [model] is required.
  static Future<bool> connectKnown({
    int? model,
    required String mac,
    String sdk = 'lepu',
    bool autoFetchOnFinish = true,
  }) async {
    final result = await _method.invokeMethod<bool>('connectKnown', {
      'model': ?model,
      'mac': mac,
      'sdk': sdk,
      'autoFetchOnFinish': autoFetchOnFinish,
    });
    return result ?? false;
  }

  /// Disconnect from the currently connected device.
  static Future<bool> disconnect() async {
    final result = await _method.invokeMethod<bool>('disconnect');
    return result ?? false;
  }

  // ════════════════════════════════════════════════════════════════════
  // Time sync
  // ════════════════════════════════════════════════════════════════════

  /// Push the phone's clock to the connected device so on-device
  /// recordings carry an accurate timestamp.
  ///
  /// Without this, BP2 / ER1 / ER2 / O2Ring records drift after every
  /// battery change because the device falls back to its factory RTC.
  ///
  /// The native bridge picks the right vendor call by family:
  ///
  ///  * **iOS URAT family** — `[VTMURATUtils syncTime:]` with the
  ///    supplied [time] (default `DateTime.now()`).
  ///  * **iOS legacy O2 family** — `[VTO2Communicate setRtcTime:]`.
  ///  * **Android (lepu-blepro)** — `BleServiceHelper.syncTime(model)`.
  ///    The Lepu helper always uses the phone's current time, so the
  ///    [time] argument is ignored on Android. Pass `null` (the
  ///    default) to make this explicit.
  ///
  /// Returns `false` if the device family doesn't expose a sync
  /// primitive (iComon scales, AirBP, PC60FW family).
  static Future<bool> syncTime({int? model, DateTime? time}) async {
    final ms = time?.millisecondsSinceEpoch;
    final result = await _method.invokeMethod<bool>('syncTime', {
      'model': ?model,
      'epochMs': ?ms,
    });
    return result ?? false;
  }

  // ════════════════════════════════════════════════════════════════════
  // Battery query
  // ════════════════════════════════════════════════════════════════════

  /// Request a one-shot battery reading from the connected device.
  ///
  /// Resolves with the next [BatteryInfo] event the device emits, or
  /// times out (default 5 s) on devices that don't acknowledge.
  ///
  /// Coverage:
  ///
  ///  * **iOS** — every URAT-family device + legacy O2 ring. Universal.
  ///  * **Android** — only AirBP, AP20, SP20, LEM, OxyII, and PC80B
  ///    expose an on-demand battery query. For BP2 / ER1 / ER2 / Oxy
  ///    /etc., the Lepu SDK ships battery as a side-effect of the
  ///    real-time data stream — start a measurement and listen on
  ///    [batteryStream] (or [measurementStream] for the per-rt-data
  ///    `battery` field) to read the value.
  ///
  /// Throws a [PlatformException] with code `UNSUPPORTED` on the
  /// Android-only families that have no direct query.
  static Future<BatteryInfo?> getBattery({
    int? model,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final next = batteryStream.first.timeout(
      timeout,
      onTimeout: () =>
          throw TimeoutException('getBattery: device did not respond', timeout),
    );
    final ok = await _method.invokeMethod<bool>('getBattery', {
      'model': ?model,
    });
    if (ok != true) return null;
    return next;
  }

  // ════════════════════════════════════════════════════════════════════
  // Device configuration
  // ════════════════════════════════════════════════════════════════════

  /// Request the connected device's saved configuration.
  ///
  /// Resolves with the next [DeviceConfigEvent] the device emits.
  /// The shape of [DeviceConfigEvent.fields] is family-dependent — see
  /// the [ConfigField] doc for the keys each family understands.
  ///
  /// Supported families:
  ///
  ///  * **BP family** — BP2 / BP2A / BP2T / BP3 / BP3* (Android only
  ///    for BP3; iOS exposes the richer BP2 config struct).
  ///  * **WOxi family** — O2Ring S, S8/AW, BAND-WU and similar
  ///    (iOS-only request — Android's lepu-blepro uses `oxy2*`
  ///    methods which are wired separately; see
  ///    [DeviceConfigEvent.family] == `oxy2` events).
  ///  * **FOxi family** — PF-10BWS and similar.
  ///  * **ER1 / ER2** — Android only.
  ///  * **PF10AW1** — both platforms.
  ///
  /// Returns null if the call could not be issued (e.g. device not
  /// connected, unsupported family).
  static Future<DeviceConfigEvent?> getDeviceConfig({
    int? model,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final next = deviceConfigStream.first.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'getDeviceConfig: device did not respond',
        timeout,
      ),
    );
    final ok = await _method.invokeMethod<bool>('getDeviceConfig', {
      'model': ?model,
    });
    if (ok != true) return null;
    return next;
  }

  /// Push one or more configuration fields to the connected device.
  ///
  /// Use [ConfigField] for each setting you want to change — see the
  /// [ConfigField] doc for the family-specific field names.
  ///
  /// On WOxi/FOxi devices the protocol writes one field at a time, so
  /// passing N fields produces N round-trips. On BP2 / ER1 / ER2 / BP3
  /// the SDK sends a struct in one shot with the supplied fields
  /// merged on top of the current config.
  ///
  /// Returns `true` if every write was accepted by the SDK.
  static Future<bool> setDeviceConfig(
    List<ConfigField> fields, {
    int? model,
  }) async {
    final list = fields.map((f) => f.toMap()).toList();
    final ok = await _method.invokeMethod<bool>('setDeviceConfig', {
      'model': ?model,
      'fields': list,
    });
    return ok ?? false;
  }

  /// Get the currently connected device model, or -1 if none.
  static Future<int> getConnectedModel() async {
    final result = await _method.invokeMethod<int>('getConnectedModel');
    return result ?? -1;
  }

  // ════════════════════════════════════════════════════════════════════
  // Real-time measurement
  // ════════════════════════════════════════════════════════════════════

  /// Start real-time measurement streaming.
  ///
  /// Optionally specify [model] to start RT task for a specific device.
  ///
  /// On iOS the [mode] argument is honoured for BP devices (BP2 / BP2A /
  /// BP2T / BP2W / BP3*) and selects which internal state the device is
  /// switched to before polling begins:
  ///  - `'bp'`      → blood pressure measurement (default)
  ///  - `'ecg'`     → ECG-lead-I measurement
  ///  - `'history'` → history review
  ///  - `'ready'`   → power-on / idle
  ///  - `'off'`     → request shutdown
  ///
  /// For all other device families the argument is ignored — Android's
  /// `BleServiceHelper.startRtTask(model)` makes the same decision
  /// implicitly based on the model id, so you can always pass the mode
  /// and expect identical behaviour on both platforms.
  static Future<bool> startMeasurement({int? model, String? mode}) async {
    final result = await _method.invokeMethod<bool>('startMeasurement', {
      'model': ?model,
      'mode': ?mode,
    });
    return result ?? false;
  }

  /// Stop real-time measurement streaming.
  static Future<bool> stopMeasurement({int? model}) async {
    final result = await _method.invokeMethod<bool>('stopMeasurement', {
      'model': ?model,
    });
    return result ?? false;
  }

  // ════════════════════════════════════════════════════════════════════
  // Device management
  // ════════════════════════════════════════════════════════════════════

  /// Request device information from the connected device.
  static Future<bool> getDeviceInfo({int? model}) async {
    final result = await _method.invokeMethod<bool>('getDeviceInfo', {
      'model': ?model,
    });
    return result ?? false;
  }

  /// Request the file list from the connected device.
  ///
  /// Listen on [fileListEventStream] (or the legacy [fileListStream]) for
  /// the response.  Supported on every family that has on-device storage
  /// (BP2, ER1/ER2, Oxy, OxyII, PF10AW1).  Returns `UNSUPPORTED` for
  /// iComon scales and AirBP devices (which have no flash to enumerate).
  static Future<bool> getFileList({int? model}) async {
    final result = await _method.invokeMethod<bool>('getFileList', {
      'model': ?model,
    });
    return result ?? false;
  }

  // ════════════════════════════════════════════════════════════════════
  // File transfer (history download)
  // ════════════════════════════════════════════════════════════════════

  /// Begin downloading a single file by [fileName] from the connected
  /// device.  Returns immediately — observe [fileReadProgressStream],
  /// [fileReadCompleteStream], and [fileReadErrorStream] for results.
  ///
  /// Typical flow:
  /// ```dart
  /// final list = await BluetodevController.fileListEventStream.first;
  /// for (final name in list.files) {
  ///   await BluetodevController.readFile(fileName: name);
  ///   final done = await BluetodevController.fileReadCompleteStream.first;
  ///   await persist(done.fileName, done.content);
  /// }
  /// ```
  ///
  /// Only one read can be in flight at a time on iOS — calling [readFile]
  /// again before [fileReadCompleteStream] (or [fileReadErrorStream])
  /// fires returns a `BUSY` MethodChannel error.  Android can in
  /// principle multiplex but the Lepu SDK serialises requests internally,
  /// so the same one-at-a-time discipline is recommended.
  static Future<bool> readFile({int? model, required String fileName}) async {
    final result = await _method.invokeMethod<bool>('readFile', {
      'model': ?model,
      'fileName': fileName,
    });
    return result ?? false;
  }

  /// Cancel an in-flight [readFile] download.
  ///
  /// Only the ER1 family natively supports mid-download cancellation; for
  /// every other family [cancelReadFile] either ends the URAT session
  /// (iOS) or returns `UNSUPPORTED` (Android non-ER1).  In both cases
  /// disconnecting via [disconnect] is a guaranteed-clean way to stop a
  /// download, at the cost of having to reconnect afterwards.
  static Future<bool> cancelReadFile({int? model}) async {
    final result = await _method.invokeMethod<bool>('cancelReadFile', {
      'model': ?model,
    });
    return result ?? false;
  }

  /// Pause an in-flight ER1 file download (ER1 family only).
  ///
  /// Returns `UNSUPPORTED` on every other family and on iOS.
  static Future<bool> pauseReadFile({int? model}) async {
    final result = await _method.invokeMethod<bool>('pauseReadFile', {
      'model': ?model,
    });
    return result ?? false;
  }

  /// Resume a paused ER1 file download (ER1 family only).
  ///
  /// Returns `UNSUPPORTED` on every other family and on iOS.
  static Future<bool> continueReadFile({int? model}) async {
    final result = await _method.invokeMethod<bool>('continueReadFile', {
      'model': ?model,
    });
    return result ?? false;
  }

  /// Convenience helper that drives [getFileList] and downloads every
  /// listed file sequentially.  Yields one [FileReadCompleteEvent] per
  /// successful download, and stops on the first
  /// [FileReadErrorEvent] (which the caller can `await`-catch).
  ///
  /// ```dart
  /// await for (final file in BluetodevController.downloadAllFiles()) {
  ///   await persist(file.fileName, file.content);
  /// }
  /// ```
  ///
  /// The default per-file timeout is 60 s; pass [perFileTimeout] to
  /// override (e.g. for very long oximetry recordings).
  static Stream<FileReadCompleteEvent> downloadAllFiles({
    int? model,
    Duration perFileTimeout = const Duration(seconds: 60),
  }) async* {
    // Kick off the listing first so we have a list to iterate over.
    final listFuture = fileListEventStream.first.timeout(
      const Duration(seconds: 10),
    );
    final ok = await getFileList(model: model);
    if (!ok) {
      throw StateError('getFileList returned false');
    }
    final list = await listFuture;
    if (list.files.isEmpty) return;

    for (final name in list.files) {
      // Keep listening for the next complete/error before we issue the
      // download — first() must be subscribed before the native side
      // has a chance to emit.
      final completeF = fileReadCompleteStream
          .firstWhere((e) => e.fileName == name)
          .timeout(perFileTimeout);
      final errorF = fileReadErrorStream
          .firstWhere((e) => e.fileName == null || e.fileName == name)
          .timeout(perFileTimeout);

      final started = await readFile(model: model, fileName: name);
      if (!started) continue;

      // Race the two futures — whichever fires first wins.
      final result = await Future.any<dynamic>([completeF, errorF]);
      if (result is FileReadErrorEvent) {
        throw StateError('Download of $name failed: ${result.error}');
      }
      yield result as FileReadCompleteEvent;
    }
  }

  // ════════════════════════════════════════════════════════════════════
  // iComon-scale offline history
  // ════════════════════════════════════════════════════════════════════

  /// Ask a connected iComon scale (body-composition, kitchen, tape
  /// measure, or jump rope) to replay every measurement it has cached
  /// on internal flash. Each record arrives as a [HistoryDataEvent] on
  /// [historyDataStream].
  ///
  /// In practice the scale also auto-uploads the same records
  /// immediately after a BLE reconnect; this method exists so a
  /// consumer can re-trigger the pull explicitly (e.g. after toggling
  /// airplane mode or if the auto-upload was missed).
  ///
  /// Returns `UNSUPPORTED` for Lepu / Viatom devices — they expose
  /// per-file downloads via [readFile] instead.
  static Future<bool> readHistoryData() async {
    final result = await _method.invokeMethod<bool>('readHistoryData');
    return result ?? false;
  }

  /// Factory reset the connected device.
  static Future<bool> factoryReset({int? model}) async {
    final result = await _method.invokeMethod<bool>('factoryReset', {
      'model': ?model,
    });
    return result ?? false;
  }

  /// Politely power the connected device off.
  ///
  /// Coverage is currently sparse upstream:
  ///
  ///  * **iOS BP2 family** — issues `VTMBPTargetStatusEnd`, the same
  ///    opcode `startMeasurement(mode: "off")` already uses.
  ///  * **iOS iComon kitchen scale** — `powerOffKitchenScale:` from
  ///    `ICDeviceManagerSettingManager`.
  ///  * **iOS legacy O2 / URAT non-BP / Android any-family** — no
  ///    shutdown opcode is exposed by the underlying SDK; this method
  ///    returns `false` (after throwing `UNSUPPORTED` on the platform
  ///    channel, swallowed here). Consumers should call [disconnect]
  ///    as a fallback.
  ///
  /// Returns `true` if the device acked the shutdown request.
  static Future<bool> shutdown({int? model}) async {
    try {
      final result = await _method.invokeMethod<bool>('shutdown', {
        'model': ?model,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'UNSUPPORTED') return false;
      rethrow;
    }
  }
}
