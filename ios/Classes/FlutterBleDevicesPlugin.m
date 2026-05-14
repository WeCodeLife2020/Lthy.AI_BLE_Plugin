//
//  FlutterBleDevicesPlugin.m
//  flutter_ble_devices
//
//  iOS bridge for Viatom/Lepu BLE medical devices.
//
//  Responsibilities:
//   - Scan / connect BLE peripherals via CoreBluetooth (VTProductLib is a
//     protocol layer and does NOT do its own scanning/connection).
//   - Filter & classify discovered peripherals using VTMDeviceTypeMapper so
//     the Dart layer sees the same `model` integers as the Android plugin.
//   - After connection, hand the CBPeripheral to VTMURATUtils (or
//     VTO2Communicate for legacy 0xAA-header O2Ring devices) and forward
//     commands invoked from the Dart side.
//   - Parse real-time responses with VTMBLEParser / VTO2Parser and emit
//     events on the "viatom_ble_stream" EventChannel using the same schema
//     the Android plugin uses.
//

#import "FlutterBleDevicesPlugin.h"
#import "VTMDeviceTypeMapper.h"
#import "VTAirBPPacket.h"

#import <CoreBluetooth/CoreBluetooth.h>
#import <VTMProductLib/VTMProductLib.h>

// Nordic UART service used by the Viatom AirBP / SmartBP.
static NSString *const kAirBPServiceUUID = @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static NSString *const kAirBPTxCharUUID  = @"6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // phone → device (write)
static NSString *const kAirBPRxCharUUID  = @"6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // device → phone (notify)

// iComon scale SDK (vendored under ios/Frameworks/).
//
// The iComon SDK vendors Obj-C classes named `ICDevice`, `ICDeviceManager`
// and `ICDeviceInfo` — which collide with Apple's public
// `ImageCaptureCore.framework` and private `iTunesCloud.framework`. We
// surface that conflict only when the host app opts into the `IComon`
// subspec (see `flutter_ble_devices.podspec`). When the subspec is not
// active the iComon headers aren't on the include path and
// `FBD_HAS_ICOMON` stays 0, which strips every iComon symbol from the
// compiled binary.
#if __has_include(<ICDeviceManager/ICDeviceManager.h>)
    #define FBD_HAS_ICOMON 1
    #import <ICDeviceManager/ICDeviceManager.h>
    #import <ICDeviceManager/ICDeviceManagerDelegate.h>
    #import <ICDeviceManager/ICScanDeviceDelegate.h>
    #import <ICDeviceManager/ICScanDeviceInfo.h>
    #import <ICDeviceManager/ICDevice.h>
    #import <ICDeviceManager/ICDeviceManagerConfig.h>
    #import <ICDeviceManager/ICUserInfo.h>
    #import <ICDeviceManager/ICWeightData.h>
    #import <ICDeviceManager/ICWeightCenterData.h>
    #import <ICDeviceManager/ICWeightHistoryData.h>
    #import <ICDeviceManager/ICKitchenScaleData.h>
    #import <ICDeviceManager/ICRulerData.h>
    #import <ICDeviceManager/ICSkipData.h>
    #import <ICDeviceManager/ICConstant.h>
#else
    #define FBD_HAS_ICOMON 0
#endif

static NSString *const kMethodChannelName = @"viatom_ble";
static NSString *const kEventChannelName  = @"viatom_ble_stream";

#define FBD_LOG(fmt, ...) NSLog(@"[FBDevices] " fmt, ##__VA_ARGS__)

#pragma mark - FlutterBleDevicesPlugin

@interface FlutterBleDevicesPlugin () <FlutterStreamHandler,
                                       CBCentralManagerDelegate,
                                       CBPeripheralDelegate,
                                       VTMURATDeviceDelegate,
                                       VTMURATUtilsDelegate,
                                       VTO2CommunicateDelegate
#if FBD_HAS_ICOMON
                                     , ICDeviceManagerDelegate
                                     , ICScanDeviceDelegate
#endif
>

@property (nonatomic, strong) FlutterMethodChannel *methodChannel;
@property (nonatomic, strong) FlutterEventChannel  *eventChannel;
@property (nonatomic, strong) FlutterEventSink      eventSink;

// BLE stack
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *discovered; // uuidString → peripheral
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *>  *advData;   // uuidString → advertisementData
@property (nonatomic, strong) NSMutableDictionary<NSString *, VTMDeviceMapping *> *mappings; // uuidString → mapping
@property (nonatomic, strong) CBPeripheral *activePeripheral;
@property (nonatomic, strong) VTMDeviceMapping *activeMapping;

// Viatom SDK bridges (only one is active at a time)
@property (nonatomic, strong) VTMURATUtils     *uratUtil;
@property (nonatomic, strong) VTO2Communicate  *o2Util;

#if FBD_HAS_ICOMON
// iComon SDK state — only present when the IComon subspec is active.
@property (nonatomic, assign) BOOL iComonInitialized;
@property (nonatomic, assign) BOOL iComonPendingScan; // queued scan() that arrived before onInitFinish:
@property (nonatomic, strong) NSMutableDictionary<NSString *, ICScanDeviceInfo *> *iComonScans; // macAddr → scan info
@property (nonatomic, strong) ICDevice *activeIComonDevice;
@property (nonatomic, strong) ICUserInfo *currentUserInfo;
#endif

// AirBP state (when activeMapping.protocolPath == VTMProtocolPathAirBP)
@property (nonatomic, strong) CBCharacteristic *airBPTxChar;
@property (nonatomic, strong) CBCharacteristic *airBPRxChar;
@property (nonatomic, strong) NSMutableData    *airBPRxBuffer;

// In-progress URAT file download (BP2 / ER1 / ER2 / WOxi / FOxi / ER3 / MSeries).
// The URAT protocol is three-step: prepareReadFile → readFile:offset (chunked) →
// endReadFile. We hold these here so dispatchURATResponse can drive the
// state machine across the per-chunk responses.
@property (nonatomic, copy)   NSString       *pendingReadFileName;
@property (nonatomic, strong) NSMutableData  *pendingReadBuffer;
@property (nonatomic, assign) uint32_t        pendingReadTotalSize;

// State
@property (nonatomic, assign) BOOL serviceInitialized;
@property (nonatomic, assign) BOOL serviceDeployed;    // services/chars discovered
@property (nonatomic, assign) NSInteger connectedModel;
@property (nonatomic, strong) NSArray<NSNumber *> *scanModelFilter;
@property (nonatomic, assign) BOOL scanRequested;       // scan requested while central not powered on

// Mid-recording catch-up state. When the consumer connects to a device
// that's mid-recording, the live RT stream only carries samples from
// subscription-onward. The *full* recording is persisted to the
// device's flash once the recording finishes; we detect that transition
// (ER1/ER2 curStatus → "saved", BP2 paramDataType → result) and
// auto-trigger a fresh file-list → readFile cycle.
//
// `knownFileNames` is the baseline set captured at connect time so the
// auto-pull only targets genuinely-new entries. Off by default for
// legacy callers; opt-in via connect(... autoFetchOnFinish: true ...)
// which maps to the `autoFetchOnFinish` arg on the connect method call.
@property (nonatomic, assign) BOOL            autoFetchOnFinish;
@property (nonatomic, strong) NSMutableSet<NSString *> *knownFileNames;
// Set by triggerGetFileListForCatchUp (i.e. the recording-finished
// transition) so the next applyFileListForCatchUp: invocation knows
// that a new file exists by definition and must be downloaded — even
// when this is the session's very first enumeration and
// knownFileNames is still empty. See the Android side's
// `pendingCatchUpByModel` for the same fix.
@property (nonatomic, assign) BOOL            pendingCatchUp;
@property (nonatomic, assign) NSInteger       lastEr1CurStatus;
@property (nonatomic, assign) NSInteger       lastEr2CurStatus;
@property (nonatomic, assign) NSInteger       lastBp2ParamDataType;

// Real-time polling (Android's BleServiceHelper.startRtTask drives this
// internally; on iOS we have to poll the URAT channel ourselves for the
// device families whose SDK command is a single-shot GET rather than a
// push subscription).
@property (nonatomic, strong) NSTimer *rtPollTimer;
@property (nonatomic, assign) BOOL measuring;
@property (nonatomic, assign) uint32_t mSeriesPollIndex;

// Pending commands
@property (nonatomic, copy)   FlutterResult pendingInitResult;

// Connection-deploy watchdog. CoreBluetooth's `connectPeripheral:` has
// no timeout — if the peripheral powers off mid-connect or the
// VTMURATUtils service-discovery flow stalls, `utilDeployCompletion:`
// never fires and the consumer is left hanging. We arm this timer in
// `handleConnect:` and cancel it from the deploy callbacks; if it
// fires, we surface a `deploy_timeout` disconnect event and tear the
// connection down. Default 15 s — tuned to comfortably cover service
// discovery on slow peripherals (BP2 Pro is the worst we've seen at
// ~6 s) without leaving stuck UI for too long.
@property (nonatomic, strong) NSTimer *connectionWatchdog;

@end

@implementation FlutterBleDevicesPlugin

#pragma mark - FlutterPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterBleDevicesPlugin *inst = [FlutterBleDevicesPlugin new];
    inst.methodChannel = [FlutterMethodChannel methodChannelWithName:kMethodChannelName
                                                     binaryMessenger:[registrar messenger]];
    [registrar addMethodCallDelegate:inst channel:inst.methodChannel];

    inst.eventChannel = [FlutterEventChannel eventChannelWithName:kEventChannelName
                                                  binaryMessenger:[registrar messenger]];
    [inst.eventChannel setStreamHandler:inst];
    FBD_LOG(@"registered (iComon=%@)", FBD_HAS_ICOMON ? @"YES" : @"NO");
}

- (instancetype)init {
    if ((self = [super init])) {
        _discovered     = [NSMutableDictionary dictionary];
        _advData        = [NSMutableDictionary dictionary];
        _mappings       = [NSMutableDictionary dictionary];
        _connectedModel = -1;
#if FBD_HAS_ICOMON
        _iComonScans    = [NSMutableDictionary dictionary];
        // Mirror every documented default in ICUserInfo.h. `[ICUserInfo new]`
        // zero-inits BOOLs/ints, so without explicit assignment the SDK
        // silently disables impedance / HR / balance / gravity even on
        // supported scales — matching the iComon ICDemo reference VC.
        _currentUserInfo = [ICUserInfo new];
        _currentUserInfo.userIndex               = 1;
        _currentUserInfo.age                     = 25;
        _currentUserInfo.height                  = 175;
        _currentUserInfo.weight                  = 60.0f;
        _currentUserInfo.sex                     = ICSexTypeMale;
        _currentUserInfo.peopleType              = ICPeopleTypeNormal;
        _currentUserInfo.weightUnit              = ICWeightUnitKg;
        _currentUserInfo.rulerUnit               = ICRulerUnitCM;
        _currentUserInfo.rulerMode               = ICRulerMeasureModeLength;
        _currentUserInfo.kitchenUnit             = ICKitchenScaleUnitG;
        _currentUserInfo.enableMeasureImpendence = YES;
        _currentUserInfo.enableMeasureHr         = YES;
        _currentUserInfo.enableMeasureBalance    = YES;
        _currentUserInfo.enableMeasureGravity    = YES;
#endif
    }
    return self;
}

#pragma mark - FlutterStreamHandler

- (FlutterError *_Nullable)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    self.eventSink = events;
    return nil;
}

- (FlutterError *_Nullable)onCancelWithArguments:(id)arguments {
    self.eventSink = nil;
    return nil;
}

- (void)sendEvent:(NSDictionary *)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.eventSink) {
            self.eventSink(event);
        }
    });
}

#pragma mark - MethodChannel dispatch

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSString *method = call.method;
    if ([method isEqualToString:@"initService"])            { [self handleInitService:result];            return; }
    if ([method isEqualToString:@"isServiceReady"])         { result(@(self.serviceInitialized));         return; }
    if ([method isEqualToString:@"checkPermissions"])       { result(@([self isBluetoothPoweredOn]));     return; }
    if ([method isEqualToString:@"requestPermissions"])     { [self handleRequestPermissions:result];     return; }
    if ([method isEqualToString:@"scan"])                   { [self handleScan:call result:result];       return; }
    if ([method isEqualToString:@"stopScan"])               { [self handleStopScan:result];               return; }
    if ([method isEqualToString:@"connect"])                { [self handleConnect:call result:result];    return; }
    if ([method isEqualToString:@"disconnect"])             { [self handleDisconnect:result];             return; }
    if ([method isEqualToString:@"getConnectedModel"])      { result(@(self.connectedModel));             return; }
    if ([method isEqualToString:@"startMeasurement"])       { [self handleStartMeasurement:call result:result]; return; }
    if ([method isEqualToString:@"stopMeasurement"])        { [self handleStopMeasurement:call result:result];  return; }
    if ([method isEqualToString:@"getDeviceInfo"])          { [self handleGetDeviceInfo:call result:result];    return; }
    if ([method isEqualToString:@"getFileList"])            { [self handleGetFileList:call result:result];      return; }
    if ([method isEqualToString:@"readFile"])               { [self handleReadFile:call result:result];         return; }
    if ([method isEqualToString:@"cancelReadFile"])         { [self handleCancelReadFile:call result:result];   return; }
    if ([method isEqualToString:@"readHistoryData"])        { [self handleReadHistoryData:call result:result];  return; }
    if ([method isEqualToString:@"pauseReadFile"]
        || [method isEqualToString:@"continueReadFile"]) {
        // The URAT protocol does not expose pause/continue; advise the
        // caller to disconnect & reconnect for true cancellation.
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"pause/continueReadFile is not supported on iOS; disconnect to abort"
                                   details:nil]);
        return;
    }
    if ([method isEqualToString:@"factoryReset"])           { [self handleFactoryReset:call result:result];     return; }
    if ([method isEqualToString:@"updateUserInfo"])         { [self handleUpdateUserInfo:call result:result]; return; }
    result(FlutterMethodNotImplemented);
}

