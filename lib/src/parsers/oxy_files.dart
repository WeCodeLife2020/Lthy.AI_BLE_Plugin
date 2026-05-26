// Oximeter recorded-file decoders for the three on-flash formats the
// Lepu/Viatom oximeter line uses:
//
//   * `oxy`     — legacy O2Ring family (O2Ring, O2M, BabyO2, SleepU,
//                 OxyLink, OxyFit, OxyRing, BBSM-S1/S2, OxyU, AI-S100,
//                 etc.). 5 bytes per second; "early" 40-byte fixed
//                 header; no trailing footer.
//   * `oxyII`   — second-gen O2-series (CMRing, OxyFit-WPS, BBSM-S3,
//                 O2Ring-RE, O2RingF, …). 3 bytes per sample; 10-byte
//                 fixed header; 48-byte fixed footer.
//   * `pf10aw1` — Wellue Checkme O2 (PF-10AW-1 / SA-10AW-PU /
//                 PF-10BWS / PF-10BW-VE). 2 bytes per sample; same
//                 10-byte header / 48-byte footer skeleton as `oxyII`.
//
// All three layouts are reverse-engineered from the bundled
// `lepu-blepro-1.2.0.aar` parsers (obfuscated `doad.dofd`,
// `doad.dofe`, `doac.n`).  Field names and behaviour mirror the SDK's
// public model classes (`com.lepu.blepro.ext.oxy.OxyFile`,
// `com.lepu.blepro.ext.oxy2.OxyFile`,
// `com.lepu.blepro.ext.pf10aw1.OxyFile`) byte-for-byte so callers can
// switch from Android-only reflection to this cross-platform parser
// without observable behaviour changes.
//
// NOTE on timestamps: the modern `oxyII` / `pf10aw1` footer stores
// `startTime` as a little-endian u32 of *device local* wall-clock
// seconds (interpreted by the firmware as if UTC).  The Android SDK
// subtracts the phone's current timezone offset to recover a real UTC
// Unix timestamp; this port does the same to keep parity, and also
// exposes the raw value as [startTimeRaw] so callers can apply a
// different timezone offset when replaying foreign files.

import 'dart:typed_data';

// ---------------------------------------------------------------------------
//  Common helpers
// ---------------------------------------------------------------------------

int _u8(List<int> b, int o) => b[o] & 0xFF;

int _u16Le(List<int> b, int o) => (b[o] & 0xFF) | ((b[o + 1] & 0xFF) << 8);

int _u32Le(List<int> b, int o) =>
    (b[o] & 0xFF) |
    ((b[o + 1] & 0xFF) << 8) |
    ((b[o + 2] & 0xFF) << 16) |
    ((b[o + 3] & 0xFF) << 24);

/// Current local timezone offset in **seconds**, matching the Java
/// `TimeZone.getDefault().getOffset(now) / 1000` value the Android SDK
/// uses to convert wall-clock seconds → Unix UTC seconds.
int _localTzOffsetSeconds() => DateTime.now().timeZoneOffset.inSeconds;

// ---------------------------------------------------------------------------
//  Legacy O2Ring family — `family: "oxy"`
// ---------------------------------------------------------------------------

/// Per-second record stored inside an [OxyFile].
///
/// Byte layout (5 bytes per record, starts at byte offset 40):
///
/// | Offset | Size | Field            |
/// | ---    | ---  | ---              |
/// | `0`    | `1`  | spo2 (u8)        |
/// | `1..3` | `2`  | pr (LE u16)      |
/// | `3`    | `1`  | vector (u8)      |
/// | `4`    | `1`  | flag byte:       |
/// |        |      |  bit 7 → warningSignSpo2     |
/// |        |      |  bit 6 → warningSignPr       |
/// |        |      |  bit 5 → warningSignVector   |
/// |        |      |  bit 4 → warningSignInvalid  |
/// |        |      |  bits 5..4 → sleepState (0..3) |
///
/// The Android SDK's port of these warning bits has a long-standing bug
/// (`(b & 0x80) == 1`, which is never true) — this Dart port surfaces
/// the **correct** bit-set interpretation as the named getters and
/// preserves the buggy values under [warningSignSpo2Sdk] etc. so
/// existing consumers that compare against the Android Java objects can
/// opt in to the bug-compatible value when needed.
class OxyEachData {
  /// SpO₂ % for this second (0..100, 0xFF when the finger is off).
  final int spo2;

