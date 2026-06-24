// Typed event models for the on-device file-transfer pipeline.
//
// Wire format (emitted by both the Android Kotlin plugin and the iOS
// Obj-C plugin — `LthyBlePlugin.kt`/`.m`):
//
//   { event: 'fileList',         model, deviceFamily?, files: [String] }
//   { event: 'fileReadProgress', model, deviceFamily,  fileName?, progress: 0..1 }
//   { event: 'fileReadComplete', model, deviceFamily,  fileName,
//                                size,  content: <base64>?, parsed?: { ... } }
//   { event: 'fileReadError',    model, deviceFamily,  fileName?, error }
//
// `content` is base64-encoded raw file bytes when the SDK exposes them;
// `parsed` is a best-effort family-specific map of typed fields the SDK
// has already parsed for us (e.g. SpO2 lists for oximeters).

import 'dart:convert';
import 'dart:typed_data';

import '../parsers/bp2_file.dart';
import '../parsers/er1_er2_file.dart';
import '../parsers/oxy_files.dart';

/// Response to [BluetodevController.getFileList].
class FileListEvent {
  /// Lepu/iComon model id for which this list applies.
  final int model;

  /// Family token: `"er1"`, `"er2"`, `"bp2"`, `"oxy"`, `"oxyII"`,
  /// `"pf10aw1"`, etc.  Always present on Android, present on iOS for
  /// every family that supports listing.
  final String? deviceFamily;

  /// Filenames stored on the device's flash, oldest-first.  Pass each
  /// entry to [BluetodevController.readFile] to download the file.
  final List<String> files;

  const FileListEvent({
    required this.model,
    required this.files,
    this.deviceFamily,
  });

  factory FileListEvent.fromMap(Map<String, dynamic> m) => FileListEvent(
    model: (m['model'] as num?)?.toInt() ?? -1,
    deviceFamily: m['deviceFamily'] as String?,
    files: ((m['files'] as List?) ?? const []).whereType<String>().toList(
      growable: false,
    ),
  );

  @override
  String toString() =>
      'FileListEvent(model=$model, family=$deviceFamily, files=${files.length})';
}

/// Per-chunk progress update during a file download.
class FileReadProgressEvent {
  final int model;
  final String deviceFamily;
  final String? fileName;

  /// Fraction in `0.0 ... 1.0`.  Plugins normalise the SDK's native
  /// progress (which may arrive as `0..100` integers) to this range.
  final double progress;

  const FileReadProgressEvent({
    required this.model,
    required this.deviceFamily,
    required this.progress,
    this.fileName,
  });

  factory FileReadProgressEvent.fromMap(Map<String, dynamic> m) =>
      FileReadProgressEvent(
        model: (m['model'] as num?)?.toInt() ?? -1,
        deviceFamily: (m['deviceFamily'] as String?) ?? 'unknown',
        fileName: m['fileName'] as String?,
        progress: (m['progress'] as num?)?.toDouble() ?? 0.0,
      );

  @override
  String toString() =>
      'FileReadProgress($deviceFamily $fileName '
      '${(progress * 100).toStringAsFixed(1)}%)';
}

/// Final event of a successful file download.
class FileReadCompleteEvent {
  final int model;
  final String deviceFamily;
  final String fileName;

  /// Decoded file bytes (may be empty if the SDK only exposes parsed
  /// fields and not the raw payload).
  final Uint8List content;