- (void)handleUpdateUserInfo:(FlutterMethodCall *)call result:(FlutterResult)result {
#if FBD_HAS_ICOMON
    NSNumber *heightNum = call.arguments[@"height"];
    NSNumber *ageNum    = call.arguments[@"age"];
    NSNumber *isMaleNum = call.arguments[@"isMale"];

    ICUserInfo *info = [ICUserInfo new];
    info.userIndex               = 1;
    info.height                  = heightNum ? (NSUInteger)heightNum.doubleValue : 175;
    info.age                     = ageNum    ? (NSUInteger)ageNum.integerValue   : 25;
    info.weight                  = 60.0f;
    info.sex                     = (isMaleNum == nil || isMaleNum.boolValue) ? ICSexTypeMale : ICSexTypeFemal;
    info.peopleType              = ICPeopleTypeNormal;
    info.weightUnit              = ICWeightUnitKg;
    info.rulerUnit               = ICRulerUnitCM;
    info.rulerMode               = ICRulerMeasureModeLength;
    info.kitchenUnit             = ICKitchenScaleUnitG;
    info.enableMeasureImpendence = YES;
    info.enableMeasureHr         = YES;
    info.enableMeasureBalance    = YES;
    info.enableMeasureGravity    = YES;

    self.currentUserInfo = info;
    if (self.iComonInitialized) {
        [[ICDeviceManager shared] updateUserInfo:info];
        FBD_LOG(@"iComon updateUserInfo pushed (height=%lu age=%lu sex=%d)",
                (unsigned long)info.height, (unsigned long)info.age, (int)info.sex);
    }
    result(@YES);
#else
    // iComon subspec not active — silently accept the call so Dart code
    // doesn't need to branch on platform capability. Viatom/AirBP devices
    // do not need this data.
    (void)call;
    result(@YES);
#endif
}

#pragma mark - Service lifecycle

- (void)handleInitService:(FlutterResult)result {
    if (self.central == nil) {
        self.central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    }
#if FBD_HAS_ICOMON
    // Bring up the iComon SDK exactly once (opt-in subspec).
    if (!self.iComonInitialized) {
        // Order matches the 1.3.0_b1312 ICDemo: updateUserInfo → delegate →
        // initMgr. The SDK reads user context during init and during the
        // first scan callback, so pushing it after init creates a window
        // where impedance/HR can be silently disabled on supported scales.
        [[ICDeviceManager shared] updateUserInfo:self.currentUserInfo];
        ICDeviceManagerConfig *cfg = [ICDeviceManagerConfig new];
        cfg.isShowPowerAlert = NO;
        [[ICDeviceManager shared] setDelegate:self];
        [[ICDeviceManager shared] initMgrWithConfig:cfg];
        // iComonInitialized becomes YES once onInitFinish:YES fires.
        FBD_LOG(@"iComon SDK init requested (userIndex=%lu height=%lu sex=%d impedance=%d hr=%d)",
                (unsigned long)self.currentUserInfo.userIndex,
                (unsigned long)self.currentUserInfo.height,
                (int)self.currentUserInfo.sex,
                (int)self.currentUserInfo.enableMeasureImpendence,
                (int)self.currentUserInfo.enableMeasureHr);
    }
#endif
    self.serviceInitialized = YES;
    FBD_LOG(@"initService complete");
    [self sendEvent:@{@"event": @"serviceReady"}];
    result(@YES);
}

- (void)handleRequestPermissions:(FlutterResult)result {
    // iOS surfaces the BT usage prompt automatically when CBCentralManager
    // is instantiated; all we can do is nudge creation and report whether
    // Bluetooth is powered on.
    if (self.central == nil) {
        self.central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    }
    result(@([self isBluetoothPoweredOn]));
}

- (BOOL)isBluetoothPoweredOn {
    return self.central != nil && self.central.state == CBManagerStatePoweredOn;
}

#pragma mark - Scan / stop scan

- (void)handleScan:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (!self.serviceInitialized) {
        result([FlutterError errorWithCode:@"NOT_INITIALIZED" message:@"Call initService first" details:nil]);
        return;
    }
    NSArray *models = call.arguments[@"models"];
    self.scanModelFilter = ([models isKindOfClass:NSArray.class]) ? models : nil;

    // NOTE: we deliberately do NOT clear `discovered`/`advData`/`mappings`
    // on rescan. Consumers commonly drive the UI as scan() → user picks
    // → connect(mac), but they may also re-trigger scan() before
    // committing (refresh button, retry-after-error, etc.). Wiping the
    // cache means the user can hit "connect" with a mac that was
    // discovered seconds ago but is no longer in `discovered` because a
    // rescan zeroed it. The peripheral instance is still valid — keep
    // it. Garbage-collection happens naturally on disconnect or on
    // app-lifecycle teardown.

    if (![self isBluetoothPoweredOn]) {
        // Defer until powered-on via centralManagerDidUpdateState:
        self.scanRequested = YES;
        FBD_LOG(@"scan deferred — BT not powered on (state=%ld)", (long)self.central.state);
        result(@YES);
        return;
    }
    [self startCentralScan];
#if FBD_HAS_ICOMON
    // iComon SDK scans independently via its own CBCentralManager. If
    // init is still in flight, queue the request — `onInitFinish:` will
    // replay it once the SDK is ready.
    if (self.iComonInitialized) {
        [self.iComonScans removeAllObjects];
        [[ICDeviceManager shared] scanDevice:self];
        self.iComonPendingScan = NO;
    } else {
        self.iComonPendingScan = YES;
        FBD_LOG(@"iComon scan deferred — onInitFinish has not fired yet");
    }
#endif
    FBD_LOG(@"scan started (models=%@, cache=%lu peripherals)",
            self.scanModelFilter ?: @"any", (unsigned long)self.discovered.count);
    result(@YES);
}

- (void)startCentralScan {
    // AllowDuplicates=YES so we keep getting adv reports for the same
    // peripheral. Some Viatom devices (notably ER1 family) initially
    // advertise with an empty/short local name, then complete the name
    // a few packets later — if duplicates are suppressed we miss the
    // complete name and `mappingForAdvertisedName:` returns nil. The
    // small extra battery cost is worth the discovery reliability.
    [self.central scanForPeripheralsWithServices:nil
                                         options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @YES}];
    self.scanRequested = NO;
}

- (void)handleStopScan:(FlutterResult)result {
    if (self.central.isScanning) {
        [self.central stopScan];
    }
#if FBD_HAS_ICOMON
    if (self.iComonInitialized) {
        [[ICDeviceManager shared] stopScan];
    }
    self.iComonPendingScan = NO;
#endif
    self.scanRequested = NO;
    FBD_LOG(@"scan stopped");
    result(@YES);
}

#pragma mark - Connect / disconnect

- (void)handleConnect:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSString *mac  = call.arguments[@"mac"];
    NSNumber *modelObj = call.arguments[@"model"];
    NSString *sdk  = call.arguments[@"sdk"] ?: @"lepu";

    // Reset catch-up bookkeeping on every new connect so a stale baseline
    // from a prior device never confuses the auto-pull diff.
    NSNumber *autoBox = call.arguments[@"autoFetchOnFinish"];
    self.autoFetchOnFinish    = (autoBox != nil) ? autoBox.boolValue : YES;
    self.knownFileNames       = [NSMutableSet set];
    self.pendingCatchUp       = NO;
    self.lastEr1CurStatus     = -1;
    self.lastEr2CurStatus     = -1;
    self.lastBp2ParamDataType = -1;

    if ([sdk isEqualToString:@"icomon"]) {
#if FBD_HAS_ICOMON
        if (!self.iComonInitialized) {
            result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                                       message:@"iComon SDK not ready — onInitFinish has not fired yet. Retry shortly."
                                       details:nil]);
            return;
        }
        if (mac.length == 0) {
            result([FlutterError errorWithCode:@"INVALID_ARGS" message:@"mac is required" details:nil]);
            return;
        }
        ICDevice *dev = [ICDevice new];
        dev.macAddr = mac;
        self.activeIComonDevice = dev;

        VTMDeviceMapping *mapping = [VTMDeviceMapping new];
        mapping.vtmDeviceType = VTMDeviceTypeUnknown;
        mapping.lepuModel     = -1;
        mapping.protocolPath  = VTMProtocolPathIComon;
        mapping.family        = @"icomon";
        mapping.deviceType    = @"scale";
        self.activeMapping    = mapping;

        FBD_LOG(@"connect iComon mac=%@", mac);
        [[ICDeviceManager shared] addDevice:dev callback:^(ICDevice * _Nonnull device, ICAddDeviceCallBackCode code) {
            // Connection state update comes through onDeviceConnectionChanged:state:
        }];
        // Mirror the URAT/AirBP lifecycle so Dart sees `connecting` on
        // every protocol path; `onDeviceConnectionChanged:` will cancel
        // the watchdog and emit `connected` on success.
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"connecting",
                          @"mac": mac ?: @"",
                          @"sdk": @"icomon",
                          @"family": @"icomon",
                          @"deviceType": @"scale"}];
        [self armConnectionWatchdog];
        result(@YES);
        return;
#else
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"iComon scale support is not compiled in. Add the 'IComon' subspec to your Podfile — see flutter_ble_devices README."
                                   details:nil]);
        return;
#endif
    }

    if (mac.length == 0) {
        result([FlutterError errorWithCode:@"INVALID_ARGS" message:@"mac is required" details:nil]);
        return;
    }
    CBPeripheral *peripheral = self.discovered[mac];
    if (peripheral == nil) {
        // Try to recover by identifier lookup in case the device was seen in
        // a prior scan session.
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:mac];
        if (uuid) {
            NSArray *known = [self.central retrievePeripheralsWithIdentifiers:@[uuid]];
            if (known.count > 0) peripheral = known.firstObject;
        }
    }
    if (peripheral == nil) {
        // The peripheral is unknown to CoreBluetooth in this process —
        // either scan() was never called, or the OS evicted the
        // peripheral after a long idle. Either way the consumer must
        // re-scan; we return a structured error with a clearer
        // recovery hint than the generic UNKNOWN_DEVICE.
        FBD_LOG(@"connect failed — unknown peripheral mac=%@ (cache=%lu)",
                mac, (unsigned long)self.discovered.count);
        result([FlutterError errorWithCode:@"UNKNOWN_DEVICE"
                                   message:@"Peripheral not in CoreBluetooth cache. Call scan() and wait for the deviceFound event before connect()."
                                   details:@{@"mac": mac ?: @"",
                                             @"cacheSize": @(self.discovered.count)}]);
        return;
    }

    VTMDeviceMapping *mapping = self.mappings[mac];
    if (mapping == nil && modelObj != nil) {
        mapping = [VTMDeviceTypeMapper mappingForLepuModel:modelObj.integerValue];
    }
    if (mapping == nil) {
        result([FlutterError errorWithCode:@"UNSUPPORTED_DEVICE"
                                   message:@"Device model is not recognised by VTProductLib"
                                   details:nil]);
        return;
    }

    self.activePeripheral = peripheral;
    self.activeMapping    = mapping;
    self.serviceDeployed  = NO;

    // Stop scanning to free the radio for GATT.
    if (self.central.isScanning) [self.central stopScan];

    FBD_LOG(@"connect mac=%@ family=%@ model=%ld path=%d", mac, mapping.family,
            (long)mapping.lepuModel, (int)mapping.protocolPath);
    [self.central connectPeripheral:peripheral options:nil];

    // Surface a `connecting` state immediately so the consumer can
    // distinguish "connect() returned" from "peripheral actually
    // linked". Without this, the Dart side only sees `connected` /
    // `disconnected` and has no way to drive a spinner during the
    // (sometimes >5 s) service-discovery phase.
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"connecting",
                      @"model": @(mapping.lepuModel),
                      @"family": mapping.family ?: @"unknown",
                      @"deviceType": mapping.deviceType ?: @"unknown"}];

    [self armConnectionWatchdog];
    result(@YES);
}

- (void)armConnectionWatchdog {
    [self.connectionWatchdog invalidate];
    __weak typeof(self) weakSelf = self;
    self.connectionWatchdog = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                              repeats:NO
                                                                block:^(NSTimer * _Nonnull timer) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (strongSelf.serviceDeployed) return; // already up; spurious fire
        FBD_LOG(@"connection watchdog fired — deploy_timeout for mapping=%@",
                strongSelf.activeMapping.family ?: @"unknown");
        if (strongSelf.activePeripheral) {
            [strongSelf.central cancelPeripheralConnection:strongSelf.activePeripheral];
        }
        [strongSelf sendEvent:@{@"event": @"connectionState",
                                @"state": @"disconnected",
                                @"reason": @"deploy_timeout"}];
    }];
}

- (void)cancelConnectionWatchdog {
    [self.connectionWatchdog invalidate];
    self.connectionWatchdog = nil;
}

