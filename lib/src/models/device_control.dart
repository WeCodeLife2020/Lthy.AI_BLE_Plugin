// Device-control models — battery query and read/write config.
//
// These types back the cross-platform device-management API added in
// the ViHealth-parity milestone (`syncTime`, `getBattery`,
// `getDeviceConfig` / `setDeviceConfig`). The native plugins emit
// dictionary events with a stable wire format; the classes here are
// the typed view of those dictionaries plus simple `toMap()` helpers
// for the write path.
//
// Wire-format reference is the README's `## Stream events` section.

/// One-shot battery info reported in response to
/// [BluetodevController.getBattery] (and bundled as a side-effect of
/// every `rtData` event on devices that include battery in their
/// real-time payload).
class BatteryInfo {
  /// Battery level (0-100).
  ///
  /// Some families (notably PF10AW1) report a coarse 0..3 level via
  /// [batLevel] instead; in that case [percent] is null.
  final int? percent;

  /// Coarse battery level (0..3) reported by PF10AW1/FOxi devices.
  /// Null on every other family.
  final int? batLevel;

  /// Battery state, mapped to the Viatom enum:
  ///   0 = normal use, 1 = charging, 2 = fully charged, 3 = low
  /// May be null on Android families that don't expose state separately.
  final int? state;

  /// Battery voltage in mV (some firmwares only). 0/null when absent.
  final int? voltageMv;

  /// Lepu model id this reading came from, or -1 for legacy paths.
  final int model;

  /// Device family the reading came from, e.g. `bp2`, `oxy`, `pf10aw1`.
  /// Always present; defaults to `"unknown"` on legacy paths.
  final String family;

  const BatteryInfo({
    required this.model,
    required this.family,
    this.percent,
    this.batLevel,
    this.state,
    this.voltageMv,
  });

  factory BatteryInfo.fromMap(Map<String, dynamic> map) {
    // Both iOS and Android publish the same keys; the native code
    // does the work of converting per-family struct shapes into this
    // common envelope before posting.
    return BatteryInfo(
      model: (map['model'] as int?) ?? -1,
      family:
          (map['family'] as String?) ??
          (map['deviceFamily'] as String?) ??
          'unknown',
      percent: map['percent'] as int?,
      batLevel: map['batLevel'] as int?,
      state: map['state'] as int?,
      voltageMv: map['voltage'] as int?,
    );
  }

  @override
  String toString() =>
      'BatteryInfo(family=$family, model=$model, '
      'percent=$percent, batLevel=$batLevel, state=$state)';
}

/// Snapshot of a device's configuration, returned by
/// [BluetodevController.getDeviceConfig] and emitted on
/// [BluetodevController.deviceConfigStream] when the device pushes
/// the response.
///
/// The set of populated fields is family-dependent — see
/// [DeviceConfigEvent.fields] for the family-specific names and
/// units. All known scalar values are exposed verbatim under that map;
/// the convenience getters ([volume], [brightness], etc.) cover the
/// most common ones across families.
class DeviceConfigEvent {
  /// e.g. `bp2`, `woxi`, `foxi`, `er1`, `er2`, `pf10aw1`, `bp3`, `oxy2`.
  final String family;

  /// Lepu model id this config came from. -1 on legacy paths.
  final int model;

  /// Family-specific raw fields. Keys come straight from the native
  /// emitter — kept verbatim so a future config field added on the
  /// native side automatically flows through Dart without needing a
  /// model change. Field names are documented in the README.
  final Map<String, Object?> fields;

  const DeviceConfigEvent({
    required this.family,
    required this.model,
    required this.fields,
  });

  factory DeviceConfigEvent.fromMap(Map<String, dynamic> map) {
    // Defensive copy so consumers can mutate the map they receive
    // without poisoning the stream's internal record.
    final fields = <String, Object?>{};
    for (final entry in map.entries) {
      if (entry.key == 'event' ||
          entry.key == 'family' ||
          entry.key == 'model' ||
          entry.key == 'deviceFamily') {
        continue;
      }
      fields[entry.key] = entry.value;
    }
    return DeviceConfigEvent(
      family:
          (map['family'] as String?) ??
          (map['deviceFamily'] as String?) ??
          'unknown',
      model: (map['model'] as int?) ?? -1,
      fields: fields,
    );
  }