  /// Family-specific best-effort parsed fields, exactly as the vendor
  /// SDK already decoded them.  Keys depend on `deviceFamily`:
  ///
  ///  * `bp2`        — `fileName`, `type`, `content`
  ///  * `er1` / `er2` — `fileName`, `content`
  ///  * `oxy`        — `fileType`, `fileVersion`, `recordingTime`,
  ///                  `spo2List`, `prList`, `motionList`, `avgSpo2`,
  ///                  `asleepTime`, `asleepTimePercent`
  ///  * `oxyII`      — `fileType`, `startTime`, `interval`,
  ///                  `spo2List`, `prList`, `motionList`, `avgSpo2`,
  ///                  `minSpo2`, `avgHr`, `stepCounter`, `o2Score`, ...
  ///  * `pf10aw1`    — `fileType`, `startTime`, `endTime`, `interval`,
  ///                  `spo2List`, `prList`, ...
  ///
  /// On iOS the plugin only fills `parsed` for the legacy O2 path; for
  /// URAT-protocol families the raw [content] is delivered and Dart-side
  /// parsing is the consumer's responsibility.
  final Map<String, dynamic>? parsed;

  const FileReadCompleteEvent({
    required this.model,
    required this.deviceFamily,
    required this.fileName,
    required this.content,
    this.parsed,
  });

  factory FileReadCompleteEvent.fromMap(Map<String, dynamic> m) {
    final raw = m['content'];
    Uint8List bytes;
    if (raw is String) {
      try {
        bytes = base64Decode(raw);
      } catch (_) {
        bytes = Uint8List(0);
      }
    } else if (raw is List) {
      bytes = Uint8List.fromList(raw.cast<int>());
    } else {
      bytes = Uint8List(0);
    }
    final parsed = m['parsed'];
    return FileReadCompleteEvent(
      model: (m['model'] as num?)?.toInt() ?? -1,
      deviceFamily: (m['deviceFamily'] as String?) ?? 'unknown',
      fileName: (m['fileName'] as String?) ?? '',
      content: bytes,
      parsed: parsed is Map ? Map<String, dynamic>.from(parsed) : null,
    );
  }

  /// File size in bytes (equivalent to `content.length`).
  int get size => content.length;

  /// Decode [content] into a typed object using the bundled Dart-side
  /// parsers.  Currently supports:
  ///
  ///  * `bp2`     → [Bp2File] (subtype [Bp2BpFile] or [Bp2EcgFile])
  ///  * `er1`     → [Er1EcgFile]
  ///  * `er2`     → [Er1EcgFile] (same on-flash format as ER1)
  ///  * `oxy`     → [OxyFile]      (legacy O2Ring family)
  ///  * `oxyII`   → [OxyIIFile]    (second-gen O2 series)
  ///  * `pf10aw1` → [Pf10aw1File]  (Wellue Checkme O2)
  ///
  /// Returns `null` for any other family or when [content] is empty
  /// (i.e. the SDK only exposed pre-parsed fields via [parsed]).
  /// Re-throws [ArgumentError] when the bytes are obviously malformed
  /// — typically too short for the family's documented header.
  ///
  /// The decoder is *cross-platform*: the same Dart code runs on
  /// Android (where the Lepu AAR also exposes equivalent Java
  /// objects) and iOS (where it's the only available decoder).
  Object? get decoded {
    if (content.isEmpty) return null;
    switch (deviceFamily) {
      case 'bp2':
        return Bp2File.parse(content);
      case 'er1':
        return Er1EcgFile.parseEr1(content);
      case 'er2':
        return Er1EcgFile.parseEr2(content);
      case 'oxy':
        return OxyFile.parse(content);
      case 'oxyII':
        return OxyIIFile.parse(content);
      case 'pf10aw1':
        return Pf10aw1File.parse(content);
      default:
        return null;
    }
  }

  @override
  String toString() => 'FileReadComplete($deviceFamily $fileName $size bytes)';
}

/// Emitted on a download failure or cancellation.
class FileReadErrorEvent {
  final int model;
  final String deviceFamily;
  final String? fileName;
  final String error;

  const FileReadErrorEvent({
    required this.model,
    required this.deviceFamily,
    required this.error,
    this.fileName,
  });

  factory FileReadErrorEvent.fromMap(Map<String, dynamic> m) =>
      FileReadErrorEvent(
        model: (m['model'] as num?)?.toInt() ?? -1,
        deviceFamily: (m['deviceFamily'] as String?) ?? 'unknown',
        fileName: m['fileName'] as String?,
        error: (m['error'] as String?) ?? 'unknown',
      );