- (void)handleDisconnect:(FlutterResult)result {
#if FBD_HAS_ICOMON
    if (self.activeMapping.protocolPath == VTMProtocolPathIComon && self.activeIComonDevice) {
        [[ICDeviceManager shared] removeDevice:self.activeIComonDevice
                                      callback:^(ICDevice * _Nonnull device, ICRemoveDeviceCallBackCode code) {}];
        self.activeIComonDevice = nil;
    } else if (self.activePeripheral) {
        [self.central cancelPeripheralConnection:self.activePeripheral];
    }
#else
    if (self.activePeripheral) {
        [self.central cancelPeripheralConnection:self.activePeripheral];
    }
#endif
    // Tear down Viatom utils + any in-flight file download state.
    [self stopRtPoll];
    self.uratUtil = nil;
    self.o2Util   = nil;
    self.pendingReadFileName  = nil;
    self.pendingReadBuffer    = nil;
    self.pendingReadTotalSize = 0;
    self.connectedModel = -1;
    self.serviceDeployed = NO;
    FBD_LOG(@"disconnect requested");
    result(@YES);
}

#pragma mark - Measurement / info / file list / factory reset

- (void)handleStartMeasurement:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;

    // Optional `mode` argument — currently only used by the BP family to
    // switch the device into BP-measure vs ECG-measure vs history review
    // before real-time polling begins.
    NSString *mode = [call.arguments isKindOfClass:NSDictionary.class]
                   ? (call.arguments[@"mode"] ?: @"")
                   : @"";

    if (m.protocolPath == VTMProtocolPathIComon) {
        // iComon scales stream weight data automatically after connection —
        // no explicit start command is required.
        result(@YES);
        return;
    }
    if (m.protocolPath == VTMProtocolPathAirBP) {
        [self writeAirBPCommand:VTAirBPCmdStartMeasure payload:nil];
        result(@YES);
        return;
    }
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        [self.o2Util beginGetRealData];
        [self.o2Util beginGetRealWave];
        self.measuring = YES;
        result(@YES);
        return;
    }

    // URAT path. Kick off the first poll synchronously so Dart sees
    // feedback immediately, then schedule a repeating timer because
    // most Viatom URAT commands are single-shot GETs.
    switch (m.vtmDeviceType) {
        case VTMDeviceTypeECG: {
            [self.uratUtil requestECGRealData];
            [self startRtPollEvery:0.3 withBlock:^(VTMURATUtils *u) {
                [u requestECGRealData];
            }];
            break;
        }
        case VTMDeviceTypeBP: {
            // Android's startRtTask(bp2) implicitly flips the BP2 into
            // the requested measurement mode before polling.  Mirror
            // that: 0=BP, 1=ECG, 2=history, 3=ready, 4=shutdown.
            u_char target = VTMBPTargetStatusBP;
            if ([mode isEqualToString:@"ecg"])      target = VTMBPTargetStatusECG;
            else if ([mode isEqualToString:@"history"]) target = VTMBPTargetStatusHistory;
            else if ([mode isEqualToString:@"ready"])   target = VTMBPTargetStatusStart;
            else if ([mode isEqualToString:@"off"])     target = VTMBPTargetStatusEnd;
            [self.uratUtil requestChangeBPState:target];
            [self.uratUtil requestBPRealData];
            [self startRtPollEvery:0.4 withBlock:^(VTMURATUtils *u) {
                [u requestBPRealData];
            }];
            break;
        }
        case VTMDeviceTypeScale: {
            [self.uratUtil requestScaleRealData];
            [self.uratUtil requestScaleRealWve];
            [self startRtPollEvery:0.3 withBlock:^(VTMURATUtils *u) {
                [u requestScaleRealData];
                [u requestScaleRealWve];
            }];
            break;
        }
        case VTMDeviceTypeER3: {
            [self.uratUtil requestER3ECGRealData];
            [self startRtPollEvery:0.5 withBlock:^(VTMURATUtils *u) {
                [u requestER3ECGRealData];
            }];
            break;
        }
        case VTMDeviceTypeMSeries: {
            self.mSeriesPollIndex = 0;
            [self.uratUtil requestMSeriesRunParamsWithIndex:0];
            [self startRtPollEvery:0.5 withBlock:^(VTMURATUtils *u) {
                [u requestMSeriesRunParamsWithIndex:self.mSeriesPollIndex++];
            }];
            break;
        }
        case VTMDeviceTypeWOxi: {
            // Push subscription — no polling required.
            [self.uratUtil observeParameters:YES waveform:YES rawdata:NO accdata:NO];
            [self.uratUtil woxi_requestWOxiRealData];
            self.measuring = YES;
            break;
        }
        case VTMDeviceTypeFOxi: {
            // Push subscription — no polling required.
            [self.uratUtil foxi_makeInfoSend:YES];
            [self.uratUtil foxi_makeWaveSend:YES];
            self.measuring = YES;
            break;
        }
        case VTMDeviceTypeBabyPatch: {
            [self.uratUtil baby_requestRunParams];
            [self startRtPollEvery:2.0 withBlock:^(VTMURATUtils *u) {
                [u baby_requestRunParams];
            }];
            break;
        }
        default:
            break;
    }
    result(@YES);
}

- (void)handleStopMeasurement:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    [self stopRtPoll];
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath == VTMProtocolPathIComon) {
        result(@YES);
        return;
    }
    if (m.protocolPath == VTMProtocolPathAirBP) {
        [self writeAirBPCommand:VTAirBPCmdStopMeasure payload:nil];
        result(@YES);
        return;
    }
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        // VTO2Communicate has no explicit stop-real-time; stop pushing by
        // disconnecting observation is handled implicitly on disconnect.
    } else if (m.vtmDeviceType == VTMDeviceTypeWOxi) {
        [self.uratUtil observeParameters:NO waveform:NO rawdata:NO accdata:NO];
    } else if (m.vtmDeviceType == VTMDeviceTypeFOxi) {
        [self.uratUtil foxi_makeInfoSend:NO];
        [self.uratUtil foxi_makeWaveSend:NO];
    } else if (m.vtmDeviceType == VTMDeviceTypeECG) {
        [self.uratUtil exitER1MeasurementMode];
    } else if (m.vtmDeviceType == VTMDeviceTypeER3) {
        [self.uratUtil exitER3MeasurementMode];
    }
    result(@YES);
}

#pragma mark - Real-time polling

- (void)startRtPollEvery:(NSTimeInterval)interval
               withBlock:(void (^)(VTMURATUtils *util))tick {
    [self stopRtPoll];
    self.measuring = YES;
    __weak typeof(self) weakSelf = self;
    self.rtPollTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                        repeats:YES
                                                          block:^(NSTimer * _Nonnull t) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s == nil) { [t invalidate]; return; }
        if (!s.measuring || s.uratUtil == nil) { [t invalidate]; return; }
        tick(s.uratUtil);
    }];
}

- (void)stopRtPoll {
    self.measuring = NO;
    if (self.rtPollTimer) {
        [self.rtPollTimer invalidate];
        self.rtPollTimer = nil;
    }
}

- (void)handleGetDeviceInfo:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath == VTMProtocolPathIComon) {
        // Device info for iComon scales arrives via onReceiveDeviceInfo: — no
        // explicit request API exists in this SDK version.
        result(@YES);
        return;
    }
    if (m.protocolPath == VTMProtocolPathAirBP) {
        [self writeAirBPCommand:VTAirBPCmdGetInfo payload:nil];
        result(@YES);
        return;
    }
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        [self.o2Util beginGetInfo];
    } else {
        [self.uratUtil requestDeviceInfo];
    }
    result(@YES);
}

- (void)handleGetFileList:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath == VTMProtocolPathIComon) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"iComon scales do not expose a file list API."
                                   details:nil]);
        return;
    }
    if (m.protocolPath == VTMProtocolPathAirBP) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"AirBP historical-record browsing is not wired yet."
                                   details:nil]);
        return;
    }
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"File list on legacy O2 path uses prepareReadFile; not yet wired."
                                   details:nil]);
        return;
    }
    [self.uratUtil requestFilelist];
    result(@YES);
}

#pragma mark - iComon scale "read all stored history"

// Welland-family scales buffer offline measurements; they replay them
// through `onReceiveWeightHistoryData:` either automatically on BLE
// reconnect or on demand when the consumer calls readHistoryData:.
//
// The settingManager singleton lives on ICDeviceManager; reaching it
// does not require the scale to be connected but readHistoryData: does.
- (void)handleReadHistoryData:(FlutterMethodCall *)call
                       result:(FlutterResult)result {
#if FBD_HAS_ICOMON
    ICDevice *dev = self.activeIComonDevice;
    if (dev == nil) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"readHistoryData is iComon-scale only; connect with sdk='icomon' first"
                                   details:nil]);
        return;
    }
    [[[ICDeviceManager shared] getSettingManager]
        readHistoryData:dev
               callback:^(ICSettingCallBackCode code) {
        FBD_LOG(@"iComon readHistoryData returned code=%d", (int)code);
    }];
    result(@YES);
#else
    (void)call;
    result([FlutterError errorWithCode:@"UNSUPPORTED"
                               message:@"iComon scale support is not compiled in."
                               details:nil]);
#endif
}

#pragma mark - File transfer (history download)

// File-transfer family classification — pulls the exact `family` string
// already chosen by VTMDeviceTypeMapper so Dart consumers see the same
// values the Android plugin emits ("er1" / "er2" / "bp2" / "oxy" / ...).
- (NSString *)fileFamilyForActiveMapping {
    NSString *family = self.activeMapping.family;
    return family.length ? family : @"unknown";
}

// ── Mid-recording catch-up ──────────────────────────────────────────
//
// See the header-level comment on `autoFetchOnFinish` for the wire
// semantics. On iOS the transition detection lives in the URAT rtData
// dispatch path for ER1/ER2 and in the BP2 `paramDataType` handler; the
// file-list diff logic is identical to Android.

- (void)emitRecordingFinishedForFamily:(NSString *)family {
    if (family.length == 0) family = [self fileFamilyForActiveMapping];
    [self sendEvent:@{@"event":        @"recordingFinished",
                      @"deviceFamily": family,
                      @"model":        @(self.connectedModel)}];
}

/// Ask the device for a fresh file list — the corresponding fileList
/// event will in turn trigger `applyFileListForCatchUp:` below. On the
/// legacy O2 path the file list is embedded in `getInfo` so we re-issue
/// that; on URAT families a dedicated `requestFilelist` exists.
///
/// This method is only invoked from the two recording-finished
/// transition points (URAT curStatus→4 for ER1/ER2 and BP2 param-type
/// → result), so setting `pendingCatchUp = YES` here is safe and
/// eliminates any risk of forgetting the flag at a callsite.
- (void)triggerGetFileListForCatchUp {
    self.pendingCatchUp = YES;
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath == VTMProtocolPathURAT && self.uratUtil) {
        [self.uratUtil requestFilelist];
    } else if (m.protocolPath == VTMProtocolPathO2Legacy && self.o2Util) {
        [self.o2Util beginGetInfo];
    }
}

/// Diff a freshly-received file list against `knownFileNames` and
/// auto-pull any new entries (when `autoFetchOnFinish` is enabled).
/// The first list we see on a connection normally becomes the
/// baseline so that pre-existing recordings don't get mass-downloaded
/// unexpectedly — unless `pendingCatchUp` is set, meaning this
/// enumeration was triggered by a recording-finished transition and a
/// new file is guaranteed to exist (fall back to the tail of the
/// list, which Lepu returns in ascending chronological order, if for
/// some reason there's no diff against the empty baseline).
- (void)applyFileListForCatchUp:(NSArray<NSString *> *)files {
    if (files.count == 0) return;
    BOOL isFirstList       = (self.knownFileNames.count == 0);
    BOOL hasPendingCatchUp = self.pendingCatchUp;
    self.pendingCatchUp    = NO;

    NSMutableArray<NSString *> *diff = [NSMutableArray array];
    for (NSString *name in files) {
        if (name.length == 0) continue;
        if (![self.knownFileNames containsObject:name]) {
            [diff addObject:name];
        }
    }
    [self.knownFileNames addObjectsFromArray:files];
    if (!self.autoFetchOnFinish) return;

    NSArray<NSString *> *toFetch = nil;
    if (hasPendingCatchUp && diff.count > 0) {
        toFetch = diff;
    } else if (hasPendingCatchUp && files.count > 0) {
        toFetch = @[ files.lastObject ]; // tail = newest recording
    } else if (isFirstList || diff.count == 0) {
        return; // plain baseline enumeration
    } else {
        toFetch = diff;
    }

    FBD_LOG(@"auto-fetching %lu file(s): %@ "
            @"(pendingCatchUp=%d, isFirstList=%d)",
            (unsigned long)toFetch.count, toFetch,
            hasPendingCatchUp, isFirstList);
    VTMDeviceMapping *m = self.activeMapping;
    // The URAT state machine only supports one in-flight transfer at a
    // time; kick off the first and let the client call readFile() for
    // subsequent entries on the fileReadComplete event. In practice the
    // diff is almost always a single file (the one just saved).
    for (NSString *name in toFetch) {
        if (self.pendingReadFileName != nil) break;
        if (m.protocolPath == VTMProtocolPathURAT) {
            self.pendingReadFileName  = name;
            self.pendingReadBuffer    = [NSMutableData data];
            self.pendingReadTotalSize = 0;
            [self.uratUtil prepareReadFile:name];
        } else if (m.protocolPath == VTMProtocolPathO2Legacy) {
            self.pendingReadFileName  = name;
            self.pendingReadBuffer    = nil;
            self.pendingReadTotalSize = 0;
            [self.o2Util beginReadFileWithFileName:name];
        }
    }
}

