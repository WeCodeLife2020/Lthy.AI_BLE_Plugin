#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_ble_devices.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_ble_devices'
  s.version          = '1.0.0'
  s.summary          = 'Flutter plugin for Viatom/Lepu BLE medical devices.'
  s.description      = <<-DESC
Flutter plugin wrapping the official Viatom VTProductLib iOS SDK (and lepu-blepro
on Android) to expose device scanning, connection, and real-time data streaming
for ECG, Oximeter, Blood Pressure and Scale products.
                       DESC
  s.homepage         = 'https://github.com/wecodelife/flutter_ble_devices'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'WeCodeLife' => 'dev@wecodelife.com' }
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  # Viatom VTProductLib (Obj-C xcframework) used by all subspecs.
  s.dependency 'VTMProductLib', '~> 1.5'

  s.platform         = :ios, '11.0'
  s.ios.deployment_target = '11.0'
  s.swift_version = '5.0'
  s.libraries = 'c++', 'stdc++'
  s.frameworks  = 'CoreBluetooth'

  # Default build pulls in ECG/BP/Oximeter/AirBP support only — the iComon
  # scale SDK is opt-in (see `IComon` subspec below) because its vendored
  # xcframeworks register Objective-C classes whose names collide with
  # Apple's ImageCaptureCore (`ICDevice`, `ICDeviceManager`) and
  # iTunesCloud (`ICDeviceInfo`) private framework. Keeping the default
  # build free of those xcframeworks eliminates the
  #   "objc[...]: Class ICDevice is implemented in both ..."
  # runtime warning for apps that don't need body-composition scales.
  s.default_subspecs = 'Core'

  # ── Core subspec ─────────────────────────────────────────────────────
  # VTMProductLib 1.5 ships a real `ios-arm64_x86_64-simulator` slice, so
  # Apple-Silicon hosts can build & run the iOS Simulator natively — no
  # `EXCLUDED_ARCHS` workaround required.
  s.subspec 'Core' do |cs|
    cs.source_files        = 'Classes/**/*'
    cs.public_header_files = 'Classes/**/*.h'
    cs.pod_target_xcconfig = {
      'DEFINES_MODULE' => 'YES',
      'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
      'OTHER_LDFLAGS' => '$(inherited) -ObjC',
    }
  end

  # ── IComon subspec (opt-in) ──────────────────────────────────────────
  # Pull this in from the host app's Podfile *only* if you need body-
  # composition scale support via the iComon SDK:
  #
  #   target 'Runner' do
  #     pod 'flutter_ble_devices', :path => '.../flutter_ble_devices',
  #         :subspecs => ['Core', 'IComon']
  #   end
  #
  # When included, `FlutterBleDevicesPlugin.m` compiles with
  # `__has_include(<ICDeviceManager/ICDeviceManager.h>)` satisfied and
  # activates the iComon code paths automatically.
  s.subspec 'IComon' do |ic|
    ic.dependency 'flutter_ble_devices/Core'
    ic.vendored_frameworks = [
      'Frameworks/ICDeviceManager.xcframework',
      'Frameworks/ICBleProtocol.xcframework',
      'Frameworks/ICBodyFatAlgorithms.xcframework',
      'Frameworks/ICLogger.xcframework',
    ]
    ic.pod_target_xcconfig = {
      'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 arm64',
      'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
      'OTHER_LDFLAGS' => '$(inherited) -ObjC',
    }
  end
end
