/// Flutter plugin for Viatom/Lepu BLE medical devices.
///
/// Wraps the official lepu-blepro Android SDK and exposes
/// device scanning, connection, and real-time data streaming
/// through a clean Dart API.
library;

export 'src/bluetodev_controller.dart';
export 'src/models/device_control.dart';
export 'src/models/device_info.dart';
export 'src/models/measurement_event.dart';
export 'src/models/device_models.dart';
export 'src/models/file_transfer.dart';
export 'src/lescale_controller.dart';

// Dart-side decoders for the bytes returned by `readFile()`. They run
// identically on Android & iOS, so consumers don't have to special-
// case the platform when decoding ER1/ER2/BP2 recordings.
export 'src/parsers/ecg_diagnosis.dart';
export 'src/parsers/bp2_file.dart';
export 'src/parsers/er1_er2_file.dart';
export 'src/parsers/oxy_files.dart';