- (void)handleReadFile:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    NSString *fileName = call.arguments[@"fileName"];
    if (fileName.length == 0) {
        result([FlutterError errorWithCode:@"BAD_ARG"
                                   message:@"fileName is required"
                                   details:nil]);
        return;
    }
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath == VTMProtocolPathIComon) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"iComon scales have no on-device file storage."
                                   details:nil]);
        return;
    }
    if (m.protocolPath == VTMProtocolPathAirBP) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"AirBP devices have no on-device file storage."
                                   details:nil]);
        return;
    }
    if (self.pendingReadFileName != nil) {
        result([FlutterError errorWithCode:@"BUSY"
                                   message:@"A file read is already in progress; wait for fileReadComplete or disconnect."
                                   details:nil]);
        return;
    }

    // Legacy O2 path has a one-shot API that handles chunking + progress
    // internally and surfaces results through `postCurrentReadProgress:` /
    // `readCompleteWithData:`.
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        self.pendingReadFileName  = fileName;
        self.pendingReadBuffer    = nil;
        self.pendingReadTotalSize = 0;
        [self.o2Util beginReadFileWithFileName:fileName];
        result(@YES);
        return;
    }

    // URAT path — three-step protocol. We send `prepareReadFile`; the
    // device responds with VTMBLECmdStartRead carrying the file length,
    // which dispatchURATResponse uses to bootstrap the chunked download.
    self.pendingReadFileName  = fileName;
    self.pendingReadBuffer    = [NSMutableData data];
    self.pendingReadTotalSize = 0;
    [self.uratUtil prepareReadFile:fileName];
    result(@YES);
}

- (void)handleCancelReadFile:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (self.pendingReadFileName == nil) {
        result(@NO);
        return;
    }
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath != VTMProtocolPathO2Legacy && self.uratUtil != nil) {
        // Best effort — tell the device we're done; it will resume serving
        // other commands once it sees endReadFile.
        [self.uratUtil endReadFile];
    }
    NSString *fileName = self.pendingReadFileName;
    self.pendingReadFileName  = nil;
    self.pendingReadBuffer    = nil;
    self.pendingReadTotalSize = 0;
    [self sendEvent:@{@"event": @"fileReadError",
                      @"deviceFamily": [self fileFamilyForActiveMapping],
                      @"model": @(self.connectedModel),
                      @"fileName": fileName ?: @"",
                      @"error": @"cancelled"}];
    result(@YES);
}

- (void)handleFactoryReset:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath == VTMProtocolPathIComon) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"Factory reset is not exposed by the iComon SDK."
                                   details:nil]);
        return;
    }
    if (m.protocolPath == VTMProtocolPathAirBP) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"Factory reset is not exposed by the AirBP protocol wrapper."
                                   details:nil]);
        return;
    }
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        [self.o2Util beginFactory];
    } else {
        [self.uratUtil factoryReset];
    }
    result(@YES);
}

- (BOOL)ensureReady:(FlutterResult)result {
    // A connection is ready when we have a mapping AND the underlying SDK
    // has reported that services are up. For iComon scales there is no
    // Lepu model id, so `connectedModel` is allowed to stay -1.
    if (self.activeMapping == nil || !self.serviceDeployed) {
        result([FlutterError errorWithCode:@"NOT_CONNECTED"
                                   message:@"No device connected / services not deployed yet"
                                   details:nil]);
        return NO;
    }
    return YES;
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    FBD_LOG(@"centralManagerDidUpdateState=%ld", (long)central.state);
    if (central.state == CBManagerStatePoweredOn) {
        if (self.scanRequested) {
            [self startCentralScan];
        }
    } else {
        // Surface disconnect when bluetooth goes away.
        if (self.activePeripheral) {
            [self sendEvent:@{@"event": @"connectionState",
                              @"state": @"disconnected",
                              @"reason": @"bluetooth_off"}];
        }
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSString *name = advertisementData[CBAdvertisementDataLocalNameKey];
    if (name.length == 0) name = peripheral.name;
    VTMDeviceMapping *mapping = [VTMDeviceTypeMapper mappingForAdvertisedName:name];
    if (mapping == nil) return;  // Not a Viatom device we recognise.

    // Honour scan model filter when provided.
    if (self.scanModelFilter.count > 0 &&
        ![self.scanModelFilter containsObject:@(mapping.lepuModel)]) {
        return;
    }

    NSString *uuid = peripheral.identifier.UUIDString;
    self.discovered[uuid] = peripheral;
    self.advData[uuid]    = advertisementData;
    self.mappings[uuid]   = mapping;

    NSString *sdkLabel = (mapping.protocolPath == VTMProtocolPathAirBP) ? @"airbp" : @"lepu";
    [self sendEvent:@{@"event": @"deviceFound",
                      @"name":  name ?: @"",
                      @"mac":   uuid,
                      @"model": @(mapping.lepuModel),
                      @"rssi":  RSSI ?: @0,
                      @"sdk":   sdkLabel,
                      @"deviceType": mapping.deviceType,
                      @"family": mapping.family}];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    VTMDeviceMapping *m = self.activeMapping;
    if (m == nil) m = self.mappings[peripheral.identifier.UUIDString];
    FBD_LOG(@"didConnect uuid=%@ path=%d family=%@",
            peripheral.identifier.UUIDString, (int)m.protocolPath, m.family);

    if (m.protocolPath == VTMProtocolPathAirBP) {
        // AirBP is a plain Nordic-UART device — we drive the peripheral
        // directly. We MUST set ourselves as the CBPeripheralDelegate
        // because there's no SDK util in this path.
        peripheral.delegate = self;
        self.uratUtil = nil;
        self.o2Util   = nil;
        self.airBPRxBuffer = [NSMutableData data];
        [peripheral discoverServices:@[[CBUUID UUIDWithString:kAirBPServiceUUID]]];
        return;
    }

    // For URAT and legacy-O2 paths, the SDK takes ownership of the
    // peripheral and its CBPeripheralDelegate via `setPeripheral:` —
    // it then drives `discoverServices` / `discoverCharacteristics`
    // internally and notifies us through `utilDeployCompletion:`
    // (URAT) or `o2_serviceDeployed:` (legacy O2). Setting
    // `peripheral.delegate = self` here would be quickly clobbered
    // and risk a brief window where messages route to us with no
    // handler in place. The official viatom-dev demo (`VTConnectViewController.m`)
    // assigns the peripheral to the SDK util WITHOUT touching the
    // CBPeripheralDelegate — we mirror that exactly.
    NSDictionary *advData = self.advData[peripheral.identifier.UUIDString];
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        VTO2Communicate *util = [VTO2Communicate new];
        util.o2Delegate = self;
        util.delegate   = self;
        util.deviceDelegate = self;
        if (advData) util.advertisementData = advData;
        util.peripheral = peripheral;
        self.o2Util = util;
        self.uratUtil = nil;
        FBD_LOG(@"VTO2Communicate util attached — awaiting o2_serviceDeployed:");
    } else {
        VTMURATUtils *util = [VTMURATUtils new];
        util.delegate = self;
        util.deviceDelegate = self;
        if (advData) util.advertisementData = advData;
        util.peripheral = peripheral;
        self.uratUtil = util;
        self.o2Util = nil;
        FBD_LOG(@"VTMURATUtils util attached — awaiting utilDeployCompletion:");
    }
    // We do NOT yet emit "connected" — we wait for the deploy callback.
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    FBD_LOG(@"didFailToConnect uuid=%@ err=%@",
            peripheral.identifier.UUIDString, error.localizedDescription);
    [self cancelConnectionWatchdog];
    self.activePeripheral = nil;
    self.activeMapping    = nil;
    self.connectedModel   = -1;
    self.serviceDeployed  = NO;
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"disconnected",
                      @"reason": error.localizedDescription ?: @"connect_failed"}];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    FBD_LOG(@"didDisconnect uuid=%@ err=%@",
            peripheral.identifier.UUIDString, error.localizedDescription);
    [self cancelConnectionWatchdog];
    [self stopRtPoll];
    // Surface any in-flight file read as a `cancelled` error so the Dart
    // future doesn't hang.
    if (self.pendingReadFileName != nil) {
        [self emitFileReadError:@"disconnected"];
    }
    self.activePeripheral = nil;
    self.activeMapping    = nil;
    self.connectedModel   = -1;
    self.serviceDeployed  = NO;
    self.uratUtil         = nil;
    self.o2Util           = nil;
    self.airBPTxChar      = nil;
    self.airBPRxChar      = nil;
    self.airBPRxBuffer    = nil;
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"disconnected",
                      @"reason": error.localizedDescription ?: @"user_initiated"}];
}

#pragma mark - VTMURATDeviceDelegate  (URAT / WOxi / FOxi / ...)

- (void)utilDeployCompletion:(VTMURATUtils *)util {
    [self cancelConnectionWatchdog];
    self.serviceDeployed = YES;
    self.connectedModel  = self.activeMapping.lepuModel;
    FBD_LOG(@"URAT deploy complete model=%ld family=%@",
            (long)self.connectedModel, self.activeMapping.family);
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"connected",
                      @"model": @(self.connectedModel),
                      @"family": self.activeMapping.family,
                      @"deviceType": self.activeMapping.deviceType}];
}

- (void)utilDeployFailed:(VTMURATUtils *)util {
    [self cancelConnectionWatchdog];
    FBD_LOG(@"URAT deploy FAILED — services or characteristics not discoverable");
    if (self.activePeripheral) {
        [self.central cancelPeripheralConnection:self.activePeripheral];
    }
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"disconnected",
                      @"reason": @"service_discovery_failed"}];
}

- (void)util:(VTMURATUtils *)util updateDeviceRSSI:(NSNumber *)RSSI {
    [self sendEvent:@{@"event": @"rssi", @"rssi": RSSI ?: @0}];
}

#pragma mark - VTMURATUtilsDelegate  (response dispatcher)

- (void)util:(VTMURATUtils *)util
commandSendFailed:(u_char)errorCode {
    [self sendEvent:@{@"event": @"commandError", @"errorCode": @(errorCode)}];
}

- (void)util:(VTMURATUtils *)util
commandFailed:(u_char)cmdType
  deviceType:(VTMDeviceType)deviceType
  failedType:(VTMBLEPkgType)type {
    [self sendEvent:@{@"event": @"commandError",
                      @"cmdType": @(cmdType),
                      @"deviceType": @(deviceType),
                      @"failedType": @(type)}];
}

- (void)util:(VTMURATUtils *)util
commandCompletion:(u_char)cmdType
   deviceType:(VTMDeviceType)deviceType
     response:(NSData *)response {
    if (response == nil) return;
    [self dispatchURATResponse:response cmdType:cmdType deviceType:deviceType];
}

- (void)receiveHeartRateByStandardService:(Byte)hrByte {
    [self sendEvent:@{@"event": @"rtData",
                      @"deviceType": self.activeMapping.deviceType ?: @"unknown",
                      @"deviceFamily": self.activeMapping.family   ?: @"unknown",
                      @"model": @(self.connectedModel),
                      @"hr": @(hrByte)}];
}

#pragma mark - URAT response parsing