  @override
  String toString() => 'FileReadError($deviceFamily $fileName: $error)';
}

/// Informational event emitted the moment a Lepu device reports a
/// recording has just been saved to flash (ER1/ER2 `curStatus → 4`,
/// BP2 `paramDataType → *_result`). Consumers who turn
/// `autoFetchOnFinish` off in [BluetodevController.connect] use this to
/// drive their own fetch cycle; with `autoFetchOnFinish` on the plugin
/// pulls the resulting file automatically and the client only needs
/// [BluetodevController.fileReadCompleteStream].
class RecordingFinishedEvent {
  final int model;
  final String deviceFamily;

  const RecordingFinishedEvent({
    required this.model,
    required this.deviceFamily,
  });

  factory RecordingFinishedEvent.fromMap(Map<String, dynamic> m) =>
      RecordingFinishedEvent(
        model: (m['model'] as num?)?.toInt() ?? -1,
        deviceFamily: (m['deviceFamily'] as String?) ?? 'unknown',
      );

  @override
  String toString() => 'RecordingFinished($deviceFamily model=$model)';
}

/// A single historical record fetched from an iComon device.  Offline
/// measurements (taken while the phone was disconnected) are replayed
/// as these events either automatically on reconnect, or on demand via
/// [BluetodevController.readHistoryData].
///
/// The concrete shape depends on [kind]:
///
/// * `weight`       — `weight_kg`, `weight_g`, `weight_lb`, `weight_st`,
///                    `weight_st_lb`, `precision_kg`, `precision_lb`,
///                    `impedance`, `userId`, `time` (Unix seconds)
/// * `kitchenScale` — `weight_g`, `isStabilized`, `time`
/// * `ruler`        — `distance_cm`, `distance_in`, `distance_ft`,
///                    `isStabilized`, `time`
/// * `skip`         — `skipCount`, `elapsedTime`, `actualTime`,
///                    `avgFreq`, `calories`, `battery`, `time`
///                    (plus `fastestFreq`, `interrupts`, `mostJump` on
///                    Android)
class HistoryDataEvent {
  /// One of `weight`, `kitchenScale`, `ruler`, `skip`.
  final String kind;

  /// Always `"icomon"` for now — the only platform with offline-history
  /// support in this plugin.  Future BP2 / oximeter add-ons could extend
  /// this with more values.
  final String deviceFamily;

  /// MAC address of the source device.
  final String mac;

  /// Unix timestamp (seconds), or `null` if the device didn't attach a
  /// timestamp to this record.
  final int? time;

  /// Full raw payload (every field the native side emitted, minus the
  /// event/kind/deviceFamily/mac/time keys extracted above).  Consumers
  /// that need the typed fields should read them directly from here —
  /// the keys are documented above per-kind.
  final Map<String, dynamic> fields;

  const HistoryDataEvent({
    required this.kind,
    required this.deviceFamily,
    required this.mac,
    required this.fields,
    this.time,
  });

  factory HistoryDataEvent.fromMap(Map<String, dynamic> m) {
    final time = (m['time'] as num?)?.toInt();
    return HistoryDataEvent(
      kind: (m['kind'] as String?) ?? 'unknown',
      deviceFamily: (m['deviceFamily'] as String?) ?? 'icomon',
      mac: (m['mac'] as String?) ?? '',
      time: (time == null || time == 0) ? null : time,
      fields: Map<String, dynamic>.from(m),
    );
  }

  /// Convenience — returns [time] as a `DateTime` in local time, or
  /// `null` if the record was missing a timestamp.
  DateTime? get timestamp =>
      time == null ? null : DateTime.fromMillisecondsSinceEpoch(time! * 1000);

  /// Shorthand for weight records.
  double? get weightKg => (fields['weight_kg'] as num?)?.toDouble();

  @override
  String toString() =>
      'HistoryDataEvent($kind $deviceFamily mac=$mac time=$time)';
}