  /// Pulse rate (bpm) for this second.
  final int pr;

  /// Motion vector for this second (0..255; the firmware uses this to
  /// detect movement-induced artefacts).
  final int vector;

  /// `true` when any non-zero "spo2 alarm" bit is set in the flag byte.
  /// Use this in new code — it matches the human-readable behaviour.
  final bool warningSignSpo2;

  /// `true` when the pulse-rate alarm bit is set.
  final bool warningSignPr;

  /// `true` when the motion-vector alarm bit is set.
  final bool warningSignVector;

  /// `true` when the firmware-internal "data invalid" bit is set.
  final bool warningSignInvalid;

  /// Sleep-state code (0..3) extracted from bits 5..4 of the flag byte.
  final int sleepState;

  /// Bug-compatible value returned by the Android `OxyFile.EachData.
  /// isWarningSignSpo2` getter (always `false` due to a `& 0x80 == 1`
  /// comparison in the AAR). Provided for callers that have to match
  /// the Java object byte-for-byte.
  final bool warningSignSpo2Sdk;
  final bool warningSignPrSdk;
  final bool warningSignVectorSdk;
  final bool warningSignInvalidSdk;

  const OxyEachData({
    required this.spo2,
    required this.pr,
    required this.vector,
    required this.warningSignSpo2,
    required this.warningSignPr,
    required this.warningSignVector,
    required this.warningSignInvalid,
    required this.sleepState,
    required this.warningSignSpo2Sdk,
    required this.warningSignPrSdk,
    required this.warningSignVectorSdk,
    required this.warningSignInvalidSdk,
  });

  factory OxyEachData.fromBytes(List<int> b, int off) {
    final flag = _u8(b, off + 4);
    return OxyEachData(
      spo2: _u8(b, off),
      pr: _u16Le(b, off + 1),
      vector: _u8(b, off + 3),
      warningSignSpo2: (flag & 0x80) != 0,
      warningSignPr: (flag & 0x40) != 0,
      warningSignVector: (flag & 0x20) != 0,
      warningSignInvalid: (flag & 0x10) != 0,
      sleepState: (flag & 0x30) >> 4,
      warningSignSpo2Sdk: (flag & 0x80) == 1,
      warningSignPrSdk: (flag & 0x40) == 1,
      warningSignVectorSdk: (flag & 0x20) == 1,
      warningSignInvalidSdk: (flag & 0x10) == 1,
    );
  }

  @override
  String toString() =>
      'OxyEachData(spo2=$spo2 pr=$pr vec=$vector sleep=$sleepState)';
}

/// Decoded legacy O2Ring-family recording (`family == "oxy"`).
///
/// Byte layout (offsets in bytes, all multi-byte ints are LE):
///
/// | Offset      | Size  | Field                     |
/// | ---         | ---   | ---                       |
/// | `0`         | `1`   | fileVersion               |
/// | `1`         | `1`   | operationMode             |
/// | `2..4`      | `2`   | year                      |
/// | `4`         | `1`   | month                     |
/// | `5`         | `1`   | day                       |
/// | `6`         | `1`   | hour                      |
/// | `7`         | `1`   | minute                    |
/// | `8`         | `1`   | second                    |
/// | `9..13`     | `4`   | size (= offset where pointBytes end) |
/// | `13..15`    | `2`   | recordingTime (seconds)   |
/// | `15..17`    | `2`   | asleepTime                |
/// | `17`        | `1`   | avgSpo2                   |
/// | `18`        | `1`   | minSpo2                   |
/// | `19`        | `1`   | dropsTimes3Percent        |
/// | `20`        | `1`   | dropsTimes4Percent        |
/// | `21`        | `1`   | asleepTimePercent         |
/// | `22..24`    | `2`   | durationTime90Percent     |
/// | `24`        | `1`   | dropsTimes90Percent       |
/// | `25`        | `1`   | o2Score                   |
/// | `26..30`    | `4`   | stepCounter               |
/// | `30..40`    | `10`  | reserved / firmware-private |
/// | `40..size`  | `*`   | pointBytes — 5 bytes per second, decoded into [data] |
class OxyFile {
  /// File-format version (byte[0]).
  final int fileVersion;