- (void)dispatchURATResponse:(NSData *)response
                     cmdType:(u_char)cmdType
                  deviceType:(VTMDeviceType)deviceType {
    // Common commands (battery, device info, file list) — cmdType uses
    // VTMBLECmd values.
    if (cmdType == VTMBLECmdGetDeviceInfo) {
        VTMDeviceInfo info = [VTMBLEParser parseDeviceInfo:response];
        [self sendEvent:@{@"event": @"deviceInfo",
                          @"model": @(self.connectedModel),
                          @"hw_version": @(info.hw_version),
                          @"fw_version": @(info.fw_version),
                          @"bl_version": @(info.bl_version),
                          @"device_type": @(info.device_type),
                          @"protocol_version": @(info.protocol_version),
                          @"raw": [response base64EncodedStringWithOptions:0]}];
        return;
    }
    if (cmdType == VTMBLECmdGetBattery) {
        VTMBatteryInfo bi = [VTMBLEParser parseBatteryInfo:response];
        [self sendEvent:@{@"event": @"battery",
                          @"state": @(bi.state),
                          @"percent": @(bi.percent),
                          @"voltage": @(bi.voltage)}];
        return;
    }
    // ── File-read state machine (BP2 / ER1 / ER2 / WOxi / FOxi / etc.) ──
    if (cmdType == VTMBLECmdStartRead) {
        // The device reports the file's total length; bootstrap the
        // chunked download at offset 0.
        if (self.pendingReadFileName == nil) return;
        VTMOpenFileReturn r = [VTMBLEParser parseFileLength:response];
        if (r.file_size == 0) {
            [self emitFileReadError:@"open returned size 0"];
            return;
        }
        self.pendingReadTotalSize = r.file_size;
        if (self.pendingReadBuffer == nil) {
            self.pendingReadBuffer = [NSMutableData dataWithCapacity:r.file_size];
        }
        [self.uratUtil readFile:0];
        return;
    }
    if (cmdType == VTMBLECmdReadFile) {
        // One chunk arrived; append, emit progress, ask for the next chunk
        // or call endReadFile if we're done.
        if (self.pendingReadFileName == nil) return;
        if (response.length > 0) {
            [self.pendingReadBuffer appendData:response];
        }
        double progress = self.pendingReadTotalSize == 0 ? 0.0
            : MIN(1.0, (double)self.pendingReadBuffer.length / (double)self.pendingReadTotalSize);
        [self sendEvent:@{@"event":        @"fileReadProgress",
                          @"deviceFamily": [self fileFamilyForActiveMapping],
                          @"model":        @(self.connectedModel),
                          @"fileName":     self.pendingReadFileName ?: @"",
                          @"progress":     @(progress)}];
        if (self.pendingReadBuffer.length >= self.pendingReadTotalSize) {
            [self.uratUtil endReadFile];
        } else {
            [self.uratUtil readFile:(uint32_t)self.pendingReadBuffer.length];
        }
        return;
    }
    if (cmdType == VTMBLECmdEndRead) {
        // The device acknowledged endReadFile; emit the final event.
        if (self.pendingReadFileName == nil) return;
        NSString *family   = [self fileFamilyForActiveMapping];
        NSString *fileName = self.pendingReadFileName;
        NSData   *content  = [self.pendingReadBuffer copy] ?: [NSData data];
        self.pendingReadFileName  = nil;
        self.pendingReadBuffer    = nil;
        self.pendingReadTotalSize = 0;
        [self sendEvent:@{@"event":        @"fileReadComplete",
                          @"deviceFamily": family,
                          @"model":        @(self.connectedModel),
                          @"fileName":     fileName,
                          @"size":         @(content.length),
                          @"content":      [content base64EncodedStringWithOptions:0]}];
        return;
    }
    if (cmdType == VTMBLECmdGetFileList) {
        VTMFileList list = [VTMBLEParser parseFileList:response];
        NSMutableArray *files = [NSMutableArray array];
        for (int i = 0; i < list.file_num; i++) {
            NSString *fn = [[NSString alloc] initWithBytes:list.fileName[i].str
                                                    length:sizeof(list.fileName[i].str)
                                                  encoding:NSUTF8StringEncoding];
            if (fn.length) [files addObject:[fn stringByTrimmingCharactersInSet:
                                             [NSCharacterSet controlCharacterSet]]];
        }
        [self sendEvent:@{@"event":        @"fileList",
                          @"model":        @(self.connectedModel),
                          @"deviceFamily": [self fileFamilyForActiveMapping],
                          @"files":        files}];
        [self applyFileListForCatchUp:files];
        return;
    }
    if (cmdType == VTMBLECmdSyncTime) {
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"connected",
                          @"model": @(self.connectedModel),
                          @"subEvent": @"setTime"}];
        return;
    }

    // Device-type specific parsing
    switch (deviceType) {
        case VTMDeviceTypeECG:
            [self parseECGResponse:response cmdType:cmdType]; break;
        case VTMDeviceTypeBP:
            [self parseBPResponse:response cmdType:cmdType];  break;
        case VTMDeviceTypeScale:
            [self parseScaleResponse:response cmdType:cmdType]; break;
        case VTMDeviceTypeWOxi:
            [self parseWOxiResponse:response cmdType:cmdType]; break;
        case VTMDeviceTypeFOxi:
            [self parseFOxiResponse:response cmdType:cmdType]; break;
        case VTMDeviceTypeER3:
        case VTMDeviceTypeMSeries:
            [self parseER3Response:response cmdType:cmdType];  break;
        case VTMDeviceTypeBabyPatch:
            [self parseBabyResponse:response cmdType:cmdType]; break;
        default:
            // Unknown — emit raw for debugging.
            [self sendEvent:@{@"event": @"raw",
                              @"cmdType": @(cmdType),
                              @"deviceType": @(deviceType),
                              @"data": [response base64EncodedStringWithOptions:0]}];
            break;
    }
}

- (void)parseECGResponse:(NSData *)response cmdType:(u_char)cmdType {
    if (cmdType == VTMECGCmdGetRealData) {
        VTMRealTimeData rt = [VTMBLEParser parseRealTimeData:response];
        VTMFlagDetail flag = [VTMBLEParser parseFlag:rt.run_para.sys_flag];
        VTMRunStatus  st   = [VTMBLEParser parseStatus:rt.run_para.run_status];
        NSMutableArray *mv = [NSMutableArray arrayWithCapacity:rt.waveform.sampling_num];
        NSMutableArray *raw = [NSMutableArray arrayWithCapacity:rt.waveform.sampling_num];
        for (int i = 0; i < rt.waveform.sampling_num && i < 300; i++) {
            short s = rt.waveform.wave_data[i];
            [raw addObject:@(s)];
            [mv  addObject:@([VTMBLEParser mVFromShort:s])];
        }
        NSString *family = self.activeMapping.family ?: @"er1";
        [self sendEvent:@{@"event": @"rtData",
                          @"deviceType": @"ecg",
                          @"deviceFamily": family,
                          @"model": @(self.connectedModel),
                          @"hr": @(rt.run_para.hr),
                          @"battery": @(rt.run_para.percent),
                          @"batteryState": @(flag.batteryStatus),
                          @"recordTime": @(rt.run_para.record_time),
                          @"curStatus": @(st.curStatus),
                          @"isLeadOff": @(flag.rMark == 0 && st.curStatus == 0),
                          @"ecgFloats": mv,
                          @"ecgShorts": raw,
                          @"samplingRate": @125,
                          @"mvConversion": @0.002467}];
        // Detect the idle/measuring → "saving succeed" transition
        // (curStatus == 4) on ER1/ER2 and kick off the auto-pull so the
        // full file — including pre-connection samples — is downloaded.
        NSInteger cur = (NSInteger)st.curStatus;
        BOOL isEr1 = [family isEqualToString:@"er1"];
        BOOL isEr2 = [family isEqualToString:@"er2"];
        NSInteger last = isEr1 ? self.lastEr1CurStatus
                                : (isEr2 ? self.lastEr2CurStatus : -1);
        if (cur == 4 && last != 4 && (isEr1 || isEr2)) {
            [self emitRecordingFinishedForFamily:family];
            if (self.autoFetchOnFinish) {
                [self triggerGetFileListForCatchUp];
            }
        }
        if (isEr1) self.lastEr1CurStatus = cur;
        if (isEr2) self.lastEr2CurStatus = cur;
        return;
    }
    if (cmdType == VTMECGCmdGetRealWave) {
        VTMRealTimeWF wf = [VTMBLEParser parseRealTimeWaveform:response];
        NSMutableArray *mv = [NSMutableArray arrayWithCapacity:wf.sampling_num];
        for (int i = 0; i < wf.sampling_num && i < 300; i++) {
            [mv addObject:@([VTMBLEParser mVFromShort:wf.wave_data[i]])];
        }
        [self sendEvent:@{@"event": @"rtWaveform",
                          @"deviceType": @"ecg",
                          @"deviceFamily": self.activeMapping.family ?: @"er1",
                          @"model": @(self.connectedModel),
                          @"waveType": @"ecg",
                          @"ecgFloats": mv,
                          @"samplingRate": @125,
                          @"mvConversion": @0.002467}];
        return;
    }
    [self emitRaw:response cmd:cmdType dev:VTMDeviceTypeECG];
}

- (void)parseBPResponse:(NSData *)response cmdType:(u_char)cmdType {
    NSString *family = self.activeMapping.family ?: @"bp2";

    // Real-time data packet: contains run-status AND the measurement payload
    // determined by the `type` byte (0=BP measuring, 1=BP result,
    // 2=ECG measuring, 3=ECG result, 4=idle).
    if (cmdType == VTMBPCmdGetRealData) {
        VTMBPRealTimeData rt = [VTMBLEParser parseBPRealTimeData:response];
        NSMutableDictionary *d = [@{
            @"event":          @"rtData",
            @"deviceType":     @"bp",
            @"deviceFamily":   family,
            @"model":          @(self.connectedModel),
            @"deviceStatus":   @(rt.run_status.status),
            @"batteryState":   @(rt.run_status.battery.state),
            @"batteryPercent": @(rt.run_status.battery.percent),
            @"paramDataType":  @(rt.rt_wav.type),
        } mutableCopy];

        NSData *dataSlice = [NSData dataWithBytes:rt.rt_wav.data length:sizeof(rt.rt_wav.data)];
        switch (rt.rt_wav.type) {
            case 0: {
                VTMBPMeasuringData mm = [VTMBLEParser parseBPMeasuringData:dataSlice];
                d[@"measureType"] = @"bp_measuring";
                d[@"pressure"]    = @(mm.pressure);
                d[@"pr"]          = @(mm.pulse_rate);
                d[@"isDeflate"]   = @(mm.is_deflating != 0);
                d[@"isPulse"]     = @(mm.is_get_pulse != 0);
                break;
            }
            case 1: {
                VTMBPEndMeasureData mr = [VTMBLEParser parseBPEndMeasureData:dataSlice];
                d[@"measureType"] = @"bp_result";
                d[@"sys"]         = @(mr.systolic_pressure);
                d[@"dia"]         = @(mr.diastolic_pressure);
                d[@"mean"]        = @(mr.mean_pressure);
                d[@"pr"]          = @(mr.pulse_rate);
                d[@"result"]      = @(mr.medical_result);
                d[@"stateCode"]   = @(mr.state_code);
                break;
            }
            case 2: {
                VTMECGMeasuringData em = [VTMBLEParser parseECGMeasuringData:dataSlice];
                d[@"measureType"]  = @"ecg_measuring";
                d[@"hr"]           = @(em.pulse_rate);
                d[@"curDuration"]  = @(em.duration);
                d[@"isLeadOff"]    = @((em.special_status & 0x02) != 0);
                d[@"isPoolSignal"] = @((em.special_status & 0x01) != 0);
                NSMutableArray *mv = [NSMutableArray arrayWithCapacity:rt.rt_wav.wav.sampling_num];
                NSMutableArray *sh = [NSMutableArray arrayWithCapacity:rt.rt_wav.wav.sampling_num];
                for (int i = 0; i < rt.rt_wav.wav.sampling_num && i < 300; i++) {
                    short s = rt.rt_wav.wav.wave_data[i];
                    [sh addObject:@(s)];
                    [mv addObject:@([VTMBLEParser bpMvFromShort:s])];
                }
                d[@"ecgFloats"]    = mv;
                d[@"ecgShorts"]    = sh;
                d[@"samplingRate"] = @250;
                d[@"mvConversion"] = @0.003098;
                break;
            }
            case 3: {
                VTMECGEndMeasureData er = [VTMBLEParser parseECGEndMeasureData:dataSlice];
                d[@"measureType"] = @"ecg_result";
                d[@"hr"]          = @(er.hr);
                d[@"qrs"]         = @(er.qrs);
                d[@"pvcs"]        = @(er.pvcs);
                d[@"qtc"]         = @(er.qtc);
                d[@"result"]      = @(er.result);
                break;
            }
            default:
                d[@"measureType"] = @"idle";
                break;
        }
        [self sendEvent:d];
        // BP2 recording-finished edge trigger: paramDataType transitions
        // *to* 1 (bp_result) or 3 (ecg_result) mean a new file has just
        // been written to flash. We only fire on the edge so a streak of
        // result frames doesn't re-pull the same file.
        NSInteger ptype = (NSInteger)rt.rt_wav.type;
        BOOL isResult = (ptype == 1) || (ptype == 3);
        if (isResult && self.lastBp2ParamDataType != ptype) {
            [self emitRecordingFinishedForFamily:family];
            if (self.autoFetchOnFinish) {
                [self triggerGetFileListForCatchUp];
            }
        }
        self.lastBp2ParamDataType = ptype;
        return;
    }

    if (cmdType == VTMBPCmdGetRealStatus) {
        VTMBPRunStatus st = [VTMBLEParser parseBPRealTimeStatus:response];
        [self sendEvent:@{@"event":          @"rtData",
                          @"deviceType":     @"bp",
                          @"deviceFamily":   family,
                          @"model":          @(self.connectedModel),
                          @"measureType":    @"bp_status",
                          @"deviceStatus":   @(st.status),
                          @"batteryState":   @(st.battery.state),
                          @"batteryPercent": @(st.battery.percent)}];
        return;
    }

    if (cmdType == VTMBPCmdGetRealPressure) {
        VTMRealTimePressure p = [VTMBLEParser parseBPRealTimePressure:response];
        [self sendEvent:@{@"event":        @"rtData",
                          @"deviceType":   @"bp",
                          @"deviceFamily": family,
                          @"model":        @(self.connectedModel),
                          @"measureType":  @"bp_pressure",
                          @"pressure":     @(p.pressure)}];
        return;
    }

    if (cmdType == VTMBPCmdGetConfig) {
        VTMBPConfig cfg = [VTMBLEParser parseBPConfig:response];
        [self sendEvent:@{@"event":      @"deviceConfig",
                          @"family":     family,
                          @"model":      @(self.connectedModel),
                          @"calibZero":  @(cfg.last_calib_zero),
                          @"calibSlope": @(cfg.calib_slope),
                          @"volume":     @(cfg.volume),
                          @"unit":       @(cfg.unit),
                          @"timeUtc":    @(cfg.time_utc)}];
        return;
    }

    [self emitRaw:response cmd:cmdType dev:VTMDeviceTypeBP];
}

