// Round-trip tests for the Dart-side file decoders.  Each test
// constructs a minimal byte buffer that matches what the device
// firmware writes to flash, runs the parser, and asserts every
// field is recovered exactly.  The fixtures double as living
// documentation of the on-flash format.

import 'dart:typed_data';

import 'package:flutter_ble_devices/flutter_ble_devices.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a buffer of [length] zeros, then write each `(offset, byte)`
/// in [bytes] over it.  Multi-byte fields are pre-split into their
/// little-endian bytes by the test helpers below.
Uint8List _buf(int length, Map<int, int> bytes) {
  final out = Uint8List(length);
  bytes.forEach((offset, value) {
    out[offset] = value & 0xFF;
  });
  return out;
}

void _writeU16Le(Uint8List buf, int offset, int value) {
  buf[offset] = value & 0xFF;
  buf[offset + 1] = (value >> 8) & 0xFF;
}

void _writeU32Le(Uint8List buf, int offset, int value) {
  buf[offset] = value & 0xFF;
  buf[offset + 1] = (value >> 8) & 0xFF;
  buf[offset + 2] = (value >> 16) & 0xFF;
  buf[offset + 3] = (value >> 24) & 0xFF;
}

void _writeI16Le(Uint8List buf, int offset, int value) {
  // Two's-complement 16-bit encoding.
  final u = value & 0xFFFF;
  buf[offset] = u & 0xFF;
  buf[offset + 1] = (u >> 8) & 0xFF;
}