  /// `operationMode` byte (0 = continuous, 1 = spot-check, … per firmware).
  final int operationMode;

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;

  /// UTC Unix timestamp (seconds) of the recording's start, derived from
  /// [year]/[month]/[day]/[hour]/[minute]/[second] **assuming those
  /// fields represent local wall-clock**.  Matches the Android SDK's
  /// `DateUtil.getSecondTimestamp(...)` call.
  final int startTime;

  /// Byte offset where the per-second pointBytes end (= length of
  /// `header + pointBytes`).  The SDK exposes this as `size`.
  final int size;

  /// Number of recorded seconds.  Equivalent to `data.length`.
  final int recordingTime;

  /// Total seconds the wearer was scored as "asleep" (firmware heuristic).
  final int asleepTime;

  /// Average SpO₂ across the whole recording (%).
  final int avgSpo2;

  /// Minimum SpO₂ in the recording (%).
  final int minSpo2;

  /// Number of ≥3 % SpO₂ desaturations.
  final int dropsTimes3Percent;

  /// Number of ≥4 % SpO₂ desaturations.
  final int dropsTimes4Percent;

  /// Percentage (0..100) of [recordingTime] scored as asleep.
  final int asleepTimePercent;

  /// Total seconds SpO₂ was < 90 %.
  final int durationTime90Percent;

  /// Number of times SpO₂ dipped below 90 %.
  final int dropsTimes90Percent;

  /// Firmware-computed "O₂ score" (0..100; higher is better).
  final int o2Score;

  /// Cumulative step counter for the recording.
  final int stepCounter;

  /// Raw pointBytes (bytes 40..size).  Each 5-byte chunk is parsed into
  /// [data]; the raw slice is preserved so callers can re-parse with a
  /// different schema (e.g. firmware-specific tweaks).
  final Uint8List pointBytes;

  /// Per-second decoded samples (5 bytes each — see [OxyEachData]).
  final List<OxyEachData> data;

  /// Original file payload.
  final Uint8List bytes;

  OxyFile._({
    required this.fileVersion,
    required this.operationMode,
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    required this.startTime,
    required this.size,
    required this.recordingTime,
    required this.asleepTime,
    required this.avgSpo2,
    required this.minSpo2,
    required this.dropsTimes3Percent,
    required this.dropsTimes4Percent,
    required this.asleepTimePercent,
    required this.durationTime90Percent,
    required this.dropsTimes90Percent,
    required this.o2Score,
    required this.stepCounter,
    required this.pointBytes,
    required this.data,
    required this.bytes,
  });