- (void)parseScaleResponse:(NSData *)response cmdType:(u_char)cmdType {
    NSString *family = self.activeMapping.family ?: @"scale";
    if (cmdType == VTMSCALECmdGetRealData) {
        VTMScaleRealData rt = [VTMBLEParser parseScaleRealData:response];
        // Viatom S1 stores weight as big-endian u_short with 2-decimal
        // precision (e.g. 7523 → 75.23 kg).  Resistance is big-endian u_int.
        uint16_t weightBE = rt.scale_data.weight;
        uint32_t impBE    = rt.scale_data.resistance;
        double weightKg = CFSwapInt16BigToHost(weightBE) / 100.0;
        uint32_t imp    = CFSwapInt32BigToHost(impBE);
        [self sendEvent:@{@"event":          @"rtData",
                          @"deviceType":     @"scale",
                          @"deviceFamily":   family,
                          @"model":          @(self.connectedModel),
                          @"weightKg":       @(weightKg),
                          @"impedance":      @(imp),
                          @"heartRate":      @(rt.run_para.hr),
                          @"runStatus":      @(rt.run_para.run_status),
                          @"leadStatus":     @(rt.run_para.lead_status)}];
        return;
    }
    if (cmdType == VTMSCALECmdGetRealWave) {
        VTMRealTimeWF wf = [VTMBLEParser parseScaleRealTimeWaveform:response];
        NSMutableArray *pts = [NSMutableArray arrayWithCapacity:wf.sampling_num];
        for (int i = 0; i < wf.sampling_num && i < 300; i++) {
            [pts addObject:@(wf.wave_data[i])];
        }
        [self sendEvent:@{@"event":        @"rtWaveform",
                          @"deviceType":   @"scale",
                          @"deviceFamily": family,
                          @"model":        @(self.connectedModel),
                          @"waveType":     @"ecg",
                          @"waveData":     pts}];
        return;
    }
    if (cmdType == VTMSCALECmdGetRunParams) {
        VTMScaleRunParams rp = [VTMBLEParser parseScaleRunParams:response];
        [self sendEvent:@{@"event":        @"rtData",
                          @"deviceType":   @"scale",
                          @"deviceFamily": family,
                          @"model":        @(self.connectedModel),
                          @"subType":      @"runParams",
                          @"hr":           @(rp.hr),
                          @"recordTime":   @(rp.record_time),
                          @"runStatus":    @(rp.run_status),
                          @"leadStatus":   @(rp.lead_status)}];
        return;
    }
    [self emitRaw:response cmd:cmdType dev:VTMDeviceTypeScale];
}

- (void)parseWOxiResponse:(NSData *)response cmdType:(u_char)cmdType {
    NSString *family = self.activeMapping.family ?: @"woxi";
    if (cmdType == VTMWOxiCmdGetRealData || cmdType == VTMWOxiCmdPushRunParams) {
        VTMWOxiRealData rd = [VTMBLEParser woxi_parseRealData:response];
        NSMutableArray *wave = [NSMutableArray arrayWithCapacity:rd.waveform.sampling_num];
        for (int i = 0; i < rd.waveform.sampling_num; i++) {
            [wave addObject:@(rd.waveform.waveform_data[i])];
        }
        [self sendEvent:@{@"event":          @"rtData",
                          @"deviceType":     @"oximeter",
                          @"deviceFamily":   family,
                          @"model":          @(self.connectedModel),
                          @"spo2":           @(rd.run_para.spo2),
                          @"pr":             @(rd.run_para.pr),
                          @"pi":             @(rd.run_para.pi / 10.0),
                          @"battery":        @(rd.run_para.battery_percent),
                          @"batteryState":   @(rd.run_para.battery_state),
                          @"state":          @(rd.run_para.run_status),
                          @"sensorState":    @(rd.run_para.sensor_state),
                          @"motion":         @(rd.run_para.motion),
                          @"recordTime":     @(rd.run_para.record_time),
                          @"waveData":       wave}];
        return;
    }
    if (cmdType == VTMWOxiCmdPushRealWave) {
        // Waveform-only push packet — extract the byte payload directly.
        NSMutableArray *pts = [NSMutableArray arrayWithCapacity:response.length];
        const uint8_t *b = response.bytes;
        for (NSUInteger i = 0; i < response.length; i++) [pts addObject:@(b[i])];
        [self sendEvent:@{@"event":        @"rtWaveform",
                          @"deviceType":   @"oximeter",
                          @"deviceFamily": family,
                          @"model":        @(self.connectedModel),
                          @"waveType":     @"ppg",
                          @"waveData":     pts}];
        return;
    }
    if (cmdType == VTMWOxiCmdGetConfig) {
        VTMWOxiInfo cfg = [VTMBLEParser woxi_parseConfig:response];
        [self sendEvent:@{@"event":       @"deviceConfig",
                          @"family":      family,
                          @"model":       @(self.connectedModel),
                          @"spo2Thr":     @(cfg.spo2_thr),
                          @"hrThrLow":    @(cfg.hr_thr_low),
                          @"hrThrHigh":   @(cfg.hr_thr_high),
                          @"motor":       @(cfg.motor),
                          @"buzzer":      @(cfg.buzzer),
                          @"interval":    @(cfg.interval),
                          @"brightness":  @(cfg.brightness),
                          @"displayMode": @(cfg.display_mode)}];
        return;
    }
    [self emitRaw:response cmd:cmdType dev:VTMDeviceTypeWOxi];
}

- (void)parseFOxiResponse:(NSData *)response cmdType:(u_char)cmdType {
    NSString *family = self.activeMapping.family ?: @"foxi";
    if (cmdType == VTMFOxiCmdInfoResp) {
        VTMFOxiMeasureInfo info = [VTMBLEParser foxi_parseMeasureInfo:response];
        [self sendEvent:@{@"event":          @"rtData",
                          @"deviceType":     @"oximeter",
                          @"deviceFamily":   family,
                          @"model":          @(self.connectedModel),
                          @"spo2":           @(info.spo2),
                          @"pr":             @(info.pr),
                          @"pi":             @(info.pi / 10.0),
                          @"status":         @(info.status),
                          @"batLevel":       @((info.res >> 6) & 0x03),
                          @"probeOff":       @((info.status & 0x02) != 0)}];
        return;
    }
    if (cmdType == VTMFOxiCmdWaveResp) {
        __block NSMutableArray *points = [NSMutableArray array];
        __block NSMutableArray *beats  = [NSMutableArray array];
        [VTMBLEParser foxi_parseMeasureWave:response completion:^(int num, VTMFOxiMeasureWave *wave) {
            if (wave == NULL || num <= 0) return;
            for (int i = 0; i < num; i++) {
                for (int j = 0; j < 5; j++) {
                    uint8_t v = wave[i].wavedata[j];
                    [points addObject:@(v & 0x7F)];       // Bit0-6: waveform sample
                    [beats  addObject:@(((v >> 7) & 1))]; // Bit7: pulse beat flag
                }
            }
        }];
        [self sendEvent:@{@"event":        @"rtWaveform",
                          @"deviceType":   @"oximeter",
                          @"deviceFamily": family,
                          @"model":        @(self.connectedModel),
                          @"waveType":     @"ppg",
                          @"waveData":     points,
                          @"beats":        beats}];
        return;
    }
    if (cmdType == VTMFOxiCmdGetConfig) {
        VTMFOxiConfig cfg = [VTMBLEParser foxi_parseConfig:response];
        [self sendEvent:@{@"event":       @"deviceConfig",
                          @"family":      family,
                          @"model":       @(self.connectedModel),
                          @"spo2Low":     @(cfg.spo2Low),
                          @"prHigh":      @(cfg.prHigh),
                          @"prLow":       @(cfg.prLow),
                          @"alarm":       @(cfg.alramIsOn),
                          @"beep":        @(cfg.beepIsOn),
                          @"measureMode": @(cfg.measureMode),
                          @"language":    @(cfg.language)}];
        return;
    }
    [self emitRaw:response cmd:cmdType dev:VTMDeviceTypeFOxi];
}

- (void)parseER3Response:(NSData *)response cmdType:(u_char)cmdType {
    NSString *family = self.activeMapping.family ?: @"er3";

    if (cmdType == VTMER3ECGCmdGetRealData) {
        VTMER3RealTimeData rt = [VTMBLEParser parseER3RealTimeData:response];
        // Decompressed waveform (12 leads × samples).  Pass-through as
        // base64 — decoding 12-lead ECG bytes into float[] per lead is
        // non-trivial and not useful for the phone display.
        NSData *waveSlice = nil;
        if (response.length > sizeof(rt.run_params)) {
            waveSlice = [response subdataWithRange:NSMakeRange(sizeof(rt.run_params),
                                                               response.length - sizeof(rt.run_params))];
        }
        [self sendEvent:@{@"event":          @"rtData",
                          @"deviceType":     @"ecg",
                          @"deviceFamily":   family,
                          @"model":          @(self.connectedModel),
                          @"hr":             @(rt.run_params.ecg_hr),
                          @"respRate":       @(rt.run_params.ecg_resp_rate),
                          @"spo2":           @(rt.run_params.oxi_spo2),
                          @"pr":             @(rt.run_params.oxi_pr),
                          @"pi":             @(rt.run_params.oxi_pi / 10.0),
                          @"temperature":    @(rt.run_params.temp_val / 100.0),
                          @"battery":        @(rt.run_params.battery_percent),
                          @"batteryState":   @(rt.run_params.battery_state),
                          @"recordTime":     @(rt.run_params.record_time),
                          @"runStatus":      @(rt.run_params.run_status),
                          @"leadMode":       @(rt.run_params.cable_type),
                          @"leadState":      @(rt.run_params.electrodes_state),
                          @"samplingNum":    @(rt.waveform.sampling_num),
                          @"waveInfo":       @(rt.waveform.wave_info),
                          @"waveOffset":     @(rt.waveform.offset),
                          @"compressedWave": waveSlice
                              ? [waveSlice base64EncodedStringWithOptions:0]
                              : @""}];
        return;
    }
    if (cmdType == VTMMSeriesCmdGetRealData) {
        VTMMSeriesRunParams rp = [VTMBLEParser parseMSeriesRunParams:response];
        VTMMSeriesFlag flag = [VTMBLEParser parseMSeiriesSysFlag:rp];
        [self sendEvent:@{@"event":          @"rtData",
                          @"deviceType":     @"ecg",
                          @"deviceFamily":   family,
                          @"model":          @(self.connectedModel),
                          @"hr":             @(rp.hr),
                          @"battery":        @(rp.percent),
                          @"recordTime":     @(rp.record_time),
                          @"leadMode":       @(rp.lead_mode),
                          @"leadState":      @(rp.lead_state),
                          @"batteryState":   @(flag.batteryState),
                          @"ecgLeadState":   @(flag.ecgLeadState),
                          @"oxyState":       @(flag.oxyState),
                          @"tempState":      @(flag.tempState),
                          @"measureState":   @(flag.measureState),
                          @"firstIndex":     @(rp.first_index),
                          @"samplingNum":    @(rp.sampling_num)}];
        return;
    }
    [self emitRaw:response cmd:cmdType dev:VTMDeviceTypeER3];
}

- (void)parseBabyResponse:(NSData *)response cmdType:(u_char)cmdType {
    if (cmdType == VTMBabyCmdGetRunParams) {
        VTMBabyRunParams rp = [VTMBLEParser baby_parseRunParams:response];
        [self sendEvent:@{@"event":          @"rtData",
                          @"deviceType":     @"baby",
                          @"deviceFamily":   @"baby",
                          @"model":          @(self.connectedModel),
                          @"runStatus":      @(rp.run_status),
                          @"attitude":       @(rp.attitude_status),
                          @"wearStatus":     @(rp.wear_status),
                          @"rr":             @(rp.rr),
                          @"alarmTypeRR":    @(rp.alarm_type_rr),
                          @"temperature":    @(rp.cur_temperature / 10.0),
                          @"alarmTypeTemp":  @(rp.alarm_type_temp),
                          @"battery":        @(rp.batInfo.percent),
                          @"batteryState":   @(rp.batInfo.state),
                          @"startupTime":    @(rp.startup_time),
                          @"gestureAlarm":   @(rp.gesture_alarm)}];
        return;
    }
    if (cmdType == VTMBabyCmdGetGesture) {
        VTMBabyAtt att = [VTMBLEParser baby_parseAttitude:response];
        [self sendEvent:@{@"event":        @"rtData",
                          @"deviceType":   @"baby",
                          @"deviceFamily": @"baby",
                          @"model":        @(self.connectedModel),
                          @"subType":      @"gesture",
                          @"pitch":        @(att.alg_result.Pitch),
                          @"roll":         @(att.alg_result.Roll),
                          @"yaw":          @(att.alg_result.Yaw),
                          @"gesture":      @(att.alg_result.gesture),
                          @"rr":           @(att.alg_result.RR),
                          @"accX":         @(att.acc_x),
                          @"accY":         @(att.acc_y),
                          @"accZ":         @(att.acc_z)}];
        return;
    }
    [self emitRaw:response cmd:cmdType dev:VTMDeviceTypeBabyPatch];
}

- (void)emitRaw:(NSData *)response cmd:(u_char)cmd dev:(VTMDeviceType)dev {
    [self sendEvent:@{@"event": @"raw",
                      @"cmdType": @(cmd),
                      @"deviceType": @(dev),
                      @"data": [response base64EncodedStringWithOptions:0]}];
}

#pragma mark - VTO2CommunicateDelegate  (legacy 0xAA O2Ring path)

- (void)o2_serviceDeployed:(BOOL)completed {
    [self cancelConnectionWatchdog];
    if (completed) {
        self.serviceDeployed = YES;
        self.connectedModel  = self.activeMapping.lepuModel;
        FBD_LOG(@"O2 deploy complete model=%ld family=%@",
                (long)self.connectedModel, self.activeMapping.family);
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"connected",
                          @"model": @(self.connectedModel),
                          @"family": self.activeMapping.family ?: @"oxy",
                          @"deviceType": @"oximeter"}];
    } else {
        FBD_LOG(@"O2 deploy FAILED — services or characteristics not discoverable");
        if (self.activePeripheral) {
            [self.central cancelPeripheralConnection:self.activePeripheral];
        }
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"disconnected",
                          @"reason": @"service_discovery_failed"}];
    }
}

