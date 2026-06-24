#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint lthy_ble_plugin.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'lthy_ble_plugin'
  s.version          = '1.0.0'
  s.summary          = 'Flutter plugin for Viatom/Lepu BLE medical devices.'
  s.description      = <<-DESC
Flutter plugin wrapping the official Viatom VTProductLib iOS SDK (and lepu-blepro
on Android) to expose device scanning, connection, and real-time data streaming
for ECG, Oximeter, Blood Pressure and Scale products.
                       DESC
  s.homepage         = 'https://github.com/WeCodeLife2020/Lthy.AI_BLE_Plugin'
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

  # Default build pulls in ECG/BP/Oximeter/AirBP **and** the iComon
  # body-composition scale path. Flutter's `flutter_install_all_ios_pods`
  # only honours a plugin's default subspecs, so anything kept out of the
  # default list silently disables itself in host apps that use the
  # auto-Podfile flow (`FBD_HAS_ICOMON` falls to 0 and the iOS scale
  # falls back to the generic Lescale parser, losing BIA + HR + impedance).
  #
  # The vendored iComon xcframeworks register Objective-C classes whose
  # names collide with Apple's ImageCaptureCore (`ICDevice`,
  # `ICDeviceManager`) and iTunesCloud (`ICDeviceInfo`) private
  # frameworks, so consumers will see a one-time
  #   "objc[...]: Class ICDevice is implemented in both ..."
  # runtime warning. That's harmless (it's a warning, not a crash) and
  # the trade-off is worth it because every supported scale needs
  # iComon to deliver body-composition data.
  #
  # Apps that genuinely don't want the iComon SDK linked in can opt out
  # via their Podfile:
  #
  #   pod 'lthy_ble_plugin', :path => '...', :subspecs => ['Core']
  s.default_subspecs = ['Core', 'IComon']

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
  #     pod 'lthy_ble_plugin', :path => '.../lthy_ble_plugin',
  #         :subspecs => ['Core', 'IComon']
  #   end
  #
  # When included, `LthyBlePlugin.m` compiles with
  # `__has_include(<ICDeviceManager/ICDeviceManager.h>)` satisfied and
  # activates the iComon code paths automatically.
  s.subspec 'IComon' do |ic|
    ic.dependency 'lthy_ble_plugin/Core'
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