  /// Decode a legacy O2Ring-family file.
  ///
  /// Throws [ArgumentError] when [raw] is shorter than the fixed 40-byte
  /// header.
  static OxyFile parse(List<int> raw) {
    if (raw.length < 40) {
      throw ArgumentError(
        'Oxy file too short: ${raw.length} bytes (need ≥40)',
      );
    }

    final size = _u32Le(raw, 9);
    final pointEnd = size < raw.length ? size : raw.length;
    final pointBytes = Uint8List.fromList(
      raw.sublist(40, pointEnd < 40 ? 40 : pointEnd),
    );

    final sampleCount = pointBytes.length ~/ 5;
    final data = <OxyEachData>[];
    for (var i = 0; i < sampleCount; i++) {
      data.add(OxyEachData.fromBytes(raw, 40 + i * 5));
    }

    final year = _u16Le(raw, 2);
    final month = _u8(raw, 4);
    final day = _u8(raw, 5);
    final hour = _u8(raw, 6);
    final minute = _u8(raw, 7);
    final second = _u8(raw, 8);
    // Match `DateUtil.getSecondTimestamp(getTimeString(y, M, d, H, m, s))`
    // — i.e. interpret the wall-clock fields as **local** time and
    // produce a UTC Unix timestamp in seconds.
    final dt = DateTime(year, month, day, hour, minute, second);
    final startTime = dt.millisecondsSinceEpoch ~/ 1000;

    return OxyFile._(
      fileVersion: _u8(raw, 0),
      operationMode: _u8(raw, 1),
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      startTime: startTime,
      size: size,
      recordingTime: _u16Le(raw, 13),
      asleepTime: _u16Le(raw, 15),
      avgSpo2: _u8(raw, 17),
      minSpo2: _u8(raw, 18),
      dropsTimes3Percent: _u8(raw, 19),
      dropsTimes4Percent: _u8(raw, 20),
      asleepTimePercent: _u8(raw, 21),
      durationTime90Percent: _u16Le(raw, 22),
      dropsTimes90Percent: _u8(raw, 24),
      o2Score: _u8(raw, 25),
      stepCounter: _u32Le(raw, 26),
      pointBytes: pointBytes,
      data: List.unmodifiable(data),
      bytes: Uint8List.fromList(raw),
    );
  }

  /// Recording duration as a [Duration].
  Duration get duration => Duration(seconds: recordingTime);

  /// SpO₂ samples convenience — equivalent to `data.map((e) => e.spo2)`.
  List<int> get spo2List => List.unmodifiable(data.map((e) => e.spo2));

  /// PR samples convenience — equivalent to `data.map((e) => e.pr)`.
  List<int> get prList => List.unmodifiable(data.map((e) => e.pr));

  /// Motion-vector samples convenience.
  List<int> get motionList => List.unmodifiable(data.map((e) => e.vector));

  @override
  String toString() =>
      'OxyFile(v$fileVersion $recordingTime s avgSpo2=$avgSpo2 '
      'minSpo2=$minSpo2 o2Score=$o2Score steps=$stepCounter '
      'data=${data.length})';
}

// ---------------------------------------------------------------------------
//  Modern OxyII family — `family: "oxyII"`
// ---------------------------------------------------------------------------

/// Decoded second-gen O2-series recording (`family == "oxyII"`).
///
/// Byte layout (header 10 + N×3 pointBytes + 48-byte footer):
///
/// | Section | Offset           | Size  | Field |
/// | ---     | ---              | ---   | ---   |
/// | header  | `0`              | `1`   | fileVersion |
/// |         | `1`              | `1`   | fileType |
/// |         | `8..10`          | `2`   | deviceModel |
/// | per-sample (at `10 + 3i`):  | | |
/// |         | `+0`             | `1`   | spo2 |
/// |         | `+1`             | `1`   | pr   |
/// |         | `+2` lo 6 bits×2 |       | motion (= `(b & 0x3F) * 2`) |
/// |         | `+2` bit 6       |       | remindHr |
/// |         | `+2` bit 7       |       | remindSpo2 |
/// | footer (relative to `f = 10 + 3N`): | | |
/// |         | `f+0`            | `4`   | checkSum (u32 LE) |
/// |         | `f+4`            | `4`   | magic (u32 LE) |
/// |         | `f+8`            | `4`   | startTime (u32 LE — local wall-clock seconds; tz-adjusted to UTC) |
/// |         | `f+12`           | `4`   | size (u32 LE — number of samples per scoring block) |
/// |         | `f+16`           | `1`   | interval (seconds per sample) |
/// |         | `f+17`           | `1`   | channelType |
/// |         | `f+18`           | `1`   | channelBytes |
/// |         | `f+32..f+34`     | `2`   | percentLessThan90 |
/// |         | `f+34`           | `1`   | asleepTime |
/// |         | `f+35`           | `1`   | avgSpo2 |
/// |         | `f+36`           | `1`   | minSpo2 |
/// |         | `f+37`           | `1`   | dropsTimes3Percent |
/// |         | `f+38`           | `1`   | dropsTimes4Percent |
/// |         | `f+39..f+41`     | `2`   | durationTime90Percent |
/// |         | `f+41`           | `1`   | dropsTimes90Percent |
/// |         | `f+42`           | `1`   | o2Score |
/// |         | `f+43..f+47`     | `4`   | stepCounter (u32 LE) |
/// |         | `f+47`           | `1`   | avgHr |
class OxyIIFile {
  final int fileVersion;
  final int fileType;
  final int deviceModel;