- (void)writeDataErrorCode:(int)errorCode {
    [self sendEvent:@{@"event": @"commandError", @"errorCode": @(errorCode)}];
}

- (void)commonResponse:(VTCmd)cmdType andResult:(VTCommonResult)result {
    [self sendEvent:@{@"event": @"commandAck",
                      @"cmdType": @(cmdType),
                      @"result": @(result)}];
}

- (void)getInfoWithResultData:(NSData *)infoData {
    if (infoData == nil) return;
    VTO2Info *info = [VTO2Parser parseO2InfoWithData:infoData];
    NSMutableDictionary *payload = [@{@"event": @"deviceInfo",
                                      @"model": @(self.connectedModel),
                                      @"deviceType": @"oximeter",
                                      @"family": self.activeMapping.family ?: @"oxy"} mutableCopy];
    if (info.hardware)   payload[@"hwVersion"] = info.hardware;
    if (info.software)   payload[@"fwVersion"] = info.software;
    if (info.sn)         payload[@"sn"]        = info.sn;
    if (info.branchCode) payload[@"branchCode"] = info.branchCode;
    if (info.curBattery) payload[@"battery"]   = info.curBattery;
    [self sendEvent:payload];
}

- (void)realDataCallBackWithData:(NSData *)realData {
    if (realData == nil) return;
    VTRealObject *obj = [VTO2Parser parseO2RealObjectWithData:realData];
    [self sendEvent:@{@"event": @"rtData",
                      @"deviceType": @"oximeter",
                      @"deviceFamily": self.activeMapping.family ?: @"oxy",
                      @"model": @(self.connectedModel),
                      @"spo2": @(obj.spo2),
                      @"pr": @(obj.hr),
                      @"pi": @(obj.pi),
                      @"battery": @(obj.battery),
                      @"batteryState": @(obj.batState),
                      @"state": @(obj.leadState),
                      @"vector": @(obj.vector)}];
}

- (void)realWaveCallBackWithData:(NSData *)realWave {
    if (realWave == nil) return;
    VTRealWave *wave = [VTO2Parser parseO2RealWaveWithData:realWave];
    NSMutableArray *ints = [NSMutableArray arrayWithCapacity:wave.points.count];
    for (NSNumber *n in wave.points) [ints addObject:n];
    [self sendEvent:@{@"event": @"rtWaveform",
                      @"deviceType": @"oximeter",
                      @"deviceFamily": self.activeMapping.family ?: @"oxy",
                      @"model": @(self.connectedModel),
                      @"spo2": @(wave.spo2),
                      @"pr": @(wave.hr),
                      @"pi": @(wave.pi),
                      @"waveData": ints}];
}

- (void)realPPGCallBackWithData:(NSData *)realPPG {
    if (realPPG == nil) return;
    NSArray<VTRealPPG *> *ppgs = [VTO2Parser parseO2RealPPGWithData:realPPG];
    NSMutableArray *ir = [NSMutableArray arrayWithCapacity:ppgs.count];
    NSMutableArray *red = [NSMutableArray arrayWithCapacity:ppgs.count];
    for (VTRealPPG *p in ppgs) {
        [ir addObject:@(p.ir)];
        [red addObject:@(p.red)];
    }
    [self sendEvent:@{@"event": @"rtWaveform",
                      @"deviceType": @"oximeter",
                      @"deviceFamily": self.activeMapping.family ?: @"oxy",
                      @"model": @(self.connectedModel),
                      @"waveType": @"ppg",
                      @"ir":  ir,
                      @"red": red}];
}

- (void)updatePeripheralRSSI:(NSNumber *)RSSI {
    [self sendEvent:@{@"event": @"rssi", @"rssi": RSSI ?: @0}];
}

// ── File-transfer helpers + legacy-O2 delegate callbacks ─────────────

/// Emit a `fileReadError` event using the current pending-read context
/// (or empty fields if no read is in flight) and reset state.
- (void)emitFileReadError:(NSString *)reason {
    NSString *family   = [self fileFamilyForActiveMapping];
    NSString *fileName = self.pendingReadFileName ?: @"";
    self.pendingReadFileName  = nil;
    self.pendingReadBuffer    = nil;
    self.pendingReadTotalSize = 0;
    [self sendEvent:@{@"event":        @"fileReadError",
                      @"deviceFamily": family,
                      @"model":        @(self.connectedModel),
                      @"fileName":     fileName,
                      @"error":        reason ?: @"unknown"}];
}

/// Legacy-O2 path (`VTO2Communicate`): `beginReadFileWithFileName:` drives
/// a fully-managed download internally and reports progress + completion
/// via these two delegate methods. We forward both into the unified
/// `fileReadProgress` / `fileReadComplete` wire-format.
- (void)postCurrentReadProgress:(double)progress {
    if (self.pendingReadFileName == nil) return;
    [self sendEvent:@{@"event":        @"fileReadProgress",
                      @"deviceFamily": @"oxy",
                      @"model":        @(self.connectedModel),
                      @"fileName":     self.pendingReadFileName,
                      @"progress":     @(MIN(1.0, MAX(0.0, progress)))}];
}

- (void)readCompleteWithData:(VTFileToRead *)fileData {
    NSString *fileName = self.pendingReadFileName ?: fileData.fileName ?: @"";
    self.pendingReadFileName  = nil;
    self.pendingReadBuffer    = nil;
    self.pendingReadTotalSize = 0;

    NSData *content = fileData.fileData ?: [NSData data];
    if (fileData.enLoadResult != 0) {
        // Non-zero VTFileLoadResult means the SDK reports a failure. Surface
        // as a fileReadError so consumers don't process garbage.
        [self sendEvent:@{@"event":        @"fileReadError",
                          @"deviceFamily": @"oxy",
                          @"model":        @(self.connectedModel),
                          @"fileName":     fileName,
                          @"error":        [NSString stringWithFormat:@"VTFileLoadResult=%d",
                                            (int)fileData.enLoadResult]}];
        return;
    }
    [self sendEvent:@{@"event":        @"fileReadComplete",
                      @"deviceFamily": @"oxy",
                      @"model":        @(self.connectedModel),
                      @"fileName":     fileName,
                      @"size":         @(content.length),
                      @"content":      [content base64EncodedStringWithOptions:0]}];
}

#pragma mark - ICDeviceManagerDelegate  (iComon scale path)

#if FBD_HAS_ICOMON
- (void)onInitFinish:(BOOL)bSuccess {
    self.iComonInitialized = bSuccess;
    FBD_LOG(@"iComon onInitFinish=%@", bSuccess ? @"YES" : @"NO");
    [self sendEvent:@{@"event": @"icomonReady", @"ok": @(bSuccess)}];
    if (bSuccess && self.iComonPendingScan) {
        FBD_LOG(@"iComon replaying deferred scan");
        [self.iComonScans removeAllObjects];
        [[ICDeviceManager shared] scanDevice:self];
        self.iComonPendingScan = NO;
    }
}

- (void)onBleState:(ICBleState)state {
    // Surface as a simple informational event — iComon's BLE state is tracked
    // separately from our CBCentralManager instance.
    [self sendEvent:@{@"event": @"icomonBleState", @"state": @(state)}];
}

- (void)onDeviceConnectionChanged:(ICDevice *)device state:(ICDeviceConnectState)state {
    if (device == nil) return;
    [self cancelConnectionWatchdog];
    if (state == ICDeviceConnectStateConnected) {
        self.serviceDeployed = YES;
        FBD_LOG(@"iComon connected mac=%@", device.macAddr);
        [self sendEvent:@{@"event": @"connectionState",
                          @"state":  @"connected",
                          @"mac":    device.macAddr ?: @"",
                          @"sdk":    @"icomon",
                          @"family": @"icomon",
                          @"deviceType": @"scale"}];
    } else {
        self.serviceDeployed = NO;
        FBD_LOG(@"iComon disconnected mac=%@", device.macAddr);
        if ([device.macAddr isEqualToString:self.activeIComonDevice.macAddr]) {
            self.activeIComonDevice = nil;
            if (self.activeMapping.protocolPath == VTMProtocolPathIComon) {
                self.activeMapping = nil;
            }
        }
        [self sendEvent:@{@"event": @"connectionState",
                          @"state":  @"disconnected",
                          @"mac":    device.macAddr ?: @"",
                          @"sdk":    @"icomon",
                          @"reason": @"device_disconnected"}];
    }
}

- (void)onReceiveWeightData:(ICDevice *)device data:(ICWeightData *)data {
    [self emitIComonWeight:data device:device];
}

// ── iComon offline-history replay callbacks ─────────────────────────
//
// These fire both automatically (when the phone reconnects to a scale
// that has cached measurements) and on demand in response to
// `-handleReadHistoryData:`. The wire format mirrors the Android side
// so Dart consumers receive identical `historyData` events regardless
// of platform.

- (void)onReceiveWeightHistoryData:(ICDevice *)device
                              data:(ICWeightHistoryData *)data {
    if (device == nil || data == nil) return;
    [self sendEvent:@{@"event":         @"historyData",
                      @"kind":          @"weight",
                      @"deviceFamily":  @"icomon",
                      @"deviceType":    @"scale",
                      @"sdk":           @"icomon",
                      @"mac":           device.macAddr ?: @"",
                      @"userId":        @(data.userId),
                      @"time":          @(data.time),
                      @"weight_kg":     @(data.weight_kg),
                      @"weight_g":      @(data.weight_g),
                      @"weight_lb":     @(data.weight_lb),
                      @"weight_st":     @(data.weight_st),
                      @"weight_st_lb":  @(data.weight_st_lb),
                      @"precision_kg":  @(data.precision_kg),
                      @"precision_lb":  @(data.precision_lb),
                      @"impedance":     @(data.imp)}];
}

- (void)onReceiveKitchenScaleHistoryData:(ICDevice *)device
                                   datas:(NSArray<ICKitchenScaleData *> *)datas {
    if (device == nil || datas.count == 0) return;
    for (ICKitchenScaleData *entry in datas) {
        [self sendEvent:@{@"event":        @"historyData",
                          @"kind":         @"kitchenScale",
                          @"deviceFamily": @"icomon",
                          @"deviceType":   @"scale",
                          @"sdk":          @"icomon",
                          @"mac":          device.macAddr ?: @"",
                          @"time":         @(entry.time),
                          @"weight_g":     @(entry.value_g),
                          @"isStabilized": @(entry.isStabilized)}];
    }
}

- (void)onReceiveRulerHistoryData:(ICDevice *)device
                             data:(ICRulerData *)data {
    if (device == nil || data == nil) return;
    [self sendEvent:@{@"event":        @"historyData",
                      @"kind":         @"ruler",
                      @"deviceFamily": @"icomon",
                      @"deviceType":   @"ruler",
                      @"sdk":          @"icomon",
                      @"mac":          device.macAddr ?: @"",
                      @"time":         @(data.time),
                      @"distance_cm":  @(data.distance_cm),
                      @"distance_in":  @(data.distance_in),
                      @"distance_ft":  @(data.distance_ft),
                      @"isStabilized": @(data.isStabilized)}];
}

- (void)onReceiveHistorySkipData:(ICDevice *)device
                            data:(ICSkipData *)data {
    if (device == nil || data == nil) return;
    [self sendEvent:@{@"event":        @"historyData",
                      @"kind":         @"skip",
                      @"deviceFamily": @"icomon",
                      @"deviceType":   @"skip",
                      @"sdk":          @"icomon",
                      @"mac":          device.macAddr ?: @"",
                      @"time":         @(data.time),
                      @"skipCount":    @(data.skip_count),
                      @"elapsedTime":  @(data.elapsed_time),
                      @"actualTime":   @(data.actual_time),
                      @"avgFreq":      @(data.avg_freq),
                      @"calories":     @(data.calories_burned),
                      @"battery":      @(data.battery)}];
}

- (void)onReceiveMeasureStepData:(ICDevice *)device step:(ICMeasureStep)step data:(NSObject *)data {
    if (device == nil || data == nil) return;
    switch (step) {
        case ICMeasureStepMeasureWeightData: {
            if ([data isKindOfClass:[ICWeightData class]]) {
                [self emitIComonWeight:(ICWeightData *)data device:device];
            }
            break;
        }
        case ICMeasureStepMeasureCenterData: {
            if ([data isKindOfClass:[ICWeightCenterData class]]) {
                ICWeightCenterData *c = (ICWeightCenterData *)data;
                [self sendEvent:@{@"event": @"rtData",
                                  @"deviceType": @"scale",
                                  @"deviceFamily": @"icomon",
                                  @"mac": device.macAddr ?: @"",
                                  @"sdk": @"icomon",
                                  @"isStabilized": @(c.isStabilized),
                                  @"leftPercent":  @(c.leftPercent),
                                  @"rightPercent": @(c.rightPercent)}];
            }
            break;
        }
        case ICMeasureStepHrResult: {
            if ([data isKindOfClass:[ICWeightData class]]) {
                ICWeightData *w = (ICWeightData *)data;
                [self sendEvent:@{@"event": @"rtData",
                                  @"deviceType": @"scale",
                                  @"deviceFamily": @"icomon",
                                  @"mac": device.macAddr ?: @"",
                                  @"sdk": @"icomon",
                                  @"hr":  @(w.hr),
                                  @"step": @"ICMeasureStepHrResult"}];
            }
            break;
        }
        case ICMeasureStepMeasureOver: {
            if ([data isKindOfClass:[ICWeightData class]]) {
                ICWeightData *w = (ICWeightData *)data;
                w.isStabilized = YES;
                [self emitIComonWeight:w device:device];
            }
            break;
        }
        default:
            break;
    }
}