  /// Sound/volume level when the family exposes one (BP2 / BP3 /
  /// WOxi `buzzer`). Returns null on families that don't.
  int? get volume {
    final v = fields['volume'] ?? fields['buzzer'];
    return (v is int) ? v : null;
  }

  /// Screen brightness when the family exposes one (WOxi). Null
  /// elsewhere.
  int? get brightness {
    final v = fields['brightness'];
    return (v is int) ? v : null;
  }

  /// SpO2 low-threshold alarm setpoint, in percent (WOxi `spo2Thr`,
  /// FOxi `spo2Low`, PF10AW1 `spo2Low`).
  int? get spo2Threshold {
    final v = fields['spo2Thr'] ?? fields['spo2Low'];
    return (v is int) ? v : null;
  }

  /// Pulse-rate alarm low threshold (WOxi `hrThrLow`, FOxi `prLow`,
  /// PF10AW1 `prLow`).
  int? get pulseRateLow {
    final v = fields['hrThrLow'] ?? fields['prLow'];
    return (v is int) ? v : null;
  }

  /// Pulse-rate alarm high threshold (WOxi `hrThrHigh`, FOxi `prHigh`,
  /// PF10AW1 `prHi` / `prHigh`).
  int? get pulseRateHigh {
    final v = fields['hrThrHigh'] ?? fields['prHigh'] ?? fields['prHi'];
    return (v is int) ? v : null;
  }

  @override
  String toString() =>
      'DeviceConfigEvent($family/model=$model, fields=${fields.length})';
}

/// One field name + value to write via
/// [BluetodevController.setDeviceConfig].
///
/// The Viatom WOxi/FOxi protocols set configuration one field at a
/// time (vendor-defined enum + 32-bit value). The Lepu Android SDK
/// likewise takes a per-family struct, but consumers typically only
/// want to flip one or two settings — so the Dart API takes a list of
/// these to keep both bridges shape-uniform.
///
/// Valid [name]s by family:
///
///  * `bp2` — `soundOn` (bool), and (iOS only) `volume`, `brightness`,
///            `avgMeasureMode`, `unit`, `language`.
///  * `bp3` — `soundOn` (bool), `volume` (0..3), `avgMeasureMode` (0..4).
///  * `woxi` — `spo2Thr`, `hrThrLow`, `hrThrHigh`, `motor`, `buzzer`,
///             `brightness`, `interval`, `displayMode`,
///             `spo2RemindSw` (bit-flag), `hrRemindSw` (bit-flag).
///  * `foxi` — `spo2Low`, `prHigh`, `prLow`, `alarm` (bool),
///             `measureMode`, `beep` (bool), `language`, `bleSw` (bool),
///             `esMode`.
///  * `er1`  — `vibration` (bool), `threshold1`, `threshold2`.
///  * `er2`  — `soundOn` (bool), `vector`, `motionCount`, `motionWindows`.
///  * `pf10aw1` — `spo2Low`, `prHi`, `prLow`, `alarmOn` (bool),
///                `beepOn` (bool), `esMode`.
class ConfigField {
  final String name;
  final Object value;

  const ConfigField(this.name, this.value);

  Map<String, Object> toMap() => {'name': name, 'value': value};
}

/// Weight unit reported by — and writable to — iComon body / kitchen
/// scales via [BluetodevController.setScaleWeightUnit] /
/// [BluetodevController.setScaleUserProfile].
///
/// Wire format mirrors `ICWeightUnit`:
/// `kg=0, lb=1, st=2, jin=3`.
enum ScaleWeightUnit {
  kg,
  lb,
  st,

  /// Jin (Chinese-market pound, 500 g).
  jin;

  int get wire => index;

  static ScaleWeightUnit fromWire(int v) =>
      v >= 0 && v < ScaleWeightUnit.values.length
      ? ScaleWeightUnit.values[v]
      : ScaleWeightUnit.kg;
}

/// Tape-measure unit used by iComon ruler accessories.
///
/// Wire format mirrors `ICRulerUnit` — note that the enum is **1-indexed**
/// in the SDK (cm=1, inch=2, ftInch=3).
enum ScaleRulerUnit {
  cm,
  inch,
  ftInch;

  /// 1-indexed wire value matching `ICRulerUnit` upstream.
  int get wire => index + 1;

  static ScaleRulerUnit fromWire(int v) {
    final i = v - 1;
    return i >= 0 && i < ScaleRulerUnit.values.length
        ? ScaleRulerUnit.values[i]
        : ScaleRulerUnit.cm;
  }
}