  /// Raw pointBytes (the slice between header and footer).  Use
  /// [spo2List]/[prList]/[motionList] for decoded views; this is exposed
  /// for callers that need byte-for-byte access.
  final Uint8List pointBytes;

  /// Per-second SpO₂ samples.
  final List<int> spo2List;

  /// Per-second pulse-rate samples (bpm).
  final List<int> prList;

  /// Per-second motion magnitude (`(flag & 0x3F) * 2`).
  final List<int> motionList;

  /// Per-second "HR alarm" flag (bit 6 of the third byte).
  final List<bool> remindHrs;

  /// Per-second "SpO₂ alarm" flag (bit 7 of the third byte).
  final List<bool> remindsSpo2;

  /// 32-bit vendor checksum from the footer.
  final int checkSum;

  /// Magic sentinel from the footer (typical value `0x564f5331` etc.).
  final int magic;

  /// UTC Unix timestamp (seconds), adjusted for the phone's current
  /// timezone — matches the Android SDK behaviour.
  final int startTime;

  /// Raw little-endian u32 as stored in the file, **before**
  /// tz-adjustment.  Use this when replaying foreign files.
  final int startTimeRaw;

  /// Number of samples per scoring block (used to compute
  /// [recordingTime] = `size * interval`).
  final int size;

  /// Seconds between samples (typically 1 or 4).
  final int interval;

  /// Recording duration in seconds (= [size] × [interval]).
  final int recordingTime;

  final int channelType;
  final int channelBytes;
  final int asleepTime;
  final int avgSpo2;
  final int minSpo2;
  final int dropsTimes3Percent;
  final int dropsTimes4Percent;

  /// `(percent × 100)` of recording spent below 90 % SpO₂.
  final int percentLessThan90;

  final int durationTime90Percent;
  final int dropsTimes90Percent;
  final int o2Score;
  final int stepCounter;
  final int avgHr;

  /// Original file payload.
  final Uint8List bytes;

  OxyIIFile._({
    required this.fileVersion,
    required this.fileType,
    required this.deviceModel,
    required this.pointBytes,
    required this.spo2List,
    required this.prList,
    required this.motionList,
    required this.remindHrs,
    required this.remindsSpo2,
    required this.checkSum,
    required this.magic,
    required this.startTime,
    required this.startTimeRaw,
    required this.size,
    required this.interval,
    required this.recordingTime,
    required this.channelType,
    required this.channelBytes,
    required this.asleepTime,
    required this.avgSpo2,
    required this.minSpo2,
    required this.dropsTimes3Percent,
    required this.dropsTimes4Percent,
    required this.percentLessThan90,
    required this.durationTime90Percent,
    required this.dropsTimes90Percent,
    required this.o2Score,
    required this.stepCounter,
    required this.avgHr,
    required this.bytes,
  });