void main() {
  group('EcgDiagnosis', () {
    test('result == 0 → regular sinus rhythm', () {
      final d = EcgDiagnosis.fromInt(0);
      expect(d.isRegular, isTrue);
      expect(d.isPoorSignal, isFalse);
      expect(d.findings, ['Normal sinus rhythm']);
    });

    test('result == -1 → poor signal sentinel', () {
      final d = EcgDiagnosis.fromInt(-1);
      expect(d.isPoorSignal, isTrue);
      expect(d.isRegular, isFalse);
      expect(d.findings, ['Poor signal']);
    });

    test('result == -2 → lead-off sentinel', () {
      final d = EcgDiagnosis.fromInt(-2);
      expect(d.isLeadOff, isTrue);
      expect(d.findings, ['Lead off']);
    });

    test('bit-mask: fast HR + irregular + AFib', () {
      // Bit 0 (fastHr) | Bit 2 (irregular) | Bit 5 (AFib)
      final v = 0x01 | 0x04 | 0x20;
      final d = EcgDiagnosis.fromInt(v);
      expect(d.isFastHr, isTrue);
      expect(d.isIrregular, isTrue);
      expect(d.isFibrillation, isTrue);
      expect(d.isSlowHr, isFalse);
      expect(d.isPvcs, isFalse);
      expect(d.findings, [
        'Fast heart rate',
        'Irregular rhythm',
        'Atrial fibrillation',
      ]);
    });

    test('all twelve bits decode independently', () {
      const masks = <int, String>{
        0x001: 'Fast heart rate',
        0x002: 'Slow heart rate',
        0x004: 'Irregular rhythm',
        0x008: 'PVCs',
        0x010: 'Heart pause',
        0x020: 'Atrial fibrillation',
        0x040: 'Wide QRS (>120 ms)',
        0x080: 'Prolonged QTc (>450 ms)',
        0x100: 'Short QTc (<300 ms)',
      };
      masks.forEach((bit, label) {
        final d = EcgDiagnosis.fromInt(bit);
        expect(d.findings, [label], reason: 'bit 0x${bit.toRadixString(16)}');
      });
    });

    test('fromLeBytes decodes the same way as fromInt', () {
      // 0x00000005 little-endian = fastHr + irregular
      final d = EcgDiagnosis.fromLeBytes([0x05, 0x00, 0x00, 0x00]);
      expect(d.isFastHr, isTrue);
      expect(d.isIrregular, isTrue);
    });
  });

  group('Bp2BpFile (fileType=1)', () {
    test('parses every documented field', () {
      // 19-byte BP record. Build it field-by-field.
      final raw = _buf(19, {
        0: 0x05, // fileVersion
        1: 0x01, // fileType (BP)
        17: 72, // pr
        18: 0x01, // result → arrhythmia true
      });
      // measureTime: 2024-05-01 09:30:15 UTC = 1714555815
      // (file stores localTime = UTC + tz offset, so to get UTC=raw - tz)
      // Use a fixed tzOffset for deterministic asserts.
      const tzOffset = Duration(hours: 0);
      const measureTimeRaw = 1714555815;
      _writeU32Le(raw, 2, measureTimeRaw);
      _writeU16Le(raw, 11, 128); // sys
      _writeU16Le(raw, 13, 82); // dia
      _writeU16Le(raw, 15, 98); // mean

      final f = Bp2File.parse(raw, timezoneOffset: tzOffset) as Bp2BpFile;
      expect(f.fileVersion, 5);
      expect(f.fileType, 1);
      expect(f.measureTimeRaw, measureTimeRaw);
      expect(f.measureTime, measureTimeRaw); // tz=0 ⇒ same value
      expect(f.sys, 128);
      expect(f.dia, 82);
      expect(f.mean, 98);
      expect(f.pr, 72);
      expect(f.result, 1);
      expect(f.arrhythmia, isTrue);
    });

    test('arrhythmia false when result byte is 0', () {
      final raw = _buf(19, {0: 1, 1: 1, 17: 70});
      _writeU32Le(raw, 2, 1714555815);
      _writeU16Le(raw, 11, 120);
      _writeU16Le(raw, 13, 80);
      _writeU16Le(raw, 15, 95);

      final f = Bp2File.parse(raw, timezoneOffset: Duration.zero) as Bp2BpFile;
      expect(f.arrhythmia, isFalse);
      expect(f.result, 0);
    });

    test('throws on truncated buffer', () {
      expect(() => Bp2File.parse([0x01, 0x01]), throwsArgumentError);
    });

    test('measureTime subtracts tz offset', () {
      final raw = _buf(19, {0: 1, 1: 1});
      _writeU32Le(raw, 2, 10_000);
      _writeU16Le(raw, 11, 100);
      _writeU16Le(raw, 13, 60);
      _writeU16Le(raw, 15, 73);
      // tzOffset = +5:30 → expect measureTime = 10000 - 19800 = -9800
      final f =
          Bp2File.parse(
                raw,
                timezoneOffset: const Duration(hours: 5, minutes: 30),
              )
              as Bp2BpFile;
      expect(f.measureTimeRaw, 10_000);
      expect(f.measureTime, 10_000 - 19_800);
    });
  });

  group('Bp2EcgFile (fileType=2)', () {
    test('parses header + waveform', () {
      // Header (48 bytes) + 4 fake samples (8 bytes wave).
      final raw = _buf(48 + 8, {
        0: 7, // fileVersion
        1: 2, // fileType (ECG)
        28: 1, // connectCable
      });
      _writeU32Le(raw, 2, 1714555815); // measureTime
      _writeU32Le(raw, 10, 30); // recordingTime (s)
      _writeU32Le(raw, 16, 0x00000005); // result: fastHr + irregular
      _writeU16Le(raw, 20, 88); // hr
      _writeU16Le(raw, 22, 100); // qrs
      _writeU16Le(raw, 24, 2); // pvcs
      _writeU16Le(raw, 26, 420); // qtc
      // 4 ECG samples: 100, -100, 200, -32768 (extreme negative)
      _writeI16Le(raw, 48, 100);
      _writeI16Le(raw, 50, -100);
      _writeI16Le(raw, 52, 200);
      _writeI16Le(raw, 54, -32768);

      final f = Bp2File.parse(raw, timezoneOffset: Duration.zero) as Bp2EcgFile;
      expect(f.fileType, 2);
      expect(f.fileVersion, 7);
      expect(f.recordingTime, 30);
      expect(f.duration, const Duration(seconds: 30));
      expect(f.hr, 88);
      expect(f.qrs, 100);
      expect(f.pvcs, 2);
      expect(f.qtc, 420);
      expect(f.connectCable, isTrue);
      expect(f.result, 5);
      expect(f.diagnosis.isFastHr, isTrue);
      expect(f.diagnosis.isIrregular, isTrue);
      expect(f.diagnosis.isPvcs, isFalse);
      // Waveform
      expect(f.waveShortData, [100, -100, 200, -32768]);
      expect(f.waveFloatData[0], closeTo(100 * kBp2EcgMvConversion, 1e-7));
      expect(f.waveFloatData[3], closeTo(-32768 * kBp2EcgMvConversion, 1e-3));
      expect(f.waveData.length, 8);
    });

    test('signed-32 sentinel diagnosis values pass through', () {
      final raw = _buf(48 + 4, {0: 1, 1: 2});
      // result == -1 (poor signal): 0xFFFFFFFF in u32
      _writeU32Le(raw, 16, 0xFFFFFFFF);
      _writeU32Le(raw, 10, 1);
      final f = Bp2File.parse(raw, timezoneOffset: Duration.zero) as Bp2EcgFile;
      expect(f.result, -1);
      expect(f.diagnosis.isPoorSignal, isTrue);
    });

    test('throws on truncated header', () {
      expect(() => Bp2File.parse(_buf(40, {0: 1, 1: 2})), throwsArgumentError);
    });

    test('unknown fileType returns Bp2UnknownFile', () {
      final raw = _buf(40, {0: 9, 1: 9});
      final f = Bp2File.parse(raw);
      expect(f, isA<Bp2UnknownFile>());
      expect(f.fileType, 9);
    });
  });

  group('Er1EcgFile / Er2EcgFile', () {
    /// Build a synthetic ER1/ER2 file with `n` waveform samples.
    Uint8List buildEr1(
      int sampleCount, {
      int recordingTime = 60,
      int dataCrc = 0x1234,
      int magic = 0xDEADBEEF,
      List<int>? samples,
    }) {
      final waveBytes = sampleCount * 2;
      final buf = Uint8List(10 + waveBytes + 20);
      buf[0] = 0x01; // fileVersion
      // Skip reserved header (1..10).
      // Waveform.
      final s =
          samples ?? List.generate(sampleCount, (i) => i - sampleCount ~/ 2);
      for (var i = 0; i < sampleCount; i++) {
        _writeI16Le(buf, 10 + i * 2, s[i]);
      }
      // Trailer
      _writeU32Le(buf, buf.length - 20, recordingTime);
      _writeU16Le(buf, buf.length - 16, dataCrc);
      _writeU32Le(buf, buf.length - 4, magic);
      return buf;
    }

    test('round-trips fileVersion / recordingTime / crc / magic', () {
      final buf = buildEr1(
        100,
        recordingTime: 30,
        dataCrc: 0xABCD,
        magic: 0xCAFEBABE,
      );
      final f = Er1EcgFile.parseEr1(buf);
      expect(f.family, 'er1');
      expect(f.fileVersion, 1);
      expect(f.recordingTime, 30);
      expect(f.duration, const Duration(seconds: 30));
      expect(f.dataCrc, 0xABCD);
      expect(f.magic, 0xCAFEBABE);
      expect(f.sampleCount, 100);
    });

    test('decodes signed-LE samples and applies mV conversion', () {
      final buf = buildEr1(4, samples: [0, 1000, -1000, 32767]);
      final f = Er1EcgFile.parseEr2(buf);
      expect(f.family, 'er2');
      expect(f.waveShortData, [0, 1000, -1000, 32767]);
      expect(f.waveFloatData[0], 0.0);
      expect(f.waveFloatData[1], closeTo(1000 * kEr1EcgMvConversion, 1e-6));
      expect(f.waveFloatData[2], closeTo(-1000 * kEr1EcgMvConversion, 1e-6));
      expect(f.waveFloatData[3], closeTo(32767 * kEr1EcgMvConversion, 1e-3));
    });

    test('throws when file too short (<= 30 bytes)', () {
      // 30 bytes is rejected (header 10 + trailer 20 → 0 wave samples).
      final tooSmall = Uint8List(30);
      expect(() => Er1EcgFile.parseEr1(tooSmall), throwsArgumentError);
    });

    test('parseEr2 yields family=er2', () {
      final buf = buildEr1(50);
      final f = Er1EcgFile.parseEr2(buf);
      expect(f.family, 'er2');
    });
  });

  group('FileReadCompleteEvent.decoded', () {
    test('dispatches BP2 → Bp2BpFile', () {
      final raw = Uint8List(19);
      raw[0] = 1;
      raw[1] = 1;
      raw[17] = 60;
      _writeU32Le(raw, 2, 1714555815);
      _writeU16Le(raw, 11, 120);
      _writeU16Le(raw, 13, 80);
      _writeU16Le(raw, 15, 93);
      final ev = FileReadCompleteEvent(
        model: 19,
        deviceFamily: 'bp2',
        fileName: 'foo.bin',
        content: raw,
      );
      expect(ev.decoded, isA<Bp2BpFile>());
    });

    test('dispatches er1 / er2 → Er1EcgFile', () {
      final buf = Uint8List(40); // header(10) + 10 samples(20) + trailer(20)
      buf[0] = 1;
      _writeU32Le(buf, buf.length - 20, 5);
      _writeU16Le(buf, buf.length - 16, 0);
      _writeU32Le(buf, buf.length - 4, 0);
      final ev1 = FileReadCompleteEvent(
        model: 7,
        deviceFamily: 'er1',
        fileName: 'a',
        content: buf,
      );
      expect(ev1.decoded, isA<Er1EcgFile>());
      expect((ev1.decoded as Er1EcgFile).family, 'er1');

      final ev2 = FileReadCompleteEvent(
        model: 11,
        deviceFamily: 'er2',
        fileName: 'a',
        content: buf,
      );
      expect((ev2.decoded as Er1EcgFile).family, 'er2');
    });

    test('returns null for unknown family or empty content', () {
      final ev = FileReadCompleteEvent(
        model: 0,
        deviceFamily: 'oxy',
        fileName: '',
        content: Uint8List(0),
      );
      expect(ev.decoded, isNull);
      final ev2 = FileReadCompleteEvent(
        model: 0,
        deviceFamily: 'er3',
        fileName: '',
        content: Uint8List.fromList([1, 2, 3]),
      );
      expect(ev2.decoded, isNull);
    });
  });

  group('OxyFile (legacy O2Ring)', () {
    /// Build a minimal legacy oxy file with [n] per-second samples.
    /// Each sample's spo2/pr/vector/flag are set so the parser can
    /// be asserted byte-for-byte.
    Uint8List buildOxy({required int sampleCount}) {
      // header is exactly 40 bytes; pointBytes start at offset 40 with
      // 5 bytes per sample; "size" field at 9..13 = total length.
      final total = 40 + sampleCount * 5;
      final buf = Uint8List(total);
      buf[0] = 3; // fileVersion
      buf[1] = 1; // operationMode
      _writeU16Le(buf, 2, 2025); // year
      buf[4] = 5;
      buf[5] = 26; // month / day
      buf[6] = 13;
      buf[7] = 41;
      buf[8] = 7; // hh:mm:ss
      _writeU32Le(buf, 9, total); // size
      _writeU16Le(buf, 13, sampleCount); // recordingTime
      _writeU16Le(buf, 15, 300); // asleepTime
      buf[17] = 96; // avgSpo2
      buf[18] = 88; // minSpo2
      buf[19] = 4; // dropsTimes3Percent
      buf[20] = 2; // dropsTimes4Percent
      buf[21] = 80; // asleepTimePercent
      _writeU16Le(buf, 22, 50); // durationTime90Percent
      buf[24] = 1; // dropsTimes90Percent
      buf[25] = 92; // o2Score
      _writeU32Le(buf, 26, 5432); // stepCounter
      // Per-sample: spo2 increments, pr=70 + i, vector=20+i, flag combines bits.
      for (var i = 0; i < sampleCount; i++) {
        final base = 40 + i * 5;
        buf[base] = 95 + (i % 6);
        _writeU16Le(buf, base + 1, 70 + i);
        buf[base + 3] = 20 + i;
        // flag: warningSignSpo2 (bit 7) + sleepState = 2 (bits 5..4 = 0b10)
        buf[base + 4] = 0x80 | 0x20;
      }
      return buf;
    }

    test('round-trips header + sample fields', () {
      final raw = buildOxy(sampleCount: 4);
      final f = OxyFile.parse(raw);
      expect(f.fileVersion, 3);
      expect(f.operationMode, 1);
      expect(f.year, 2025);
      expect(f.month, 5);
      expect(f.day, 26);
      expect(f.hour, 13);
      expect(f.minute, 41);
      expect(f.second, 7);
      expect(f.size, raw.length);
      expect(f.recordingTime, 4);
      expect(f.asleepTime, 300);
      expect(f.avgSpo2, 96);
      expect(f.minSpo2, 88);
      expect(f.dropsTimes3Percent, 4);
      expect(f.dropsTimes4Percent, 2);
      expect(f.asleepTimePercent, 80);
      expect(f.durationTime90Percent, 50);
      expect(f.dropsTimes90Percent, 1);
      expect(f.o2Score, 92);
      expect(f.stepCounter, 5432);
      expect(f.data, hasLength(4));
      expect(f.spo2List, [95, 96, 97, 98]);
      expect(f.prList, [70, 71, 72, 73]);
      expect(f.motionList, [20, 21, 22, 23]);
    });

    test('decodes EachData warning bits (corrected) and SDK-buggy parity', () {
      final raw = buildOxy(sampleCount: 1);
      final f = OxyFile.parse(raw);
      final s = f.data.single;
      expect(s.warningSignSpo2, isTrue); // bit 7 set → true (correct)
      expect(s.warningSignVector, isTrue); // bit 5 set → true (correct)
      expect(s.warningSignPr, isFalse);
      expect(s.warningSignInvalid, isFalse);
      // sleepState extracted from bits 5..4 (= 0b10 = 2).
      expect(s.sleepState, 2);
      // SDK-buggy view: `(flag & mask) == 1`, which can never be true
      // for masks > 1.  Preserved for byte-for-byte parity with the
      // Android Java object.
      expect(s.warningSignSpo2Sdk, isFalse);
      expect(s.warningSignVectorSdk, isFalse);
    });

    test('startTime treats wall-clock fields as local time', () {
      final raw = buildOxy(sampleCount: 0);
      final f = OxyFile.parse(raw);
      final expected = DateTime(2025, 5, 26, 13, 41, 7);
      expect(f.startTime, expected.millisecondsSinceEpoch ~/ 1000);
    });

    test('rejects buffers shorter than 40 bytes', () {
      expect(() => OxyFile.parse(Uint8List(39)), throwsArgumentError);
    });
  });

  group('OxyIIFile (modern O2 series)', () {
    /// Build a minimal OxyII file with [n] samples.  Footer is 48 bytes
    /// regardless of sample count.
    Uint8List buildOxyII({
      required int sampleCount,
      required int interval,
      required int rawStartTime,
    }) {
      const headerSize = 10;
      const footerSize = 48;
      final total = headerSize + sampleCount * 3 + footerSize;
      final buf = Uint8List(total);
      buf[0] = 4; // fileVersion
      buf[1] = 1; // fileType
      _writeU16Le(buf, 8, 12345); // deviceModel
      // Per-sample stride = 3 bytes.
      for (var i = 0; i < sampleCount; i++) {
        final base = headerSize + i * 3;
        buf[base] = 95 + (i % 5); // spo2
        buf[base + 1] = 65 + i; // pr
        // motion = (5 & 0x3F) * 2 = 10, remindHr bit, remindSpo2 bit
        buf[base + 2] =
            0x05 | (i.isEven ? 0x40 : 0x00) | (i.isOdd ? 0x80 : 0x00);
      }
      final f = headerSize + sampleCount * 3;
      _writeU32Le(
        buf,
        f + 0,
        0xCAFEBABE,
      ); // checkSum (treated as u32 LE → long)
      _writeU32Le(buf, f + 4, 0xDEADBEEF); // magic
      _writeU32Le(buf, f + 8, rawStartTime); // startTime raw
      _writeU32Le(buf, f + 12, sampleCount); // size
      buf[f + 16] = interval;
      buf[f + 17] = 0; // channelType
      buf[f + 18] = 1; // channelBytes
      _writeU16Le(buf, f + 32, 1500); // percentLessThan90
      buf[f + 34] = 200; // asleepTime
      buf[f + 35] = 95; // avgSpo2
      buf[f + 36] = 87; // minSpo2
      buf[f + 37] = 3; // dropsTimes3Percent
      buf[f + 38] = 1; // dropsTimes4Percent
      _writeU16Le(buf, f + 39, 80); // durationTime90Percent
      buf[f + 41] = 2; // dropsTimes90Percent
      buf[f + 42] = 91; // o2Score
      _writeU32Le(buf, f + 43, 1234); // stepCounter
      buf[f + 47] = 72; // avgHr
      return buf;
    }

    test('round-trips header + samples + footer', () {
      final raw = buildOxyII(sampleCount: 3, interval: 4, rawStartTime: 1000);
      const fixedTz = Duration(hours: 0);
      final f = OxyIIFile.parse(raw, timezoneOffset: fixedTz);
      expect(f.fileVersion, 4);
      expect(f.fileType, 1);
      expect(f.deviceModel, 12345);
      expect(f.spo2List, [95, 96, 97]);
      expect(f.prList, [65, 66, 67]);
      // motion = (0x05 & 0x3F) * 2 = 10
      expect(f.motionList, [10, 10, 10]);
      // sample 0: bit 6 set → remindHr; sample 1: bit 7 set → remindSpo2
      expect(f.remindHrs, [true, false, true]);
      expect(f.remindsSpo2, [false, true, false]);
      expect(f.checkSum, 0xCAFEBABE);
      expect(f.magic, 0xDEADBEEF);
      expect(f.startTimeRaw, 1000);
      expect(f.startTime, 1000); // fixed tz = 0
      expect(f.size, 3);
      expect(f.interval, 4);
      expect(f.recordingTime, 12);
      expect(f.channelType, 0);
      expect(f.channelBytes, 1);
      expect(f.percentLessThan90, 1500);
      expect(f.asleepTime, 200);
      expect(f.avgSpo2, 95);
      expect(f.minSpo2, 87);
      expect(f.dropsTimes3Percent, 3);
      expect(f.dropsTimes4Percent, 1);
      expect(f.durationTime90Percent, 80);
      expect(f.dropsTimes90Percent, 2);
      expect(f.o2Score, 91);
      expect(f.stepCounter, 1234);
      expect(f.avgHr, 72);
      expect(f.sampleCount, 3);
    });

    test('startTime subtracts the supplied timezone offset', () {
      final raw = buildOxyII(
        sampleCount: 1,
        interval: 1,
        rawStartTime: 1_700_000_000,
      );
      final f = OxyIIFile.parse(raw, timezoneOffset: const Duration(hours: 5));
      expect(f.startTimeRaw, 1_700_000_000);
      expect(f.startTime, 1_700_000_000 - 5 * 3600);
    });

    test('rejects too-short and unaligned body lengths', () {
      expect(() => OxyIIFile.parse(Uint8List(57)), throwsArgumentError);
      // 58 bytes is the minimum (zero samples).
      expect(
        () => OxyIIFile.parse(Uint8List(58), timezoneOffset: Duration.zero),
        returnsNormally,
      );
      // 59 bytes = 1 spare byte that doesn't align to 3-byte stride.
      expect(() => OxyIIFile.parse(Uint8List(59)), throwsArgumentError);
    });
  });

  group('Pf10aw1File (Wellue Checkme O2)', () {
    Uint8List buildPf10({
      required int sampleCount,
      required int interval,
      required int rawStartTime,
    }) {
      const headerSize = 10;
      const footerSize = 48;
      final total = headerSize + sampleCount * 2 + footerSize;
      final buf = Uint8List(total);
      buf[0] = 2;
      buf[1] = 1;
      _writeU16Le(buf, 8, 77);
      for (var i = 0; i < sampleCount; i++) {
        buf[headerSize + i * 2] = 90 + i;
        buf[headerSize + i * 2 + 1] = 60 + i;
      }
      final f = headerSize + sampleCount * 2;
      _writeU32Le(buf, f + 0, 0x11223344);
      _writeU32Le(buf, f + 4, 0x55667788);
      _writeU32Le(buf, f + 8, rawStartTime);
      _writeU32Le(buf, f + 12, sampleCount);
      buf[f + 16] = interval;
      buf[f + 17] = 1;
      buf[f + 18] = 2;
      return buf;
    }

    test('round-trips header + samples + footer + endTime', () {
      final raw = buildPf10(sampleCount: 5, interval: 2, rawStartTime: 5000);
      final f = Pf10aw1File.parse(raw, timezoneOffset: Duration.zero);
      expect(f.fileVersion, 2);
      expect(f.fileType, 1);
      expect(f.deviceModel, 77);
      expect(f.spo2List, [90, 91, 92, 93, 94]);
      expect(f.prList, [60, 61, 62, 63, 64]);
      expect(f.checkSum, 0x11223344);
      expect(f.magic, 0x55667788);
      expect(f.startTimeRaw, 5000);
      expect(f.startTime, 5000);
      expect(f.size, 5);
      expect(f.interval, 2);
      expect(f.endTime, 5000 + 5 * 2);
      expect(f.channelType, 1);
      expect(f.channelBytes, 2);
      expect(f.sampleCount, 5);
    });

    test('rejects too-short and unaligned body lengths', () {
      expect(() => Pf10aw1File.parse(Uint8List(57)), throwsArgumentError);
      // 59 bytes = 1 spare byte that doesn't align to 2-byte stride.
      expect(() => Pf10aw1File.parse(Uint8List(59)), throwsArgumentError);
    });
  });

  group('FileReadCompleteEvent.decoded oxy/oxyII/pf10aw1 dispatch', () {
    test('dispatches oxy → OxyFile', () {
      final raw = Uint8List(40);
      raw[0] = 1;
      _writeU32Le(raw, 9, 40); // size = 40 → zero samples
      _writeU16Le(raw, 2, 2024);
      raw[4] = 1;
      raw[5] = 1;
      raw[6] = 0;
      raw[7] = 0;
      raw[8] = 0;
      final ev = FileReadCompleteEvent(
        model: 1,
        deviceFamily: 'oxy',
        fileName: 'a',
        content: raw,
      );
      expect(ev.decoded, isA<OxyFile>());
    });

    test('dispatches oxyII → OxyIIFile', () {
      final raw = Uint8List(58); // header(10) + footer(48), no samples
      raw[0] = 1;
      raw[1] = 1;
      final ev = FileReadCompleteEvent(
        model: 1,
        deviceFamily: 'oxyII',
        fileName: 'a',
        content: raw,
      );
      expect(ev.decoded, isA<OxyIIFile>());
    });

    test('dispatches pf10aw1 → Pf10aw1File', () {
      final raw = Uint8List(58);
      raw[0] = 1;
      raw[1] = 1;
      final ev = FileReadCompleteEvent(
        model: 1,
        deviceFamily: 'pf10aw1',
        fileName: 'a',
        content: raw,
      );
      expect(ev.decoded, isA<Pf10aw1File>());
    });
  });
}
