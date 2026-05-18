import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'lescale_bia_calculator.dart';

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
  static Map<String, dynamic> _userProfile = {
    'height': 180.0,
    'age': 25,
    'isMale': true,
  };

  /// Update the user profile for accurate BIA calculation
  static void setProfile({
    required double heightCm,
    required int age,
    required bool isMale,
  }) {
    _userProfile = {'height': heightCm, 'age': age, 'isMale': isMale};
  }

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

        // User Entry (7 bytes)
        payload[8] = 0x01; // User Index
        payload[9] = (_userProfile['height'] as double).round();
        payload[10] = 0; // Weight High
        payload[11] = 0; // Weight Low
        int genderBit = (_userProfile['isMale'] as bool) ? 1 : 0;
        payload[12] = (genderBit << 7) | ((_userProfile['age'] as int) & 0x7F);
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

    final calc = LescaleBiaCalculator(
      weight: weight,
      heightCm: _userProfile['height'] as double,
      age: _userProfile['age'] as int,
      isMale: _userProfile['isMale'] as bool,
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
      ...report,
    });
  }

  static void _emitRtData(double weight, bool locked, {int? heartRate}) {
    _eventController.add({
      'event': 'rtData',
      'deviceType': 'scale',
      'weightKg': weight.toStringAsFixed(2),
      if (heartRate != null && heartRate > 0) 'heartRate': heartRate,
      'isLocked': locked,
    });
  }
}