  /// Decode an OxyII file.
  ///
  /// Throws [ArgumentError] when [raw] is shorter than the fixed
  /// 10-byte header + 48-byte footer (58 bytes) or the body length
  /// isn't a multiple of the 3-byte sample stride.
  static OxyIIFile parse(List<int> raw, {Duration? timezoneOffset}) {
    if (raw.length < 58) {
      throw ArgumentError(
        'OxyII file too short: ${raw.length} bytes (need ≥58)',
      );
    }
    final n = raw.length;
    if ((n - 58) % 3 != 0) {
      throw ArgumentError(
        'OxyII body length not aligned to 3-byte sample stride: '
        '${n - 58} mod 3 = ${(n - 58) % 3}',
      );
    }
    final numPoints = (n - 58) ~/ 3;
    const headerSize = 10;
    final footerOff = headerSize + numPoints * 3;

    final pointBytes = Uint8List.fromList(raw.sublist(headerSize, footerOff));
    final spo2 = List<int>.filled(numPoints, 0);
    final pr = List<int>.filled(numPoints, 0);
    final motion = List<int>.filled(numPoints, 0);
    final remindHr = List<bool>.filled(numPoints, false);
    final remindSpo2 = List<bool>.filled(numPoints, false);
    for (var i = 0; i < numPoints; i++) {
      final base = headerSize + i * 3;
      spo2[i] = _u8(raw, base);
      pr[i] = _u8(raw, base + 1);
      final flag = _u8(raw, base + 2);
      motion[i] = (flag & 0x3F) * 2;
      remindHr[i] = (flag & 0x40) >> 6 == 1;
      remindSpo2[i] = (flag & 0x80) >> 7 == 1;
    }

    final tzSeconds = (timezoneOffset ?? Duration(seconds: _localTzOffsetSeconds()))
        .inSeconds;
    final startTimeRaw = _u32Le(raw, footerOff + 8);
    final startTime = startTimeRaw - tzSeconds;
    final size = _u32Le(raw, footerOff + 12);
    final interval = _u8(raw, footerOff + 16);
    final recordingTime = size * interval;

    return OxyIIFile._(
      fileVersion: _u8(raw, 0),
      fileType: _u8(raw, 1),
      deviceModel: _u16Le(raw, 8),
      pointBytes: pointBytes,
      spo2List: List.unmodifiable(spo2),
      prList: List.unmodifiable(pr),
      motionList: List.unmodifiable(motion),
      remindHrs: List.unmodifiable(remindHr),
      remindsSpo2: List.unmodifiable(remindSpo2),
      checkSum: _u32Le(raw, footerOff + 0),
      magic: _u32Le(raw, footerOff + 4),
      startTime: startTime,
      startTimeRaw: startTimeRaw,
      size: size,
      interval: interval,
      recordingTime: recordingTime,
      channelType: _u8(raw, footerOff + 17),
      channelBytes: _u8(raw, footerOff + 18),
      percentLessThan90: _u16Le(raw, footerOff + 32),
      asleepTime: _u8(raw, footerOff + 34),
      avgSpo2: _u8(raw, footerOff + 35),
      minSpo2: _u8(raw, footerOff + 36),
      dropsTimes3Percent: _u8(raw, footerOff + 37),
      dropsTimes4Percent: _u8(raw, footerOff + 38),
      durationTime90Percent: _u16Le(raw, footerOff + 39),
      dropsTimes90Percent: _u8(raw, footerOff + 41),
      o2Score: _u8(raw, footerOff + 42),
      stepCounter: _u32Le(raw, footerOff + 43),
      avgHr: _u8(raw, footerOff + 47),
      bytes: Uint8List.fromList(raw),
    );
  }

  Duration get duration => Duration(seconds: recordingTime);

  /// Number of decoded samples.
  int get sampleCount => spo2List.length;

  @override
  String toString() =>
      'OxyIIFile(v$fileVersion type=$fileType model=$deviceModel '
      '$sampleCount samples interval=${interval}s avgSpo2=$avgSpo2 '
      'minSpo2=$minSpo2 avgHr=$avgHr o2Score=$o2Score steps=$stepCounter)';
}

// ---------------------------------------------------------------------------
//  Wellue Checkme O2 family — `family: "pf10aw1"`
// ---------------------------------------------------------------------------

/// Decoded Wellue Checkme O2-family recording
/// (`family == "pf10aw1"`).
///
/// Same 10-byte header / 48-byte footer skeleton as [OxyIIFile], but
/// each per-second sample is only 2 bytes (spo2 + pr) and the footer
/// only carries the basic block-shape fields — no average/score/desat
/// stats (the device computes those on-host).
class Pf10aw1File {
  final int fileVersion;
  final int fileType;
  final int deviceModel;
  final Uint8List pointBytes;
  final List<int> spo2List;
  final List<int> prList;
  final int checkSum;
  final int magic;