- (void)onReceiveHR:(ICDevice *)device hr:(int)hr {
    [self sendEvent:@{@"event": @"rtData",
                      @"deviceType": @"scale",
                      @"deviceFamily": @"icomon",
                      @"mac": device.macAddr ?: @"",
                      @"sdk": @"icomon",
                      @"hr":  @(hr)}];
}

- (void)onReceiveBattery:(ICDevice *)device battery:(NSUInteger)battery ext:(NSObject *)ext {
    [self sendEvent:@{@"event": @"battery",
                      @"mac": device.macAddr ?: @"",
                      @"sdk": @"icomon",
                      @"percent": @(battery)}];
}

- (void)onReceiveRSSI:(ICDevice *)device rssi:(int)rssi {
    [self sendEvent:@{@"event": @"rssi",
                      @"mac":  device.macAddr ?: @"",
                      @"sdk":  @"icomon",
                      @"rssi": @(rssi)}];
}

#pragma mark - ICScanDeviceDelegate

- (void)onScanResult:(ICScanDeviceInfo *)deviceInfo {
    if (deviceInfo == nil || deviceInfo.macAddr.length == 0) return;
    self.iComonScans[deviceInfo.macAddr] = deviceInfo;
    [self sendEvent:@{@"event":      @"deviceFound",
                      @"name":       deviceInfo.name ?: @"",
                      @"mac":        deviceInfo.macAddr,
                      @"model":      @(-1),
                      @"rssi":       @(deviceInfo.rssi),
                      @"sdk":        @"icomon",
                      @"deviceType": @"scale",
                      @"family":     @"icomon",
                      @"icDeviceType": @(deviceInfo.type),
                      @"icSubType":    @(deviceInfo.subType)}];
}

#pragma mark - iComon helpers

- (void)emitIComonWeight:(ICWeightData *)data device:(ICDevice *)device {
    if (data == nil || device == nil) return;
    double w = data.weight_kg;
    double (^r1)(double) = ^double(double v) { return round(v * 10.0) / 10.0; };
    double (^r2)(double) = ^double(double v) { return round(v * 100.0) / 100.0; };
    double muscleKg         = r1((double)data.musclePercent / 100.0 * w);
    double skeletalMuscleKg = r1((double)data.smPercent / 100.0 * w);
    double fatMassKg        = r1((double)data.bodyFatPercent / 100.0 * w);

    [self sendEvent:@{@"event": @"rtData",
                      @"deviceType":            @"scale",
                      @"deviceFamily":          @"icomon",
                      @"mac":                   device.macAddr ?: @"",
                      @"sdk":                   @"icomon",
                      @"isLocked":              @(data.isStabilized),
                      @"weightKg":              @(r2(w)),
                      @"bmi":                   @(r1(data.bmi)),
                      @"fat":                   @(r1(data.bodyFatPercent)),
                      @"fat_mass":              @(fatMassKg),
                      @"muscle":                @(muscleKg),
                      @"musclePercent":         @(r1(data.musclePercent)),
                      @"water":                 @(r1(data.moisturePercent)),
                      @"bone":                  @(r1(data.boneMass)),
                      @"protein":               @(r1(data.proteinPercent)),
                      @"bmr":                   @(data.bmr),
                      @"visceral":              @(r1(data.visceralFat)),
                      @"skeletal_muscle":       @(skeletalMuscleKg),
                      @"skeletalMusclePercent": @(r1(data.smPercent)),
                      @"subcutaneous":          @(r1(data.subcutaneousFatPercent)),
                      @"body_age":              @(data.physicalAge),
                      @"ci":                    @(r1(data.smi)),
                      @"body_score":            @(r1(data.bodyScore)),
                      @"temperature":           @(data.temperature),
                      @"heartRate":             @(data.hr),
                      @"impedance":             @(data.imp)}];
}
#endif  // FBD_HAS_ICOMON

#pragma mark - AirBP — CBPeripheralDelegate (Nordic UART)

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (self.activeMapping.protocolPath != VTMProtocolPathAirBP) return;
    if (error) {
        [self cancelConnectionWatchdog];
        FBD_LOG(@"AirBP discoverServices failed: %@", error.localizedDescription);
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"disconnected",
                          @"reason": error.localizedDescription ?: @"discover_services_failed"}];
        return;
    }
    for (CBService *svc in peripheral.services) {
        if ([svc.UUID.UUIDString caseInsensitiveCompare:kAirBPServiceUUID] == NSOrderedSame) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:kAirBPTxCharUUID],
                                                  [CBUUID UUIDWithString:kAirBPRxCharUUID]]
                                     forService:svc];
            return;
        }
    }
    [self cancelConnectionWatchdog];
    FBD_LOG(@"AirBP service %@ not advertised by peripheral", kAirBPServiceUUID);
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"disconnected",
                      @"reason": @"airbp_service_not_found"}];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    if (self.activeMapping.protocolPath != VTMProtocolPathAirBP) return;
    if (error) {
        [self cancelConnectionWatchdog];
        FBD_LOG(@"AirBP discoverCharacteristics failed: %@", error.localizedDescription);
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"disconnected",
                          @"reason": error.localizedDescription ?: @"discover_chars_failed"}];
        return;
    }
    for (CBCharacteristic *ch in service.characteristics) {
        if ([ch.UUID.UUIDString caseInsensitiveCompare:kAirBPTxCharUUID] == NSOrderedSame) {
            self.airBPTxChar = ch;
        } else if ([ch.UUID.UUIDString caseInsensitiveCompare:kAirBPRxCharUUID] == NSOrderedSame) {
            self.airBPRxChar = ch;
            [peripheral setNotifyValue:YES forCharacteristic:ch];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (self.activeMapping.protocolPath != VTMProtocolPathAirBP) return;
    if ([characteristic.UUID.UUIDString caseInsensitiveCompare:kAirBPRxCharUUID] != NSOrderedSame) return;
    if (error) {
        [self cancelConnectionWatchdog];
        FBD_LOG(@"AirBP subscribe failed: %@", error.localizedDescription);
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"disconnected",
                          @"reason": error.localizedDescription ?: @"subscribe_failed"}];
        return;
    }
    if (!characteristic.isNotifying) return;
    [self cancelConnectionWatchdog];
    self.serviceDeployed = YES;
    self.connectedModel  = self.activeMapping.lepuModel;
    FBD_LOG(@"AirBP deploy complete model=%ld", (long)self.connectedModel);
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"connected",
                      @"model": @(self.connectedModel),
                      @"family": self.activeMapping.family ?: @"airbp",
                      @"deviceType": self.activeMapping.deviceType ?: @"bp",
                      @"sdk": @"airbp"}];
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (self.activeMapping.protocolPath != VTMProtocolPathAirBP) return;
    if (error || characteristic.value.length == 0) return;
    if ([characteristic.UUID.UUIDString caseInsensitiveCompare:kAirBPRxCharUUID] != NSOrderedSame) return;

    [self.airBPRxBuffer appendData:characteristic.value];
    [self drainAirBPBuffer];
}

#pragma mark - AirBP — helpers

- (void)writeAirBPCommand:(uint8_t)cmd payload:(nullable NSData *)payload {
    if (self.airBPTxChar == nil || self.activePeripheral == nil) return;
    NSData *frame = [VTAirBPPacket buildCommand:cmd payload:payload];
    CBCharacteristicWriteType type = (self.airBPTxChar.properties & CBCharacteristicPropertyWrite)
        ? CBCharacteristicWriteWithResponse
        : CBCharacteristicWriteWithoutResponse;
    [self.activePeripheral writeValue:frame forCharacteristic:self.airBPTxChar type:type];
}

/// Drain the rolling RX buffer, emitting one event per well-formed frame and
/// leaving any trailing partial bytes in the buffer for the next packet.
- (void)drainAirBPBuffer {
    while (self.airBPRxBuffer.length >= 9) {
        const uint8_t *p = self.airBPRxBuffer.bytes;
        if (p[0] != 0xA5) {
            // Re-sync: drop bytes until we find a header or run out.
            NSRange hdr = [self.airBPRxBuffer rangeOfData:[NSData dataWithBytes:"\xA5" length:1]
                                                 options:0
                                                   range:NSMakeRange(0, self.airBPRxBuffer.length)];
            if (hdr.location == NSNotFound) {
                [self.airBPRxBuffer setLength:0];
                return;
            }
            [self.airBPRxBuffer replaceBytesInRange:NSMakeRange(0, hdr.location)
                                           withBytes:NULL length:0];
            continue;
        }
        uint16_t payloadLen = (uint16_t)p[4] | ((uint16_t)p[5] << 8);
        NSUInteger frameLen = 8 + payloadLen + 1;
        if (self.airBPRxBuffer.length < frameLen) return; // wait for more bytes

        NSData *frame = [self.airBPRxBuffer subdataWithRange:NSMakeRange(0, frameLen)];
        uint8_t cmd = 0;
        NSData *info = [VTAirBPPacket parseFrame:frame cmd:&cmd];
        [self.airBPRxBuffer replaceBytesInRange:NSMakeRange(0, frameLen) withBytes:NULL length:0];
        if (info == nil) continue;              // CRC mismatch — drop this frame
        [self handleAirBPFrameCmd:cmd payload:info];
    }
}

- (void)handleAirBPFrameCmd:(uint8_t)cmd payload:(NSData *)payload {
    NSString *mac = self.activePeripheral.identifier.UUIDString ?: @"";
    NSString *fam = self.activeMapping.family ?: @"airbp";

    switch (cmd) {
        case VTAirBPCmdStartMeasure:
        case VTAirBPCmdEngineeringStart: {
            // Payload: int16 pressure_static, int16 pressure_pulse (both LE × 100).
            if (payload.length < 4) return;
            const int8_t *b = payload.bytes;
            int16_t pStatic = (int16_t)((uint8_t)b[0] | ((uint8_t)b[1] << 8));
            int16_t pPulse  = (int16_t)((uint8_t)b[2] | ((uint8_t)b[3] << 8));
            [self sendEvent:@{@"event": @"rtData",
                              @"deviceType":   @"bp",
                              @"deviceFamily": fam,
                              @"sdk":          @"airbp",
                              @"mac":          mac,
                              @"model":        @(self.connectedModel),
                              @"measureType":  @"bp_measuring",
                              @"pressure":     @(pStatic / 100.0),
                              @"pressureRaw":  @(pStatic),
                              @"pulseWave":    @(pPulse),
                              @"pulseWaveRaw": @(pPulse)}];
            break;
        }
        case VTAirBPCmdStopMeasure: {
            [self sendEvent:@{@"event": @"measurementStopped",
                              @"sdk":   @"airbp",
                              @"mac":   mac}];
            break;
        }
        case VTAirBPCmdRunningStatus: {
            if (payload.length < 1) return;
            uint8_t status = ((const uint8_t *)payload.bytes)[0];
            [self sendEvent:@{@"event":        @"rtData",
                              @"deviceType":   @"bp",
                              @"deviceFamily": fam,
                              @"sdk":          @"airbp",
                              @"mac":          mac,
                              @"model":        @(self.connectedModel),
                              @"measureType":  @"bp_status",
                              @"status":       @(status)}];
            break;
        }
        case VTAirBPCmdMeasureResult: {
            // 16-byte record: y(2) m(1) d(1) h(1) mi(1) s(1) state(1)
            //                 sys(2) dia(2) mean(2) pr(2)
            if (payload.length < 16) return;
            const uint8_t *b = payload.bytes;
            uint16_t year  = (uint16_t)b[0] | ((uint16_t)b[1] << 8);
            int16_t sys   = (int16_t)((uint16_t)b[8]  | ((uint16_t)b[9]  << 8));
            int16_t dia   = (int16_t)((uint16_t)b[10] | ((uint16_t)b[11] << 8));
            int16_t mean  = (int16_t)((uint16_t)b[12] | ((uint16_t)b[13] << 8));
            uint16_t pr   = (uint16_t)b[14] | ((uint16_t)b[15] << 8);
            NSString *ts = [NSString stringWithFormat:@"%04d-%02d-%02d %02d:%02d:%02d",
                            year, b[2], b[3], b[4], b[5], b[6]];
            [self sendEvent:@{@"event":        @"rtData",
                              @"deviceType":   @"bp",
                              @"deviceFamily": fam,
                              @"sdk":          @"airbp",
                              @"mac":          mac,
                              @"model":        @(self.connectedModel),
                              @"measureType":  @"bp_result",
                              @"sys":          @(sys),
                              @"dia":          @(dia),
                              @"mean":         @(mean),
                              @"pr":           @(pr),
                              @"state":        @(b[7]),
                              @"timestamp":    ts}];
            break;
        }
        case VTAirBPCmdGetInfo: {
            [self sendEvent:@{@"event": @"deviceInfo",
                              @"sdk":   @"airbp",
                              @"model": @(self.connectedModel),
                              @"mac":   mac,
                              @"raw":   [payload base64EncodedStringWithOptions:0]}];
            break;
        }
        case VTAirBPCmdGetBattery: {
            if (payload.length < 1) return;
            uint8_t percent = ((const uint8_t *)payload.bytes)[0];
            [self sendEvent:@{@"event":   @"battery",
                              @"sdk":     @"airbp",
                              @"mac":     mac,
                              @"percent": @(percent)}];
            break;
        }
        default: {
            [self sendEvent:@{@"event":   @"raw",
                              @"sdk":     @"airbp",
                              @"mac":     mac,
                              @"cmdType": @(cmd),
                              @"data":    [payload base64EncodedStringWithOptions:0]}];
            break;
        }
    }
}

@end