/// Unit used by iComon kitchen scales.
///
/// Wire format mirrors `ICKitchenScaleUnit`:
/// `g=0, ml=1, lb=2, oz=3, mg=4, mlMilk=5, flOzWater=6, flOzMilk=7`.
enum KitchenScaleUnit {
  g,
  ml,
  lb,
  oz,
  mg,
  mlMilk,
  flOzWater,
  flOzMilk;

  int get wire => index;

  static KitchenScaleUnit fromWire(int v) =>
      v >= 0 && v < KitchenScaleUnit.values.length
      ? KitchenScaleUnit.values[v]
      : KitchenScaleUnit.g;
}

/// Sex flag pushed to scales for BFA / body-water computation.
///
/// Wire format matches `ICSexType`:
/// `unknown=0, male=1, female=2`.
enum ScaleSex {
  unknown,
  male,
  female;

  int get wire => index;

  static ScaleSex fromWire(int v) => v >= 0 && v < ScaleSex.values.length
      ? ScaleSex.values[v]
      : ScaleSex.unknown;
}

/// People type pushed to scales — flips the BFA algorithm between
/// the general-population curve and the athletic curve (lower-body-fat
/// baseline).
///
/// Wire format matches `ICPeopleType`: `normal=0, athlete=1`.
enum ScalePeopleType {
  normal,
  athlete;

  int get wire => index;

  static ScalePeopleType fromWire(int v) =>
      v >= 0 && v < ScalePeopleType.values.length
      ? ScalePeopleType.values[v]
      : ScalePeopleType.normal;
}

/// One profile slot on an iComon scale that supports multi-user
/// recognition (W-series scales recognise the user automatically
/// from height + last-known-weight; older scales require an explicit
/// `userIndex` selection).
///
/// Backs the `setScaleUserProfile` / `setScaleUserList` Dart APIs and
/// the `scaleUserInfo` / `scaleUserList` events emitted by the
/// native plugins.
class ScaleUserProfile {
  /// 1-indexed user slot on the device. Older iComon scales support
  /// 1..8 users; W-series scales accept arbitrary ids assigned at
  /// pair time. Default `1`.
  final int userIndex;

  /// User id, used by W-series scales for cloud sync. Pass `0` for
  /// non-W-series devices.
  final int userId;

  /// Optional nickname, shown on W-series LCDs that have a screen.
  final String? nickName;

  /// Height in centimetres. Required for body-fat-algorithm.
  final int heightCm;

  /// Age in years. Required for body-fat-algorithm.
  final int age;

  /// Sex. Required for body-fat-algorithm.
  final ScaleSex sex;

  /// Last-known weight in kilograms. Used by W-series scales for
  /// auto-recognition; pass `0` for non-W-series.
  final double lastWeightKg;

  /// People type — flips the BFA algorithm between normal and
  /// athletic baselines.
  final ScalePeopleType peopleType;

  /// Default weight unit shown on the scale's display for this user.
  final ScaleWeightUnit weightUnit;

  /// Default tape-measure unit for this user.
  final ScaleRulerUnit rulerUnit;

  /// Default kitchen-scale unit for this user.
  final KitchenScaleUnit kitchenUnit;

  /// Feature-flag — enable impedance (body-fat) measurement. Default
  /// `true`; set to `false` on scales that report bogus impedance
  /// (e.g. user wearing thick socks).
  final bool enableImpedance;

  /// Feature-flag — enable heart-rate readout on scales that support
  /// it (iC-2 and newer). Default `true`.
  final bool enableHeartRate;

  /// Feature-flag — enable left/right balance readout. Default `true`.
  final bool enableBalance;

  /// Feature-flag — enable centre-of-gravity readout. Default `true`.
  final bool enableGravity;

  const ScaleUserProfile({
    this.userIndex = 1,
    this.userId = 0,
    this.nickName,
    this.heightCm = 170,
    this.age = 25,
    this.sex = ScaleSex.male,
    this.lastWeightKg = 60.0,
    this.peopleType = ScalePeopleType.normal,
    this.weightUnit = ScaleWeightUnit.kg,
    this.rulerUnit = ScaleRulerUnit.cm,
    this.kitchenUnit = KitchenScaleUnit.g,
    this.enableImpedance = true,
    this.enableHeartRate = true,
    this.enableBalance = true,
    this.enableGravity = true,
  });