  /// UTC Unix timestamp (seconds), adjusted for the phone's current
  /// timezone — matches the Android SDK behaviour.
  final int startTime;

  /// Raw little-endian u32 as stored in the file, **before**
  /// tz-adjustment.
  final int startTimeRaw;

  final int size;
  final int interval;

  /// UTC Unix timestamp (seconds) of the end of the recording, derived
  /// from `startTime + size * interval` — matches the SDK's
  /// `OxyFile.setEndTime(...)` call.
  final int endTime;

  final int channelType;
  final int channelBytes;
  final Uint8List bytes;

  Pf10aw1File._({
    required this.fileVersion,
    required this.fileType,
    required this.deviceModel,
    required this.pointBytes,
    required this.spo2List,
    required this.prList,
    required this.checkSum,
    required this.magic,
    required this.startTime,
    required this.startTimeRaw,
    required this.size,
    required this.interval,
    required this.endTime,
    required this.channelType,
    required this.channelBytes,
    required this.bytes,
  });

  /// Decode a Pf10aw1 file.
  ///
  /// Throws [ArgumentError] when [raw] is shorter than the 58-byte
  /// minimum or its body length isn't a multiple of the 2-byte sample
  /// stride.
  static Pf10aw1File parse(List<int> raw, {Duration? timezoneOffset}) {
    if (raw.length < 58) {
      throw ArgumentError(
        'Pf10aw1 file too short: ${raw.length} bytes (need ≥58)',
      );
    }
    final n = raw.length;
    if ((n - 58) % 2 != 0) {
      throw ArgumentError(
        'Pf10aw1 body length not aligned to 2-byte sample stride: '
        '${n - 58} mod 2 = ${(n - 58) % 2}',
      );
    }
    final numPoints = (n - 58) ~/ 2;
    const headerSize = 10;
    final footerOff = headerSize + numPoints * 2;

    final pointBytes = Uint8List.fromList(raw.sublist(headerSize, footerOff));
    final spo2 = List<int>.filled(numPoints, 0);
    final pr = List<int>.filled(numPoints, 0);
    for (var i = 0; i < numPoints; i++) {
      spo2[i] = _u8(raw, headerSize + i * 2);
      pr[i] = _u8(raw, headerSize + i * 2 + 1);
    }

    final tzSeconds = (timezoneOffset ?? Duration(seconds: _localTzOffsetSeconds()))
        .inSeconds;
    final startTimeRaw = _u32Le(raw, footerOff + 8);
    final startTime = startTimeRaw - tzSeconds;
    final size = _u32Le(raw, footerOff + 12);
    final interval = _u8(raw, footerOff + 16);
    final endTime = startTime + size * interval;

    return Pf10aw1File._(
      fileVersion: _u8(raw, 0),
      fileType: _u8(raw, 1),
      deviceModel: _u16Le(raw, 8),
      pointBytes: pointBytes,
      spo2List: List.unmodifiable(spo2),
      prList: List.unmodifiable(pr),
      checkSum: _u32Le(raw, footerOff + 0),
      magic: _u32Le(raw, footerOff + 4),
      startTime: startTime,
      startTimeRaw: startTimeRaw,
      size: size,
      interval: interval,
      endTime: endTime,
      channelType: _u8(raw, footerOff + 17),
      channelBytes: _u8(raw, footerOff + 18),
      bytes: Uint8List.fromList(raw),
    );
  }

  Duration get duration => Duration(seconds: size * interval);

  /// Number of decoded samples.
  int get sampleCount => spo2List.length;

  @override
  String toString() =>
      'Pf10aw1File(v$fileVersion type=$fileType model=$deviceModel '
      '$sampleCount samples interval=${interval}s '
      'start=$startTime end=$endTime)';
}