  /// Build a profile from the dictionary the native plugins emit on
  /// the `scaleUserInfo` event. Missing keys fall back to the
  /// constructor defaults so a partial payload (e.g. older scale
  /// firmware that doesn't report `nickName`) still produces a
  /// usable profile.
  factory ScaleUserProfile.fromMap(Map<dynamic, dynamic> map) {
    int readInt(String k, [int d = 0]) => (map[k] as num?)?.toInt() ?? d;
    double readDouble(String k, [double d = 0]) =>
        (map[k] as num?)?.toDouble() ?? d;
    bool readBool(String k, [bool d = true]) => (map[k] as bool?) ?? d;
    return ScaleUserProfile(
      userIndex: readInt('userIndex', 1),
      userId: readInt('userId'),
      nickName: map['nickName'] as String?,
      heightCm: readInt('heightCm', 170),
      age: readInt('age', 25),
      sex: ScaleSex.fromWire(readInt('sex', 1)),
      lastWeightKg: readDouble('lastWeightKg', 60.0),
      peopleType: ScalePeopleType.fromWire(readInt('peopleType')),
      weightUnit: ScaleWeightUnit.fromWire(readInt('weightUnit')),
      rulerUnit: ScaleRulerUnit.fromWire(readInt('rulerUnit', 1)),
      kitchenUnit: KitchenScaleUnit.fromWire(readInt('kitchenUnit')),
      enableImpedance: readBool('enableImpedance'),
      enableHeartRate: readBool('enableHeartRate'),
      enableBalance: readBool('enableBalance'),
      enableGravity: readBool('enableGravity'),
    );
  }

  /// Serialise the profile to the dictionary the native plugins
  /// accept for `setScaleUserProfile` / `setScaleUserList`. Every
  /// key matches the constructor parameter name 1:1 so the round
  /// trip is byte-for-byte symmetric.
  Map<String, Object?> toMap() => {
    'userIndex': userIndex,
    'userId': userId,
    'nickName': nickName,
    'heightCm': heightCm,
    'age': age,
    'sex': sex.wire,
    'lastWeightKg': lastWeightKg,
    'peopleType': peopleType.wire,
    'weightUnit': weightUnit.wire,
    'rulerUnit': rulerUnit.wire,
    'kitchenUnit': kitchenUnit.wire,
    'enableImpedance': enableImpedance,
    'enableHeartRate': enableHeartRate,
    'enableBalance': enableBalance,
    'enableGravity': enableGravity,
  };
}

/// Granular reply from [BluetodevController.getPermissionState].
///
/// Distinguishing between these states lets consumers route the UX
/// correctly: only [denied] should send the user to the OS settings
/// app; [notDetermined] should trigger the runtime prompt;
/// [poweredOff] should ask the user to flip Bluetooth on; [granted]
/// is the happy path.
enum BlePermissionState {
  /// All necessary permissions are granted AND the Bluetooth radio
  /// is currently on. Scan/connect calls will succeed.
  granted,

  /// The user denied (or permanently denied) at least one of the
  /// runtime permissions. The consumer should send them to the OS
  /// settings app — calling `requestPermissions` again will be a
  /// no-op because the OS suppresses the dialog after a hard deny.
  denied,

  /// Permissions are fine but the Bluetooth radio is off. Show a
  /// prompt asking the user to enable Bluetooth.
  poweredOff,

  /// The device has no Bluetooth radio (rare; e.g. iOS simulator).
  /// Scan/connect calls will never succeed.
  unsupported,

  /// The permission state hasn't been resolved yet — typically the
  /// runtime prompt has never been shown. Calling
  /// [BluetodevController.requestPermissions] will surface the OS
  /// dialog.
  notDetermined;

  /// Maps the wire-format string emitted by the native plugins back
  /// to the enum. Unknown strings fall back to [notDetermined] so a
  /// forward-compatible plugin (e.g. one that adds new states) won't
  /// blow up an older Dart consumer.
  static BlePermissionState fromWire(String? raw) {
    switch (raw) {
      case 'granted':
        return BlePermissionState.granted;
      case 'denied':
        return BlePermissionState.denied;
      case 'poweredOff':
        return BlePermissionState.poweredOff;
      case 'unsupported':
        return BlePermissionState.unsupported;
      case 'notDetermined':
      default:
        return BlePermissionState.notDetermined;
    }
  }
}
