//
//  LthyBlePlugin.m
//  lthy_ble_plugin
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

#import "LthyBlePlugin.h"
#import "VTMDeviceTypeMapper.h"
#import "VTAirBPPacket.h"

#import <CoreBluetooth/CoreBluetooth.h>
#import <VTMProductLib/VTMProductLib.h>

// Nordic UART Service (NUS) — shared by TWO unrelated Viatom/Wellue
// protocols that both ride the standard Nordic GATT profile but with
// different framing on top:
//
//   • Viatom AirBP / SmartBP blood-pressure monitor — uses 0xA5-framed
//     URAT-style packets parsed by `VTAirBPPacket`.
//   • Wellue PC-60FW family fingertip oximeters (PF-10AW / PF-10AW1 /
//     PF-10BW / PF-10BW1, Lepu ids 85–88) — uses an `0xAA 0x55` synced
//     + CRC8/MAXIM framed packet stream where the device auto-pushes
//     SpO2/PR/PI samples once the TX-notify characteristic is enabled.
//     Reference: github.com/sza2/viatom_pc60fw README (the only public
//     write-up of this protocol).
//
// The `kAirBP*` names are kept for back-compat with existing call sites;
// `kPC60Fw*` aliases below make the PC60Fw code self-documenting.
static NSString *const kAirBPServiceUUID = @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static NSString *const kAirBPTxCharUUID  = @"6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // phone → device (write)
static NSString *const kAirBPRxCharUUID  = @"6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // device → phone (notify)
#define kPC60FwServiceUUID    kAirBPServiceUUID
#define kPC60FwTxCharUUID     kAirBPTxCharUUID
#define kPC60FwRxNotifyUUID   kAirBPRxCharUUID

// iComon scale SDK (vendored under ios/Frameworks/).
//
// The iComon SDK vendors Obj-C classes named `ICDevice`, `ICDeviceManager`
// and `ICDeviceInfo` — which collide with Apple's public
// `ImageCaptureCore.framework` and private `iTunesCloud.framework`. We
// surface that conflict only when the host app opts into the `IComon`
// subspec (see `lthy_ble_plugin.podspec`). When the subspec is not
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

#pragma mark - LthyBlePlugin

@interface LthyBlePlugin () <FlutterStreamHandler,
                                       CBCentralManagerDelegate,
                                       CBPeripheralDelegate,
                                       VTMURATDeviceDelegate,
                                       VTMURATDeviceExtension,
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

// PC60Fw state (when activeMapping.protocolPath == VTMProtocolPathPC60Fw)
//
// The TX/notify characteristic is the only one the device actually
// uses — the firmware streams real-time SpO2/PR/PI/waveform packets
// the moment notifications are enabled, with no app-side opcode
// required. We still capture the write characteristic for parity
// with the AirBP path in case a future firmware revision adds
// optional configuration writes.
@property (nonatomic, strong) CBCharacteristic *pc60FwTxChar;
@property (nonatomic, strong) CBCharacteristic *pc60FwRxChar;
@property (nonatomic, strong) NSMutableData    *pc60FwRxBuffer;

// In-progress URAT file download (BP2 / ER1 / ER2 / WOxi / FOxi / ER3 / MSeries).
// The URAT protocol is three-step: prepareReadFile → readFile:offset (chunked) →
// endReadFile. We hold these here so dispatchURATResponse can drive the
// state machine across the per-chunk responses.
@property (nonatomic, copy)   NSString       *pendingReadFileName;
@property (nonatomic, strong) NSMutableData  *pendingReadBuffer;
@property (nonatomic, assign) uint32_t        pendingReadTotalSize;
// When YES, the URAT chunk handler appends the in-flight chunk but
// stops requesting the next one — emulating a pause without dropping
// already-received bytes. `continueReadFile` re-issues
// `[uratUtil readFile:buffer.length]` to resume from the current
// offset; the device picks up exactly where it left off because URAT
// readFile is offset-keyed.
@property (nonatomic, assign) BOOL             pendingReadPaused;

// Most-recently received BP config snapshot, cached so `setDeviceConfig`
// can merge the consumer's requested fields on top without zeroing the
// calibration / volume / language fields the consumer didn't touch.
// Wrapped in NSValue because VTMBPConfig is a C struct. Cleared on
// disconnect. nil before the first `requestBPConfig` round-trip.
@property (nonatomic, strong) NSValue        *cachedBPConfig;

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

// ECG real-time pump is **response-paced**, NOT fixed-interval.
//
// Background: the original implementation used a 0.3 s NSTimer that
// fired `requestECGRealData` regardless of whether the previous
// request had been answered. CoreBluetooth is happy to queue multiple
// outstanding URAT commands on the same characteristic, but the Lepu
// ER1 / ER1-W firmware can only buffer one in flight before its rt
// buffer drains, which produced two visible symptoms in the live
// preview on iOS:
//
//   1. Sticky "Electrode off" — short batches landed entirely between
//      QRS complexes and tripped the Dart-side flat-line heuristic.
//   2. Glitchy / stalled waveform — the device occasionally returned
//      an empty packet because the previous request was still being
//      reassembled, then later returned a double-sized burst when
//      both queued requests resolved together.
//
// Both issues vanish if we fire the *next* request only after the
// previous response has been handed to `parseECGResponse:`. We keep a
// safety watchdog (`ecgRtWatchdog`) that re-issues the request if no
// response arrives within `_ecgRtWatchdogInterval`, covering the rare
// case where the SDK silently drops a request during a transient BLE
// stall. Together this matches the smoothness of Android's push-based
// `LiveEventBus.EventEr1RtData` stream without needing a new SDK.
@property (nonatomic, strong) NSTimer *ecgRtWatchdog;

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

@implementation LthyBlePlugin

#pragma mark - FlutterPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    LthyBlePlugin *inst = [LthyBlePlugin new];
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
    if ([method isEqualToString:@"getPermissionState"])     { [self handleGetPermissionState:result];     return; }
    if ([method isEqualToString:@"scan"])                   { [self handleScan:call result:result];       return; }
    if ([method isEqualToString:@"stopScan"])               { [self handleStopScan:result];               return; }
    if ([method isEqualToString:@"connect"])                { [self handleConnect:call result:result];    return; }
    if ([method isEqualToString:@"connectKnown"])           { [self handleConnectKnown:call result:result]; return; }
    if ([method isEqualToString:@"disconnect"])             { [self handleDisconnect:result];             return; }
    if ([method isEqualToString:@"syncTime"])               { [self handleSyncTime:call result:result];   return; }
    if ([method isEqualToString:@"getBattery"])             { [self handleGetBattery:call result:result]; return; }
    if ([method isEqualToString:@"getDeviceConfig"])        { [self handleGetDeviceConfig:call result:result]; return; }
    if ([method isEqualToString:@"setDeviceConfig"])        { [self handleSetDeviceConfig:call result:result]; return; }
    if ([method isEqualToString:@"getConnectedModel"])      { result(@(self.connectedModel));             return; }
    if ([method isEqualToString:@"startMeasurement"])       { [self handleStartMeasurement:call result:result]; return; }
    if ([method isEqualToString:@"stopMeasurement"])        { [self handleStopMeasurement:call result:result];  return; }
    if ([method isEqualToString:@"getDeviceInfo"])          { [self handleGetDeviceInfo:call result:result];    return; }
    if ([method isEqualToString:@"getFileList"])            { [self handleGetFileList:call result:result];      return; }
    if ([method isEqualToString:@"readFile"])               { [self handleReadFile:call result:result];         return; }
    if ([method isEqualToString:@"cancelReadFile"])         { [self handleCancelReadFile:call result:result];   return; }
    if ([method isEqualToString:@"readHistoryData"])        { [self handleReadHistoryData:call result:result];  return; }
    if ([method isEqualToString:@"pauseReadFile"])          { [self handlePauseReadFile:result];                return; }
    if ([method isEqualToString:@"continueReadFile"])       { [self handleContinueReadFile:result];             return; }
    if ([method isEqualToString:@"factoryReset"])           { [self handleFactoryReset:call result:result];     return; }
    if ([method isEqualToString:@"shutdown"])               { [self handleShutdown:call result:result];         return; }
    if ([method isEqualToString:@"updateUserInfo"])         { [self handleUpdateUserInfo:call result:result]; return; }
    if ([method isEqualToString:@"setScaleUserProfile"])    { [self handleSetScaleUserProfile:call result:result]; return; }
    if ([method isEqualToString:@"setScaleUserList"])       { [self handleSetScaleUserList:call result:result];    return; }
    if ([method isEqualToString:@"setScaleWeightUnit"])     { [self handleSetScaleWeightUnit:call result:result];  return; }
    if ([method isEqualToString:@"setScaleRulerUnit"])      { [self handleSetScaleRulerUnit:call result:result];   return; }
    if ([method isEqualToString:@"setKitchenScaleUnit"])    { [self handleSetKitchenScaleUnit:call result:result]; return; }
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

#if FBD_HAS_ICOMON
// Build an ICUserInfo from the Dart wire dictionary documented in
// `ScaleUserProfile.toMap()`. The mapping is straightforward except
// for two quirks worth calling out:
//
//   * ICUserInfo uses `enableMeasureImpendence` (sic — typo lives in
//     the SDK header) for impedance; we map our `enableImpedance`
//     onto it.
//   * `rulerMode` doesn't have a Dart wire field today — we always
//     pin it to `ICRulerMeasureModeLength` which matches the value
//     `_currentUserInfo` is initialised with at -init time. Surface
//     this once a Dart consumer asks for circumference mode.
- (ICUserInfo *)icUserInfoFromMap:(NSDictionary *)m {
    ICUserInfo *u = [ICUserInfo new];
    u.userIndex   = [m[@"userIndex"]    unsignedIntegerValue] ?: 1;
    u.userId      = [m[@"userId"]       unsignedIntegerValue];
    if ([m[@"nickName"] isKindOfClass:[NSString class]]) {
        u.nickName = m[@"nickName"];
    }
    u.height      = [m[@"heightCm"]     unsignedIntegerValue] ?: 170;
    u.age         = [m[@"age"]          unsignedIntegerValue] ?: 25;
    u.sex         = (ICSexType)[m[@"sex"] integerValue];
    u.weight      = [m[@"lastWeightKg"] floatValue];
    u.peopleType  = (ICPeopleType)[m[@"peopleType"]    unsignedIntegerValue];
    u.weightUnit  = (ICWeightUnit)[m[@"weightUnit"]    unsignedIntegerValue];
    u.rulerUnit   = (ICRulerUnit)([m[@"rulerUnit"]     unsignedIntegerValue] ?: ICRulerUnitCM);
    u.rulerMode   = ICRulerMeasureModeLength;
    u.kitchenUnit = (ICKitchenScaleUnit)[m[@"kitchenUnit"] unsignedIntegerValue];
    u.enableMeasureImpendence = [m[@"enableImpedance"]  boolValue];
    u.enableMeasureHr         = [m[@"enableHeartRate"]  boolValue];
    u.enableMeasureBalance    = [m[@"enableBalance"]    boolValue];
    u.enableMeasureGravity    = [m[@"enableGravity"]    boolValue];
    return u;
}

// Reverse of icUserInfoFromMap: takes an ICUserInfo (e.g. from the
// onReceiveUserInfo / onReceiveUserInfoList callbacks) and produces
// the wire dictionary `ScaleUserProfile.fromMap()` understands.
- (NSDictionary *)mapFromIcUserInfo:(ICUserInfo *)u {
    return @{
        @"userIndex":       @(u.userIndex),
        @"userId":          @(u.userId),
        @"nickName":        u.nickName ?: [NSNull null],
        @"heightCm":        @(u.height),
        @"age":             @(u.age),
        @"sex":             @(u.sex),
        @"lastWeightKg":    @(u.weight),
        @"peopleType":      @(u.peopleType),
        @"weightUnit":      @(u.weightUnit),
        @"rulerUnit":       @(u.rulerUnit),
        @"kitchenUnit":     @(u.kitchenUnit),
        @"enableImpedance": @(u.enableMeasureImpendence),
        @"enableHeartRate": @(u.enableMeasureHr),
        @"enableBalance":   @(u.enableMeasureBalance),
        @"enableGravity":   @(u.enableMeasureGravity),
    };
}
#endif

// Rich-profile counterpart to handleUpdateUserInfo: accepts every
// field a Dart consumer may want to push (including W-series user
// id + nickname + measurement-feature flags).
- (void)handleSetScaleUserProfile:(FlutterMethodCall *)call
                          result:(FlutterResult)result {
#if FBD_HAS_ICOMON
    NSDictionary *args = call.arguments;
    if (![args isKindOfClass:[NSDictionary class]]) {
        result([FlutterError errorWithCode:@"BAD_ARG"
                                   message:@"setScaleUserProfile expects a Map payload"
                                   details:nil]);
        return;
    }
    ICUserInfo *info = [self icUserInfoFromMap:args];
    self.currentUserInfo = info;
    if (self.iComonInitialized) {
        [[ICDeviceManager shared] updateUserInfo:info];
        FBD_LOG(@"iComon setScaleUserProfile pushed (userIndex=%lu)",
                (unsigned long)info.userIndex);
    }
    result(@YES);
#else
    (void)call;
    result(@YES);
#endif
}

// Multi-user push to a W-series scale. The Dart wire payload is a
// list of profile maps; we translate to NSArray<ICUserInfo *> and
// hand off via the SDK's `setUserList:`. Note that this is the
// *global* SDK-level user list (mirrored to every connected
// W-series device); the per-device `setUserList:userInfos:` on the
// setting manager is used when you want to scope to one device.
- (void)handleSetScaleUserList:(FlutterMethodCall *)call
                       result:(FlutterResult)result {
#if FBD_HAS_ICOMON
    NSArray *raw = call.arguments[@"profiles"];
    if (![raw isKindOfClass:[NSArray class]]) {
        result([FlutterError errorWithCode:@"BAD_ARG"
                                   message:@"setScaleUserList expects {profiles: [...]} payload"
                                   details:nil]);
        return;
    }
    NSMutableArray<ICUserInfo *> *list = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSDictionary *m in raw) {
        if ([m isKindOfClass:[NSDictionary class]]) {
            [list addObject:[self icUserInfoFromMap:m]];
        }
    }
    [[ICDeviceManager shared] setUserList:list];
    FBD_LOG(@"iComon setUserList pushed (%lu profiles)", (unsigned long)list.count);
    // If a device is connected and it's a W-series scale, ALSO push
    // per-device so the on-device storage matches. The setting
    // manager call is a no-op for non-W scales.
    if (self.activeIComonDevice != nil) {
        id<ICDeviceManagerSettingManager> mgr = [[ICDeviceManager shared] getSettingManager];
        if ([mgr respondsToSelector:@selector(setUserList:userInfos:callback:)]) {
            [mgr setUserList:self.activeIComonDevice
                  userInfos:list
                   callback:^(ICSettingCallBackCode code) {
                FBD_LOG(@"iComon setUserList per-device code=%d", (int)code);
            }];
        }
    }
    result(@YES);
#else
    (void)call;
    result(@YES);
#endif
}

// Wrapper around `setScaleUnit:`. The `unit` argument is the raw
// ICWeightUnit ordinal (kg=0, lb=1, st=2, jin=3). Returns false if
// no iComon device is connected — the setting manager methods need
// an explicit ICDevice handle.
- (void)handleSetScaleWeightUnit:(FlutterMethodCall *)call
                         result:(FlutterResult)result {
#if FBD_HAS_ICOMON
    if (self.activeIComonDevice == nil) {
        result([FlutterError errorWithCode:@"NOT_CONNECTED"
                                   message:@"No iComon scale connected"
                                   details:nil]);
        return;
    }
    NSNumber *unitNum = call.arguments[@"unit"];
    if (unitNum == nil) {
        result([FlutterError errorWithCode:@"BAD_ARG"
                                   message:@"setScaleWeightUnit requires {unit: int}"
                                   details:nil]);
        return;
    }
    ICWeightUnit unit = (ICWeightUnit)[unitNum unsignedIntegerValue];
    id<ICDeviceManagerSettingManager> mgr = [[ICDeviceManager shared] getSettingManager];
    [mgr setScaleUnit:self.activeIComonDevice
                 unit:unit
             callback:^(ICSettingCallBackCode code) {
        FBD_LOG(@"setScaleUnit code=%d", (int)code);
    }];
    result(@YES);
#else
    (void)call;
    result([FlutterError errorWithCode:@"UNSUPPORTED"
                               message:@"iComon subspec not active"
                               details:nil]);
#endif
}

- (void)handleSetScaleRulerUnit:(FlutterMethodCall *)call
                        result:(FlutterResult)result {
#if FBD_HAS_ICOMON
    if (self.activeIComonDevice == nil) {
        result([FlutterError errorWithCode:@"NOT_CONNECTED"
                                   message:@"No iComon ruler connected"
                                   details:nil]);
        return;
    }
    NSNumber *unitNum = call.arguments[@"unit"];
    if (unitNum == nil) {
        result([FlutterError errorWithCode:@"BAD_ARG"
                                   message:@"setScaleRulerUnit requires {unit: int}"
                                   details:nil]);
        return;
    }
    ICRulerUnit unit = (ICRulerUnit)[unitNum unsignedIntegerValue];
    id<ICDeviceManagerSettingManager> mgr = [[ICDeviceManager shared] getSettingManager];
    [mgr setRulerUnit:self.activeIComonDevice
                 unit:unit
             callback:^(ICSettingCallBackCode code) {
        FBD_LOG(@"setRulerUnit code=%d", (int)code);
    }];
    result(@YES);
#else
    (void)call;
    result([FlutterError errorWithCode:@"UNSUPPORTED"
                               message:@"iComon subspec not active"
                               details:nil]);
#endif
}

- (void)handleSetKitchenScaleUnit:(FlutterMethodCall *)call
                          result:(FlutterResult)result {
#if FBD_HAS_ICOMON
    if (self.activeIComonDevice == nil) {
        result([FlutterError errorWithCode:@"NOT_CONNECTED"
                                   message:@"No iComon kitchen scale connected"
                                   details:nil]);
        return;
    }
    NSNumber *unitNum = call.arguments[@"unit"];
    if (unitNum == nil) {
        result([FlutterError errorWithCode:@"BAD_ARG"
                                   message:@"setKitchenScaleUnit requires {unit: int}"
                                   details:nil]);
        return;
    }
    ICKitchenScaleUnit unit = (ICKitchenScaleUnit)[unitNum unsignedIntegerValue];
    id<ICDeviceManagerSettingManager> mgr = [[ICDeviceManager shared] getSettingManager];
    [mgr setKitchenScaleUnit:self.activeIComonDevice
                        unit:unit
                    callback:^(ICSettingCallBackCode code) {
        FBD_LOG(@"setKitchenScaleUnit code=%d", (int)code);
    }];
    result(@YES);
#else
    (void)call;
    result([FlutterError errorWithCode:@"UNSUPPORTED"
                               message:@"iComon subspec not active"
                               details:nil]);
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
    self.cachedBPConfig       = nil;

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
                                   message:@"iComon scale support is not compiled in. Add the 'IComon' subspec to your Podfile — see lthy_ble_plugin README."
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

#pragma mark - Connect by known identifier (no scan)

// Direct-connect to a peripheral CoreBluetooth remembers from a prior
// session. The OS keeps the CBPeripheral instance around for at least
// the lifetime of the app process — and often across launches — so a
// re-launch can connect without paying for a fresh scan.
//
// Flow:
//   1. Parse `mac` as an NSUUID and call
//      `retrievePeripheralsWithIdentifiers:` on the central. If the OS
//      still knows the peripheral we land in `discovered`/`mappings`
//      immediately and connect like a normal `connect()` call.
//   2. If the lookup misses (fresh install, the OS evicted us, the
//      user erased Bluetooth settings…) we fall through to a short
//      model-filtered scan and replay the connect once the device
//      advertises. This is the same fallback `connect()` already does
//      from the cache-empty branch, so the recovery path is identical.
//
// Important: the iComon path doesn't need direct-connect — `addDevice:`
// already accepts a MAC string with no scan, so we just dispatch
// straight to `handleConnect:` after relabelling the sdk argument.
- (void)handleConnectKnown:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSString *sdk = call.arguments[@"sdk"] ?: @"lepu";
    if ([sdk isEqualToString:@"icomon"]) {
        // iComon SDK's addDevice already operates by MAC alone — defer
        // to the standard connect flow.
        [self handleConnect:call result:result];
        return;
    }

    NSString *mac = call.arguments[@"mac"];
    if (mac.length == 0) {
        result([FlutterError errorWithCode:@"INVALID_ARGS"
                                   message:@"mac is required"
                                   details:nil]);
        return;
    }
    NSNumber *modelObj = call.arguments[@"model"];
    if (modelObj == nil) {
        result([FlutterError errorWithCode:@"INVALID_ARGS"
                                   message:@"model is required for connectKnown(sdk:lepu)"
                                   details:nil]);
        return;
    }

    // Try direct lookup first.
    if (self.central == nil) {
        // Initialise the central if the consumer hasn't yet — they're
        // calling connectKnown straight after launch. Symmetric with
        // how handleRequestPermissions nudges the central into existence.
        self.central = [[CBCentralManager alloc] initWithDelegate:self
                                                            queue:dispatch_get_main_queue()];
    }
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:mac];
    CBPeripheral *known = nil;
    if (uuid) {
        NSArray<CBPeripheral *> *peripherals =
            [self.central retrievePeripheralsWithIdentifiers:@[uuid]];
        if (peripherals.count > 0) known = peripherals.firstObject;
    }

    if (known) {
        // Hydrate the discovery cache so handleConnect's mac lookup
        // succeeds. We don't have advertisement data on this path so
        // populate just the mapping; deploy will fall back to the
        // model id the consumer supplied.
        VTMDeviceMapping *mapping = [VTMDeviceTypeMapper mappingForLepuModel:modelObj.integerValue];
        if (mapping == nil) {
            result([FlutterError errorWithCode:@"UNSUPPORTED_DEVICE"
                                       message:@"Device model is not recognised by VTProductLib"
                                       details:@{@"model": modelObj}]);
            return;
        }
        self.discovered[mac] = known;
        self.mappings[mac]   = mapping;
        FBD_LOG(@"connectKnown direct-connect mac=%@ model=%ld",
                mac, (long)modelObj.integerValue);
        [self handleConnect:call result:result];
        return;
    }

    // Fall back to a short scan to find the peripheral, then connect.
    // The Dart side gets the same `connecting`/`connected` lifecycle as
    // it would from a normal connect — no consumer change needed.
    FBD_LOG(@"connectKnown miss for mac=%@ — falling back to scan", mac);
    self.scanModelFilter = @[modelObj];
    if (![self isBluetoothPoweredOn]) {
        self.scanRequested = YES;
    } else {
        [self startCentralScan];
    }
    // Watchdog: stop after 10 s and fail the connect if the device
    // hasn't been seen.
    __weak typeof(self) weakSelf = self;
    NSString *targetMac = [mac copy];
    __block BOOL settled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (settled) return;
        settled = YES;
        typeof(self) s = weakSelf;
        if (s == nil) return;
        if (s.central.isScanning) [s.central stopScan];
        if (s.discovered[targetMac] != nil) {
            // Discovery happened in the window — promote to connect.
            [s handleConnect:call result:result];
        } else {
            result([FlutterError errorWithCode:@"UNKNOWN_DEVICE"
                                       message:@"connectKnown: peripheral not found within 10s. Call scan() and wait for deviceFound first."
                                       details:@{@"mac": targetMac}]);
        }
    });
    // Result is delivered from the watchdog block. Return now so the
    // method channel call doesn't block.
}

#pragma mark - Time sync

// Push phone time to the device so on-device recordings get accurate
// timestamps. iOS URAT path uses `[VTMURATUtils syncTime:]` which
// also accepts nil → uses the SDK's current-time helper internally;
// the legacy O2 protocol exposes a `VTParamTypeDate` setting whose
// content is the ISO-ish wall-clock string the firmware expects.
- (void)handleSyncTime:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;

    NSNumber *epochMs = call.arguments[@"epochMs"];
    NSDate *date = epochMs ? [NSDate dateWithTimeIntervalSince1970:epochMs.doubleValue / 1000.0]
                            : [NSDate date];

    if (m.protocolPath == VTMProtocolPathURAT) {
        if (self.uratUtil == nil) {
            result([FlutterError errorWithCode:@"NOT_READY"
                                       message:@"URAT util not initialised"
                                       details:nil]);
            return;
        }
        [self.uratUtil syncTime:date];
        result(@YES);
        return;
    }
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        if (self.o2Util == nil) {
            result([FlutterError errorWithCode:@"NOT_READY"
                                       message:@"O2 util not initialised"
                                       details:nil]);
            return;
        }
        // VTParamTypeDate's content is the device's local wall-clock
        // formatted as "yyyy-MM-dd HH:mm:ss". Match the firmware spec:
        // the device interprets the string in its own timezone, so we
        // emit phone-local wall-clock — same convention the recorded
        // file uses (see lib/src/parsers/bp2_file.dart timestamp note).
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df.timeZone   = [NSTimeZone localTimeZone];
        [self.o2Util beginToParamType:VTParamTypeDate content:[df stringFromDate:date]];
        result(@YES);
        return;
    }
    // Every other protocol path (AirBP / PC60FW / iComon) doesn't
    // expose an on-device clock to sync — silently succeed so Dart
    // code can call syncTime() unconditionally.
    result(@YES);
}

#pragma mark - Battery query (on-demand)

// Universal on iOS — every URAT family supports requestBatteryInfo,
// and the legacy O2 protocol embeds the battery in `getInfo`.
- (void)handleGetBattery:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;

    if (m.protocolPath == VTMProtocolPathURAT && self.uratUtil) {
        [self.uratUtil requestBatteryInfo];
        result(@YES);
        return;
    }
    if (m.protocolPath == VTMProtocolPathO2Legacy && self.o2Util) {
        // Legacy O2 ships battery inside the periodic info response, so
        // a `beginGetInfo` triggers a battery emission via the
        // o2GetInfoCallback pipeline (which already forwards
        // `info.battery` as a deviceInfo event). To keep the wire-format
        // uniform we re-fire after getInfo lands — simpler than wiring
        // a synthetic battery event here. Consumers should listen on
        // [BluetodevController.batteryStream] which we publish from
        // getInfo's emit path below.
        [self.o2Util beginGetInfo];
        result(@YES);
        return;
    }
    result([FlutterError errorWithCode:@"UNSUPPORTED"
                               message:@"This device family does not expose a battery query on iOS"
                               details:@{@"family": m.family ?: @"unknown"}]);
}

#pragma mark - Device configuration (get / set)

- (void)handleGetDeviceConfig:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;

    if (m.protocolPath != VTMProtocolPathURAT || self.uratUtil == nil) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"Device config is only available on URAT-family devices (BP2/BP3/WOxi/FOxi/ER1/ER2)"
                                   details:@{@"family": m.family ?: @"unknown"}]);
        return;
    }
    switch (m.vtmDeviceType) {
        case VTMDeviceTypeBP:
            [self.uratUtil requestBPConfig];   break;
        case VTMDeviceTypeWOxi:
            [self.uratUtil woxi_requestConfig]; break;
        case VTMDeviceTypeFOxi:
            [self.uratUtil foxi_requestConfig]; break;
        case VTMDeviceTypeECG:
            [self.uratUtil requestECGConfig];  break;
        case VTMDeviceTypeER3:
            [self.uratUtil requestER3Config];  break;
        case VTMDeviceTypeBabyPatch:
            [self.uratUtil baby_requestConfig]; break;
        default:
            result([FlutterError errorWithCode:@"UNSUPPORTED"
                                       message:@"This device family does not expose a config query"
                                       details:@{@"family": m.family ?: @"unknown"}]);
            return;
    }
    result(@YES);
}

- (void)handleSetDeviceConfig:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;
    NSArray *fields = call.arguments[@"fields"];
    if (![fields isKindOfClass:NSArray.class] || fields.count == 0) {
        result([FlutterError errorWithCode:@"INVALID_ARGS"
                                   message:@"fields must be a non-empty list"
                                   details:nil]);
        return;
    }

    if (m.protocolPath != VTMProtocolPathURAT || self.uratUtil == nil) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"Device config is only available on URAT-family devices"
                                   details:@{@"family": m.family ?: @"unknown"}]);
        return;
    }

    switch (m.vtmDeviceType) {
        case VTMDeviceTypeBP:
            [self setBPConfigFields:fields result:result]; return;
        case VTMDeviceTypeWOxi:
            [self setWOxiConfigFields:fields result:result]; return;
        case VTMDeviceTypeFOxi:
            [self setFOxiConfigFields:fields result:result]; return;
        default:
            result([FlutterError errorWithCode:@"UNSUPPORTED"
                                       message:@"setDeviceConfig is wired for BP / WOxi / FOxi families only"
                                       details:@{@"family": m.family ?: @"unknown"}]);
            return;
    }
}

// BP family setConfig: takes a full VTMBPConfig struct. We require the
// caller to have invoked getDeviceConfig at least once so we have a
// cached snapshot — otherwise writing back risks zeroing the device's
// calibration constants (which then need a service-grade re-cal).
- (void)setBPConfigFields:(NSArray *)fields result:(FlutterResult)result {
    if (self.cachedBPConfig == nil) {
        result([FlutterError errorWithCode:@"NO_BASELINE"
                                   message:@"BP setDeviceConfig requires a prior getDeviceConfig() — call it first so calibration fields aren't zeroed."
                                   details:nil]);
        return;
    }
    VTMBPConfig cfg;
    [self.cachedBPConfig getValue:&cfg];
    for (NSDictionary *field in fields) {
        if (![field isKindOfClass:NSDictionary.class]) continue;
        NSString *name  = field[@"name"];
        id        value = field[@"value"];
        if ([name isEqualToString:@"volume"]         && [value isKindOfClass:NSNumber.class]) cfg.volume = [value unsignedCharValue];
        else if ([name isEqualToString:@"avgMeasureMode"] && [value isKindOfClass:NSNumber.class]) cfg.avg_measure_mode = [value unsignedCharValue];
        else if ([name isEqualToString:@"deviceSwitch"]   && [value isKindOfClass:NSNumber.class]) cfg.device_switch    = [value unsignedCharValue];
        else if ([name isEqualToString:@"unit"]           && [value isKindOfClass:NSNumber.class]) cfg.unit             = [value unsignedCharValue];
        else if ([name isEqualToString:@"language"]       && [value isKindOfClass:NSNumber.class]) cfg.language         = [value unsignedCharValue];
        else if ([name isEqualToString:@"timeUtc"]        && [value isKindOfClass:NSNumber.class]) cfg.time_utc         = [value unsignedCharValue];
        else if ([name isEqualToString:@"soundOn"]        && [value isKindOfClass:NSNumber.class]) {
            // Map bool → device_switch bit0 (sound). Preserve other bits.
            if ([value boolValue]) cfg.device_switch |= 0x01;
            else                   cfg.device_switch &= ~0x01;
        }
        else if ([name isEqualToString:@"targetPressure"] && [value isKindOfClass:NSNumber.class]) cfg.bp_test_target_pressure = [value unsignedShortValue];
        else {
            FBD_LOG(@"setBPConfigFields: ignoring unknown field '%@'", name);
        }
    }
    // Persist the merged snapshot so the next set call layers on top.
    self.cachedBPConfig = [NSValue valueWithBytes:&cfg objCType:@encode(VTMBPConfig)];
    [self.uratUtil syncBPConfig:cfg];
    result(@YES);
}

// WOxi family setConfig: one VTMOxiParamsOption per field, single
// 4-byte value. The vendor enum maps name → type byte.
- (void)setWOxiConfigFields:(NSArray *)fields result:(FlutterResult)result {
    NSUInteger written = 0;
    for (NSDictionary *field in fields) {
        if (![field isKindOfClass:NSDictionary.class]) continue;
        NSString *name = field[@"name"];
        id      value  = field[@"value"];
        if (![value isKindOfClass:NSNumber.class]) continue;
        VTMWOxiSetParams type = [self woxiParamTypeForName:name];
        if (type == 0 && ![name isEqualToString:@"all"]) {
            FBD_LOG(@"setWOxiConfigFields: skipping unknown field '%@'", name);
            continue;
        }
        VTMOxiParamsOption opt;
        memset(&opt, 0, sizeof(opt));
        opt.type        = (u_char)type;
        opt.param.val   = [value unsignedIntValue];
        [self.uratUtil woxi_syncConfigParam:opt];
        written++;
    }
    result(@(written > 0));
}

// FOxi family setConfig: same per-field wire format as WOxi, different
// type-enum mapping.
- (void)setFOxiConfigFields:(NSArray *)fields result:(FlutterResult)result {
    NSUInteger written = 0;
    for (NSDictionary *field in fields) {
        if (![field isKindOfClass:NSDictionary.class]) continue;
        NSString *name = field[@"name"];
        id      value  = field[@"value"];
        if (![value isKindOfClass:NSNumber.class]) continue;
        VTMFOxiSetParams type = [self foxiParamTypeForName:name];
        if (type == 0 && ![name isEqualToString:@"all"]) {
            FBD_LOG(@"setFOxiConfigFields: skipping unknown field '%@'", name);
            continue;
        }
        VTMOxiParamsOption opt;
        memset(&opt, 0, sizeof(opt));
        opt.type        = (u_char)type;
        opt.param.val   = [value unsignedIntValue];
        [self.uratUtil foxi_syncConfigParam:opt];
        written++;
    }
    result(@(written > 0));
}

// Field-name → VTMWOxiSetParams enum mapping. Returns 0 (== "all",
// reserved) when the name is unknown so the caller can detect misses.
- (VTMWOxiSetParams)woxiParamTypeForName:(NSString *)name {
    static NSDictionary<NSString *, NSNumber *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"spo2RemindSw": @(VTMWOxiSetParamsSpO2Sw),
            @"spo2Thr":      @(VTMWOxiSetParamsSpO2Thr),
            @"hrRemindSw":   @(VTMWOxiSetParamsHRSw),
            @"hrThrLow":     @(VTMWOxiSetParamsHRThrLow),
            @"hrThrHigh":    @(VTMWOxiSetParamsHRThrHigh),
            @"motor":        @(VTMWOxiSetParamsMotor),
            @"buzzer":       @(VTMWOxiSetParamsBuzzer),
            @"displayMode":  @(VTMWOxiSetParamsDisplayMode),
            @"brightness":   @(VTMWOxiSetParamsBrightness),
            @"interval":     @(VTMWOxiSetParamsInterval),
            @"timezone":     @(VTMWOxiSetParamsTimeZoom),
            @"pushCtrl":     @(VTMWOxiSetParamsPushCtrl),
            @"algAvgTime":   @(VTMWOxiSetParamsAlgAvgtime),
            @"countdownTime":@(VTMWOxiSetParamsCountdownTime),
            @"handedness":   @(VTMWOxiSetParamsHandedness),
            @"motionSw":     @(VTMWOxiSetParamsMotionSw),
            @"motionThr":    @(VTMWOxiSetParamsMotionThr),
            @"invalidSignalSw":  @(VTMWOxiSetParamsInvalidSignalSw),
            @"invalidSignalThr": @(VTMWOxiSetParamsInvalidSignalThr),
            @"spo2FuncSw":   @(VTMWOxiSetParamsSpo2FuncSw),
        };
    });
    NSNumber *n = table[name];
    return n ? (VTMWOxiSetParams)n.unsignedIntegerValue : (VTMWOxiSetParams)0;
}

// Field-name → VTMFOxiSetParams enum mapping. Same conventions as
// woxiParamTypeForName:.
- (VTMFOxiSetParams)foxiParamTypeForName:(NSString *)name {
    static NSDictionary<NSString *, NSNumber *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"spo2Low":     @(VTMFOxiSetParamsSpO2Low),
            @"prHigh":      @(VTMFOxiSetParamsPRHigh),
            @"prLow":       @(VTMFOxiSetParamsPRLow),
            @"alarm":       @(VTMFOxiSetParamsAlram),
            @"measureMode": @(VTMFOxiSetParamsMeasureMode),
            @"beep":        @(VTMFOxiSetParamsBeep),
            @"language":    @(VTMFOxiSetParamsLanguage),
            @"bleSw":       @(VTMFOxiSetParamsBleSw),
            @"esMode":      @(VTMFOxiSetParamsESMode),
        };
    });
    NSNumber *n = table[name];
    return n ? (VTMFOxiSetParams)n.unsignedIntegerValue : (VTMFOxiSetParams)0;
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
    self.pendingReadPaused    = NO;
    self.cachedBPConfig       = nil;
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
    if (m.protocolPath == VTMProtocolPathPC60Fw) {
        // PC-60FW family auto-streams as soon as the Nordic UART notify
        // characteristic is enabled at deploy time. There is no explicit
        // "begin streaming" opcode in the protocol — the device is
        // already pushing SpO2/PR/PI/waveform packets when this Dart
        // call lands. Mark `measuring` so symmetric `stopMeasurement`
        // semantics are preserved on the Dart side.
        self.measuring = YES;
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
            // Response-paced pump — see the `ecgRtWatchdog` header
            // comment for the rationale. We stop any leftover fixed
            // interval timer first (defensive: handleStartMeasurement
            // can be re-invoked after a brief disconnect), fire the
            // first request, then let the response handler drive every
            // subsequent request.
            [self stopRtPoll];
            self.measuring = YES;
            [self armEcgRtWatchdog];
            [self.uratUtil requestECGRealData];
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
    if (m.protocolPath == VTMProtocolPathPC60Fw) {
        // No "stop streaming" opcode is documented for the PC-60FW
        // protocol — the device only stops when notifications are
        // disabled or the link drops. We can't unsubscribe without
        // tearing down the connection, so this is a no-op that just
        // clears the local `measuring` flag for parity with the AirBP
        // and URAT paths.
        self.measuring = NO;
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
    [self cancelEcgRtWatchdog];
}

#pragma mark - ECG response-paced pump

// Interval after which we assume a `requestECGRealData` response has
// been lost and the pump needs a kick. Chosen to comfortably exceed
// the longest observed rt-data turn-around (~1.5 s on a clean BLE
// link) while still recovering quickly enough that the Dart-side
// lead-off watchdog (6 s) never fires on a healthy stream.
static const NSTimeInterval kEcgRtWatchdogInterval = 2.5;

/// Schedule (or re-arm) the safety watchdog. Called on every
/// `requestECGRealData` we send; cancelled when the corresponding
/// response arrives in `parseECGResponse:`.
- (void)armEcgRtWatchdog {
    [self cancelEcgRtWatchdog];
    if (!self.measuring) return;
    __weak typeof(self) weakSelf = self;
    self.ecgRtWatchdog = [NSTimer scheduledTimerWithTimeInterval:kEcgRtWatchdogInterval
                                                         repeats:NO
                                                           block:^(NSTimer * _Nonnull t) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s == nil) return;
        if (!s.measuring || s.uratUtil == nil) return;
        // No response in `kEcgRtWatchdogInterval` — the SDK either
        // swallowed the request or the device dropped it during a
        // BLE stall. Re-issue and re-arm.
        [s.uratUtil requestECGRealData];
        [s armEcgRtWatchdog];
    }];
}

- (void)cancelEcgRtWatchdog {
    if (self.ecgRtWatchdog) {
        [self.ecgRtWatchdog invalidate];
        self.ecgRtWatchdog = nil;
    }
}

/// Pace the next `requestECGRealData`. Called from `parseECGResponse:`
/// the instant a real-time-data frame is handed to Dart. A tiny
/// dispatch delay gives CoreBluetooth's notification queue a moment to
/// drain so we don't immediately stomp on the channel; in practice
/// 20-50 ms is plenty and keeps the effective rt cadence at ≈1 Hz on
/// ER1-class firmware.
- (void)scheduleNextEcgRtRequest {
    if (!self.measuring) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s == nil) return;
        if (!s.measuring || s.uratUtil == nil) return;
        [s.uratUtil requestECGRealData];
        [s armEcgRtWatchdog];
    });
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
    if (m.protocolPath == VTMProtocolPathPC60Fw) {
        // PC-60FW exposes its hardware/firmware revision via the
        // 0xF0-header metadata frames the device pushes spontaneously
        // after subscribe (see drainPC60FwBuffer), not via a request /
        // response API. There's no opcode to ask for it on demand, so
        // we surface UNSUPPORTED here rather than silently dropping
        // the call — the Dart layer should listen on the `raw` event
        // stream if it really needs to see those metadata frames.
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"PC-60FW family pushes device info passively; no request API."
                                   details:nil]);
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
    if (m.protocolPath == VTMProtocolPathPC60Fw) {
        // PC-60FW oximeters don't expose on-device flash storage —
        // historical recordings live in the companion phone app's DB,
        // not on the device. There's no file-list opcode to call.
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"PC-60FW family has no on-device file storage."
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
            self.pendingReadPaused    = NO;
            [self.uratUtil prepareReadFile:name];
        } else if (m.protocolPath == VTMProtocolPathO2Legacy) {
            self.pendingReadFileName  = name;
            self.pendingReadBuffer    = nil;
            self.pendingReadTotalSize = 0;
            self.pendingReadPaused    = NO;
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
    if (m.protocolPath == VTMProtocolPathPC60Fw) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"PC-60FW family has no on-device file storage."
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
        self.pendingReadPaused    = NO;
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
    self.pendingReadPaused    = NO;
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
    self.pendingReadPaused    = NO;
    [self sendEvent:@{@"event": @"fileReadError",
                      @"deviceFamily": [self fileFamilyForActiveMapping],
                      @"model": @(self.connectedModel),
                      @"fileName": fileName ?: @"",
                      @"error": @"cancelled"}];
    result(@YES);
}

// pauseReadFile — flips the `pendingReadPaused` flag. The URAT chunk
// handler appends the in-flight chunk that may already be in the
// notify pipe but stops calling `readFile:offset` for the next one,
// so the device falls silent. Idempotent: pausing twice is a no-op
// that returns NO so consumers can detect the redundant call.
//
// For the legacy O2 download path (`o2Util beginReadFileWithFileName:`)
// the SDK drives chunking itself with no per-chunk hook, so true
// pause/resume isn't possible — the consumer must `cancelReadFile`
// and re-issue the read instead. We surface that explicitly.
- (void)handlePauseReadFile:(FlutterResult)result {
    if (self.pendingReadFileName == nil) {
        result(@NO);
        return;
    }
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath == VTMProtocolPathO2Legacy) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"Legacy O2 SDK has no per-chunk hook; cancelReadFile and retry instead."
                                   details:nil]);
        return;
    }
    if (self.pendingReadPaused) { result(@NO); return; }
    self.pendingReadPaused = YES;
    FBD_LOG(@"pauseReadFile: paused at %lu / %u bytes",
            (unsigned long)self.pendingReadBuffer.length, self.pendingReadTotalSize);
    result(@YES);
}

// continueReadFile — clears the pause flag and re-issues the next
// chunk request at the current buffer offset. URAT readFile is
// offset-keyed so the device picks up exactly where it left off.
- (void)handleContinueReadFile:(FlutterResult)result {
    if (self.pendingReadFileName == nil) {
        result(@NO);
        return;
    }
    if (!self.pendingReadPaused) { result(@NO); return; }
    self.pendingReadPaused = NO;
    if (self.uratUtil != nil) {
        [self.uratUtil readFile:(uint32_t)self.pendingReadBuffer.length];
    }
    FBD_LOG(@"continueReadFile: resumed from %lu bytes",
            (unsigned long)self.pendingReadBuffer.length);
    result(@YES);
}

// shutdown — politely tell the device to power off. Only a handful of
// families expose a dedicated opcode for this:
//
//   * BP2 family — `requestChangeBPState:VTMBPTargetStatusEnd` (already
//     reused inside startMeasurement when mode=="off").
//   * iComon kitchen scale — `powerOffKitchenScale:` from
//     ICDeviceManager.SettingManager.
//
// For everything else (ER1/ER2/WOxi/FOxi/legacy O2/AirBP/PC60Fw/body
// scales) the device has no shutdown command and powers off only via
// the hardware button. We return UNSUPPORTED so consumers can choose
// to disconnect instead.
- (void)handleShutdown:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![self ensureReady:result]) return;
    VTMDeviceMapping *m = self.activeMapping;
    if (m.protocolPath == VTMProtocolPathURAT &&
        m.vtmDeviceType == VTMDeviceTypeBP &&
        self.uratUtil   != nil) {
        [self.uratUtil requestChangeBPState:VTMBPTargetStatusEnd];
        result(@YES);
        return;
    }
#if FBD_HAS_ICOMON
    if (m.protocolPath == VTMProtocolPathIComon && self.activeIComonDevice != nil) {
        id<ICDeviceManagerSettingManager> mgr = [[ICDeviceManager shared] getSettingManager];
        if ([mgr respondsToSelector:@selector(powerOffKitchenScale:callback:)]) {
            [mgr powerOffKitchenScale:self.activeIComonDevice callback:^(ICSettingCallBackCode code) {
                FBD_LOG(@"powerOffKitchenScale callback code=%d", (int)code);
            }];
            result(@YES);
            return;
        }
    }
#endif
    result([FlutterError errorWithCode:@"UNSUPPORTED"
                               message:@"shutdown is not exposed by this device's protocol; disconnect instead."
                               details:@{@"model": @(self.connectedModel)}]);
}

// getPermissionState — returns one of:
//   "granted"        — central exists AND is poweredOn
//   "denied"         — CBManagerStateUnauthorized
//   "poweredOff"     — CBManagerStatePoweredOff
//   "unsupported"    — CBManagerStateUnsupported (e.g. simulator)
//   "notDetermined"  — central not yet instantiated OR state unknown/resetting
//
// Useful when consumers want to show a granular "Enable Bluetooth" vs
// "Go to Settings" vs "This device doesn't support BLE" message
// without juggling the raw integer state themselves.
- (void)handleGetPermissionState:(FlutterResult)result {
    NSString *state;
    if (self.central == nil) {
        state = @"notDetermined";
    } else {
        switch (self.central.state) {
            case CBManagerStatePoweredOn:    state = @"granted";       break;
            case CBManagerStateUnauthorized: state = @"denied";        break;
            case CBManagerStatePoweredOff:   state = @"poweredOff";    break;
            case CBManagerStateUnsupported:  state = @"unsupported";   break;
            case CBManagerStateResetting:
            case CBManagerStateUnknown:
            default:                         state = @"notDetermined"; break;
        }
    }
    result(state);
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
    if (m.protocolPath == VTMProtocolPathPC60Fw) {
        // The PC-60FW protocol has no documented factory-reset opcode;
        // the device's reset is a hardware button (long-press power).
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"Factory reset is not exposed by the PC-60FW protocol."
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

    NSString *sdkLabel = @"lepu";
    if (mapping.protocolPath == VTMProtocolPathAirBP)       sdkLabel = @"airbp";
    else if (mapping.protocolPath == VTMProtocolPathPC60Fw) sdkLabel = @"pc60fw";
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

    if (m.protocolPath == VTMProtocolPathPC60Fw) {
        // PC-60FW family oximeters (PF-10AW etc.) also ride Nordic UART
        // (same 6E400001 service as AirBP) but with a totally different
        // 0xAA55-synced + CRC8/MAXIM packet framing on top. VTMProductLib
        // has no support for this profile — `VTMURATUtils` only knows
        // the URAT 0xA5 framing on the proprietary E8FB0001 service and
        // immediately fires `utilDeployFailed` against a PC60Fw device.
        // So we drive the peripheral directly via CoreBluetooth, exactly
        // like the AirBP path, and hand any incoming bytes to our own
        // `drainPC60FwBuffer` reassembler.
        peripheral.delegate = self;
        self.uratUtil       = nil;
        self.o2Util         = nil;
        self.pc60FwRxBuffer = [NSMutableData data];
        [peripheral discoverServices:@[[CBUUID UUIDWithString:kPC60FwServiceUUID]]];
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
        // ── VTMURATDeviceExtension hook ──
        // VTMProductLib 1.5 only knows a small set of device-name
        // prefixes natively (e.g. "PF-10BWS" for FOxi, "O2 S " for
        // WOxi). When a peripheral advertises a related but
        // not-yet-recognised name — most notably the **PF-10AW /
        // PF-10AW1 / PF-10BW / PF-10BW1** finger-clip oximeters,
        // which use the same FOxi GATT profile as PF-10BWS but a
        // different `CBAdvertisementDataLocalNameKey` — the SDK's
        // service-discovery state machine cannot match the
        // peripheral's services and fires `utilDeployFailed:` with
        // an unhelpful "services or characteristics not
        // discoverable" log. Setting `util.extension = self` lets
        // us answer `extensionNamePrefixsWithType:` and feed in the
        // extra prefixes; the SDK then completes deploy normally
        // and `utilDeployCompletion:` fires.
        //
        // MUST be set BEFORE assigning `peripheral` because the SDK
        // reads the extension during the synchronous service-discovery
        // setup triggered by the peripheral assignment.
        util.extension = self;
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
    self.pc60FwTxChar     = nil;
    self.pc60FwRxChar     = nil;
    self.pc60FwRxBuffer   = nil;
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"disconnected",
                      @"reason": error.localizedDescription ?: @"user_initiated"}];
}

#pragma mark - VTMURATDeviceExtension

/// Hand the SDK extra `CBAdvertisementDataLocalNameKey` prefixes for
/// a given device family. VTMProductLib 1.5 ships a hard-coded
/// recogniser that only knows the canonical name for each family
/// (e.g. `"PF-10BWS"` for FOxi, `"O2 S"` for WOxi). When a
/// peripheral advertises a related name that uses the same GATT
/// profile but isn't in the SDK's table, deploy fails with
/// `utilDeployFailed:` and a misleading "services or characteristics
/// not discoverable" log.
///
/// We supplement the SDK's built-in list here, but ONLY for names
/// that genuinely share the SDK family's GATT profile. The older
/// PF-10AW / PF-10AW1 / PF-10BW / PF-10BW1 (Lepu ids 85–88) look
/// like FOxi peers by name but actually use the unrelated PC60FW
/// Nordic-UART profile; those are routed to `VTMProtocolPathPC60Fw`
/// in the device-type mapper and intentionally excluded here.
- (NSArray<NSString *> *)extensionNamePrefixsWithType:(VTMDeviceType)deviceType {
    switch (deviceType) {
        case VTMDeviceTypeFOxi:
            // The SDK natively recognises "PF-10BWS" (id 126). The
            // sibling "PF-10AW_1" (underscore-one, id 123) shares the
            // FOxi GATT profile but isn't in the built-in list, so we
            // register it here. Both upper- and unhyphenated variants
            // are included because the firmware build varies the
            // local-name format across hardware revisions.
            return @[@"PF-10AW_1", @"PF10AW_1", @"PF-10BWS", @"PF10BWS"];
        case VTMDeviceTypeWOxi:
            // O2Ring S advertises as either "O2 S" or "O2RING S"
            // depending on firmware build. The SDK natively only
            // looks for "O2 S "; the no-trailing-space and
            // hyphen-less variants are added here for safety.
            return @[@"O2RING S", @"O2-RING S", @"O2 S", @"O2S"];
        default:
            return nil;
    }
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

    // Mirror the Lepu Android SDK's auto-stream behaviour for device
    // families whose firmware does NOT push real-time samples until
    // the host explicitly asks. On Android, `BleServiceHelper` enables
    // the notify characteristic during its connect routine and the
    // device starts streaming immediately; on iOS, VTMProductLib is a
    // passive wrapper around CoreBluetooth and only sends the "begin
    // streaming" opcode when the app calls the family-specific
    // `*_make*Send:YES` / `*_request*RealData` helper.
    //
    // The home-page pulse-oximeter screen (and any screen that mirrors
    // its UX) deliberately does NOT call `startMeasurement()` after
    // connecting — it expects the device to start pushing as soon as
    // it has a finger inserted, the same way the Android build behaves.
    // Without this auto-start, an iOS PF-10AW completes service
    // discovery, fires `connectionState: connected`, and then sits
    // idle forever because nothing told the device to send samples.
    [self autoStartRealtimeForFamily];
}

/// Issue the family-specific "begin streaming" command immediately
/// after deploy completes for device families whose firmware does
/// not push without it. Currently this covers:
///
///   • `VTMDeviceTypeFOxi`  — newer finger-clip oximeters (PF-10AW_1
///                            id 123 / PF-10BWS id 126). Needs
///                            `foxi_makeInfoSend:YES` for the
///                            per-sample SpO2/PR struct and
///                            `foxi_makeWaveSend:YES` for the PPG
///                            waveform.
///   • `VTMDeviceTypeWOxi`  — wearable oximeters (O2Ring S). Needs
///                            an `observeParameters:waveform:` opt-in
///                            followed by `woxi_requestWOxiRealData`.
///
/// Other families are intentionally left alone:
///   • ECG / BP / Scale / ER3 / MSeries / BabyPatch — their UI
///     screens DO call `startMeasurement()` explicitly and either
///     need to send a measurement-mode command first (BP cuff
///     inflate / ECG enter-measurement) or auto-stream by design
///     once the user starts the cuff. Auto-starting here would
///     bypass the screen's state machine.
///   • Legacy O2Ring (VTO2Communicate) — handled separately in
///     `o2_serviceDeployed:`; the SDK pushes parameters by default.
///   • PC60Fw family (PF-10AW etc., ids 85–88) — handled outside this
///     callback because they don't go through VTMURATUtils at all.
///     The PC60Fw firmware streams the moment the Nordic-UART notify
///     characteristic is enabled (see `didUpdateNotificationStateFor…`
///     for VTMProtocolPathPC60Fw), so no opcode is needed.
- (void)autoStartRealtimeForFamily {
    VTMDeviceMapping *m = self.activeMapping;
    if (m == nil) return;
    switch (m.vtmDeviceType) {
        case VTMDeviceTypeFOxi:
            FBD_LOG(@"auto-start FOxi RT for model=%ld", (long)m.lepuModel);
            [self.uratUtil foxi_makeInfoSend:YES];
            [self.uratUtil foxi_makeWaveSend:YES];
            self.measuring = YES;
            break;
        case VTMDeviceTypeWOxi:
            FBD_LOG(@"auto-start WOxi RT for model=%ld", (long)m.lepuModel);
            [self.uratUtil observeParameters:YES waveform:YES rawdata:NO accdata:NO];
            [self.uratUtil woxi_requestWOxiRealData];
            self.measuring = YES;
            break;
        default:
            break;
    }
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
        [self sendEvent:@{@"event":   @"battery",
                          @"family":  self.activeMapping.family ?: @"unknown",
                          @"model":   @(self.connectedModel),
                          @"state":   @(bi.state),
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
        } else if (!self.pendingReadPaused) {
            [self.uratUtil readFile:(uint32_t)self.pendingReadBuffer.length];
        }
        // When paused we deliberately drop the next-chunk request — the
        // device falls silent until `continueReadFile` re-issues it.
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
        // Stamp the connected peripheral's identity onto the event so
        // downstream Dart can build a `BloodPressureModel` / `EcgModel`
        // with `deviceMac` + `deviceName` populated. Without these the
        // server-side dedup keys collapse and the history page can't
        // group readings by device.
        NSString *mac        = self.activePeripheral.identifier.UUIDString ?: @"";
        NSString *deviceName = self.activePeripheral.name ?: @"";
        [self sendEvent:@{@"event":        @"fileReadComplete",
                          @"deviceFamily": family,
                          @"model":        @(self.connectedModel),
                          @"mac":          mac,
                          @"deviceName":   deviceName,
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
                          @"isLeadOff": ((flag.rMark == 0 && st.curStatus == 0) ? @YES : @NO),
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
        // Response-paced pump: every rt-data frame we deliver to Dart
        // immediately requests the next one. This is what keeps the
        // iOS stream as smooth as Android's push-based LiveEventBus
        // path — without it, the device returns empty packets between
        // the fixed-timer ticks and the Dart UI sees stalls + sticky
        // lead-off. The watchdog will re-issue if no response arrives.
        [self cancelEcgRtWatchdog];
        [self scheduleNextEcgRtRequest];
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
                // VTMBPMeasuringData.pressure is in mmHg*100 per
                // VTMBLEStruct.h (`实时压（mmHg）*100`).
                d[@"pressure"]    = @(mm.pressure / 100.0);
                d[@"pressureRaw"] = @(mm.pressure);
                d[@"pr"]          = @(mm.pulse_rate);
                d[@"isDeflate"]   = ((mm.is_deflating != 0) ? @YES : @NO);
                d[@"isPulse"]     = ((mm.is_get_pulse != 0) ? @YES : @NO);
                break;
            }
            case 1: {
                VTMBPEndMeasureData mr = [VTMBLEParser parseBPEndMeasureData:dataSlice];
                d[@"measureType"] = @"bp_result";
                d[@"sys"]         = @(mr.systolic_pressure);
                d[@"dia"]         = @(mr.diastolic_pressure);
                d[@"mean"]        = @(mr.mean_pressure);
                d[@"pr"]          = @(mr.pulse_rate);
                // VTMBPEndMeasureData has TWO codes (see VTMBLEStruct.h):
                //   `state_code`     状态码    – measurement success/error
                //                              (0 = OK, 1+ = movement /
                //                              cuff-leak / over-pressure /
                //                              weak-pulse / aborted, etc.).
                //   `medical_result` 诊断结果 – BP CLASSIFICATION
                //                              (normal / elevated /
                //                              stage-1 / stage-2 / crisis).
                // Consumers (DoctorsApp blood_pressure_page) treat
                // `result == 0` as success. Emitting `medical_result`
                // there caused every non-normal reading to be rejected
                // as an error (e.g. SYS 118 / DIA 86 → stage-1 → result
                // == 2 → "Measurement unsuccessful"). Always surface the
                // state_code under `result` so the success check works,
                // and forward the classification under `medicalResult`
                // so the UI can still render a category badge later.
                d[@"result"]        = @(mr.state_code);
                d[@"stateCode"]     = @(mr.state_code);
                d[@"medicalResult"] = @(mr.medical_result);
                break;
            }
            case 2: {
                VTMECGMeasuringData em = [VTMBLEParser parseECGMeasuringData:dataSlice];
                d[@"measureType"]  = @"ecg_measuring";
                d[@"hr"]           = @(em.pulse_rate);
                d[@"curDuration"]  = @(em.duration);
                d[@"isLeadOff"]    = (((em.special_status & 0x02) != 0) ? @YES : @NO);
                d[@"isPoolSignal"] = (((em.special_status & 0x01) != 0) ? @YES : @NO);
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
        // VTMRealTimePressure.pressure is in mmHg*100 per VTMBLEStruct.h.
        [self sendEvent:@{@"event":        @"rtData",
                          @"deviceType":   @"bp",
                          @"deviceFamily": family,
                          @"model":        @(self.connectedModel),
                          @"measureType":  @"bp_pressure",
                          @"pressure":     @(p.pressure / 100.0),
                          @"pressureRaw":  @(p.pressure)}];
        return;
    }

    if (cmdType == VTMBPCmdGetConfig) {
        VTMBPConfig cfg = [VTMBLEParser parseBPConfig:response];
        // Cache so `setDeviceConfig` can merge consumer changes on top
        // of the existing snapshot rather than wiping calibration /
        // language / unused fields with zeroes.
        self.cachedBPConfig = [NSValue valueWithBytes:&cfg objCType:@encode(VTMBPConfig)];
        [self sendEvent:@{@"event":          @"deviceConfig",
                          @"family":         family,
                          @"model":          @(self.connectedModel),
                          @"calibZero":      @(cfg.last_calib_zero),
                          @"calibSlope":     @(cfg.calib_slope),
                          @"volume":         @(cfg.volume),
                          @"avgMeasureMode": @(cfg.avg_measure_mode),
                          @"deviceSwitch":   @(cfg.device_switch),
                          @"unit":           @(cfg.unit),
                          @"language":       @(cfg.language),
                          @"timeUtc":        @(cfg.time_utc),
                          @"sleepTicks":     @(cfg.sleep_ticks),
                          @"calibTicks":     @(cfg.calib_ticks),
                          @"targetPressure": @(cfg.bp_test_target_pressure)}];
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
                          @"probeOff":       (((info.status & 0x02) != 0) ? @YES : @NO)}];
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

    // The iComon SDK's CBCentralManager forwards every nearby BLE
    // peripheral it sees, regardless of whether it speaks the iComon
    // protocol. On iOS that surfaces Lepu ECGs (ER1/ER2), heart-rate
    // straps, etc. as ghost "scale" entries because we previously
    // forwarded all results with deviceType="scale". Drop anything
    // whose ICDeviceType is not a scale variant so the host app only
    // sees real iComon scales in the pair list.
    BOOL isScale = (deviceInfo.type == ICDeviceTypeWeightScale ||
                    deviceInfo.type == ICDeviceTypeFatScale ||
                    deviceInfo.type == ICDeviceTypeFatScaleWithTemperature ||
                    deviceInfo.type == ICDeviceTypeBalance);
    if (!isScale) {
        FBD_LOG(@"iComon scan dropped non-scale device name=%@ type=%lu",
                deviceInfo.name ?: @"?", (unsigned long)deviceInfo.type);
        return;
    }

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

// Reflected unit-changes from the device itself (user pressed the
// unit button on the scale, or our setScale*Unit call took effect).
// Emit `scaleUnitChanged` so Dart can update its UI immediately
// without waiting for the next weigh-in.
- (void)onReceiveWeightUnitChanged:(ICDevice *)device
                              unit:(ICWeightUnit)unit {
    [self sendEvent:@{@"event":    @"scaleUnitChanged",
                      @"subEvent": @"weight",
                      @"mac":      device.macAddr ?: @"",
                      @"unit":     @(unit)}];
}

- (void)onReceiveRulerUnitChanged:(ICDevice *)device
                             unit:(ICRulerUnit)unit {
    [self sendEvent:@{@"event":    @"scaleUnitChanged",
                      @"subEvent": @"ruler",
                      @"mac":      device.macAddr ?: @"",
                      @"unit":     @(unit)}];
}

- (void)onReceiveKitchenScaleUnitChanged:(ICDevice *)device
                                    unit:(ICKitchenScaleUnit)unit {
    [self sendEvent:@{@"event":    @"scaleUnitChanged",
                      @"subEvent": @"kitchen",
                      @"mac":      device.macAddr ?: @"",
                      @"unit":     @(unit)}];
}

// The device pushes back its currently-stored user profile (typically
// after a multi-user W-series device finishes identifying which user
// just stepped on it). Forward as `scaleUserInfo`.
- (void)onReceiveUserInfo:(ICDevice *)device userInfo:(ICUserInfo *)userInfo {
    if (device == nil || userInfo == nil) return;
    NSMutableDictionary *evt = [@{@"event":        @"scaleUserInfo",
                                  @"deviceFamily": @"icomon",
                                  @"mac":          device.macAddr ?: @""} mutableCopy];
    [evt addEntriesFromDictionary:[self mapFromIcUserInfo:userInfo]];
    [self sendEvent:evt];
}

- (void)onReceiveUserInfoList:(ICDevice *)device
                    userInfos:(NSArray<ICUserInfo *> *)userInfos {
    if (device == nil) return;
    NSMutableArray<NSDictionary *> *list =
        [NSMutableArray arrayWithCapacity:userInfos.count];
    for (ICUserInfo *u in userInfos) {
        [list addObject:[self mapFromIcUserInfo:u]];
    }
    [self sendEvent:@{@"event":        @"scaleUserList",
                      @"deviceFamily": @"icomon",
                      @"mac":          device.macAddr ?: @"",
                      @"profiles":     list}];
}
#endif  // FBD_HAS_ICOMON

#pragma mark - Nordic UART — CBPeripheralDelegate (AirBP & PC60Fw)
//
// Both `VTMProtocolPathAirBP` (Viatom AirBP / SmartBP) and
// `VTMProtocolPathPC60Fw` (Wellue PC-60FW oximeters: PF-10AW etc.)
// ride the standard Nordic UART Service. We keep them in a single
// CBPeripheralDelegate codepath for service/characteristic discovery
// (the GATT layer is identical) and only branch where the framing
// or downstream handling differs.

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    VTMProtocolPath path = self.activeMapping.protocolPath;
    if (path != VTMProtocolPathAirBP && path != VTMProtocolPathPC60Fw) return;
    NSString *tag = (path == VTMProtocolPathAirBP) ? @"AirBP" : @"PC60Fw";
    if (error) {
        [self cancelConnectionWatchdog];
        FBD_LOG(@"%@ discoverServices failed: %@", tag, error.localizedDescription);
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
    FBD_LOG(@"%@ service %@ not advertised by peripheral", tag, kAirBPServiceUUID);
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"disconnected",
                      @"reason": (path == VTMProtocolPathAirBP)
                          ? @"airbp_service_not_found"
                          : @"pc60fw_service_not_found"}];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    VTMProtocolPath path = self.activeMapping.protocolPath;
    if (path != VTMProtocolPathAirBP && path != VTMProtocolPathPC60Fw) return;
    NSString *tag = (path == VTMProtocolPathAirBP) ? @"AirBP" : @"PC60Fw";
    if (error) {
        [self cancelConnectionWatchdog];
        FBD_LOG(@"%@ discoverCharacteristics failed: %@", tag, error.localizedDescription);
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"disconnected",
                          @"reason": error.localizedDescription ?: @"discover_chars_failed"}];
        return;
    }
    for (CBCharacteristic *ch in service.characteristics) {
        if ([ch.UUID.UUIDString caseInsensitiveCompare:kAirBPTxCharUUID] == NSOrderedSame) {
            if (path == VTMProtocolPathAirBP) {
                self.airBPTxChar = ch;
            } else {
                self.pc60FwTxChar = ch;
            }
        } else if ([ch.UUID.UUIDString caseInsensitiveCompare:kAirBPRxCharUUID] == NSOrderedSame) {
            if (path == VTMProtocolPathAirBP) {
                self.airBPRxChar = ch;
            } else {
                self.pc60FwRxChar = ch;
            }
            [peripheral setNotifyValue:YES forCharacteristic:ch];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    VTMProtocolPath path = self.activeMapping.protocolPath;
    if (path != VTMProtocolPathAirBP && path != VTMProtocolPathPC60Fw) return;
    if ([characteristic.UUID.UUIDString caseInsensitiveCompare:kAirBPRxCharUUID] != NSOrderedSame) return;
    NSString *tag = (path == VTMProtocolPathAirBP) ? @"AirBP" : @"PC60Fw";
    if (error) {
        [self cancelConnectionWatchdog];
        FBD_LOG(@"%@ subscribe failed: %@", tag, error.localizedDescription);
        [self sendEvent:@{@"event": @"connectionState",
                          @"state": @"disconnected",
                          @"reason": error.localizedDescription ?: @"subscribe_failed"}];
        return;
    }
    if (!characteristic.isNotifying) return;
    [self cancelConnectionWatchdog];
    self.serviceDeployed = YES;
    self.connectedModel  = self.activeMapping.lepuModel;
    NSString *defaultFamily   = (path == VTMProtocolPathAirBP) ? @"airbp"    : @"pc60fw";
    NSString *defaultDevType  = (path == VTMProtocolPathAirBP) ? @"bp"       : @"oximeter";
    NSString *sdkLabel        = (path == VTMProtocolPathAirBP) ? @"airbp"    : @"pc60fw";
    FBD_LOG(@"%@ deploy complete model=%ld", tag, (long)self.connectedModel);
    [self sendEvent:@{@"event": @"connectionState",
                      @"state": @"connected",
                      @"model": @(self.connectedModel),
                      @"family": self.activeMapping.family ?: defaultFamily,
                      @"deviceType": self.activeMapping.deviceType ?: defaultDevType,
                      @"sdk": sdkLabel}];
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    VTMProtocolPath path = self.activeMapping.protocolPath;
    if (path != VTMProtocolPathAirBP && path != VTMProtocolPathPC60Fw) return;
    if (error || characteristic.value.length == 0) return;
    if ([characteristic.UUID.UUIDString caseInsensitiveCompare:kAirBPRxCharUUID] != NSOrderedSame) return;

    if (path == VTMProtocolPathAirBP) {
        [self.airBPRxBuffer appendData:characteristic.value];
        [self drainAirBPBuffer];
    } else {
        [self.pc60FwRxBuffer appendData:characteristic.value];
        [self drainPC60FwBuffer];
    }
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

#pragma mark - PC60Fw — helpers (Wellue PF-10AW family)
//
// PC-60FW packet framing — the only public reference is
// github.com/sza2/viatom_pc60fw which captured the protocol from a
// Wellue PC-60FW oximeter (same firmware family as PF-10AW). The
// device pushes frames over the Nordic UART notify characteristic
// with no app-side opcode required:
//
//   ┌─────┬─────┬───────┬────────┬───────────┬──────┐
//   │ AA  │ 55  │ HDR   │ LEN    │ PAYLOAD   │ CRC  │
//   ├─────┼─────┼───────┼────────┼───────────┼──────┤
//   │  1B │ 1B  │  1B   │  1B    │ LEN-1 B   │  1B  │
//   └─────┴─────┴───────┴────────┴───────────┴──────┘
//             ^         ^        ^                  ^
//             |         |        |                  |
//             |         |        +--- payload[0] = func code
//             |         +--- length INCLUDING trailing CRC
//             +--- 0x0F (data frames) or 0xF0 (metadata)
//
// CRC8/MAXIM (poly 0x31 reflected = 0x8C, init 0x00, no final XOR).
// For a valid frame, CRC over the entire packet (including the CRC
// byte) equals 0 — the standard "tag-check" form.
//
// Function codes observed:
//   0x01 (HDR=0x0F) — SpO2 / PR / PI numerical sample (~1 Hz)
//                     payload: [func, SpO2, PR, ?, ?, PI*10, ?, ?]
//   0x02 (HDR=0x0F) — pulse waveform (5 samples per packet, ~60 Hz)
//                     payload: [func, w1, w2, w3, w4, w5]
//                     One sample per cycle has bit 7 set (subtract
//                     0x80 to fit into the 0..0x7F PPG range).
//   0x03 (HDR=0xF0) — unknown 1-byte heartbeat — ignored.
//   0x21 (HDR=0x0F) — unknown — ignored.

static uint8_t fbd_crc8_maxim(const uint8_t *data, NSUInteger len) {
    // CRC-8/MAXIM (a.k.a. Dallas/1-Wire). Reflected poly 0x8C.
    uint8_t crc = 0x00;
    for (NSUInteger i = 0; i < len; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++) {
            crc = (crc & 0x01) ? (uint8_t)((crc >> 1) ^ 0x8C) : (uint8_t)(crc >> 1);
        }
    }
    return crc;
}

/// Drain the rolling RX buffer, emitting one event per well-formed
/// frame. Partial frames at the tail stay in the buffer for the next
/// notification. Sync re-acquisition discards bytes up to the next
/// `0xAA` so a CRC failure or a stray byte doesn't desynchronise the
/// stream forever.
- (void)drainPC60FwBuffer {
    while (self.pc60FwRxBuffer.length >= 4) {     // need at least sync+hdr+len
        const uint8_t *p = self.pc60FwRxBuffer.bytes;
        // Resynchronise on the 0xAA 0x55 sync word.
        if (p[0] != 0xAA || p[1] != 0x55) {
            // Hunt for the next 0xAA. If absent, drop the buffer.
            NSRange hdr = [self.pc60FwRxBuffer rangeOfData:[NSData dataWithBytes:"\xAA" length:1]
                                                  options:0
                                                    range:NSMakeRange(1, self.pc60FwRxBuffer.length - 1)];
            if (hdr.location == NSNotFound) {
                [self.pc60FwRxBuffer setLength:0];
                return;
            }
            [self.pc60FwRxBuffer replaceBytesInRange:NSMakeRange(0, hdr.location)
                                            withBytes:NULL length:0];
            continue;
        }
        // p[2] = header (0x0F or 0xF0); p[3] = length (payload+CRC)
        uint8_t header  = p[2];
        uint8_t length  = p[3];
        NSUInteger frameLen = 4 + length;
        if (self.pc60FwRxBuffer.length < frameLen) return;  // need more bytes

        // Full frame in hand — verify CRC8/MAXIM over the entire frame.
        // For a valid frame the trailing CRC byte makes the running
        // CRC fold back to zero.
        if (fbd_crc8_maxim(p, frameLen) != 0) {
            // Drop just the leading sync byte and re-hunt — keeps us
            // in lock-step even if a single bit-flip corrupted one
            // packet.
            [self.pc60FwRxBuffer replaceBytesInRange:NSMakeRange(0, 1)
                                            withBytes:NULL length:0];
            continue;
        }
        if (length < 2) {
            // Pathological: length too small to even contain a func + CRC.
            [self.pc60FwRxBuffer replaceBytesInRange:NSMakeRange(0, frameLen)
                                            withBytes:NULL length:0];
            continue;
        }
        // Slice out payload (excludes trailing CRC).
        NSData *payload = [self.pc60FwRxBuffer subdataWithRange:NSMakeRange(4, length - 1)];
        [self.pc60FwRxBuffer replaceBytesInRange:NSMakeRange(0, frameLen)
                                        withBytes:NULL length:0];
        [self handlePC60FwFrameHeader:header payload:payload];
    }
}

- (void)handlePC60FwFrameHeader:(uint8_t)header payload:(NSData *)payload {
    if (payload.length < 1) return;
    const uint8_t *p = payload.bytes;
    uint8_t func = p[0];
    NSString *mac = self.activePeripheral.identifier.UUIDString ?: @"";
    NSString *fam = self.activeMapping.family ?: @"pc60fw";

    switch (func) {
        case 0x01: {
            // Numerical SpO2/PR/PI sample. Layout (after func byte):
            //   payload[1] = SpO2  (0..100, 0xFF = invalid / probe off)
            //   payload[2] = PR    (0..250, 0xFF = invalid)
            //   payload[3] = unknown / status flags
            //   payload[4] = PI * 10 (so 0x50 → 8.0, 0xFF = invalid)
            //   payload[5] = unknown
            //   payload[6] = unknown
            // We need at least 5 bytes (func + spo2 + pr + ? + pi).
            if (payload.length < 5) return;
            uint8_t spo2Raw = p[1];
            uint8_t prRaw   = p[2];
            uint8_t piRaw   = p[4];

            // The Wellue firmware uses 0xFF as the "invalid" sentinel
            // (probe off, finger out of clip, sensor losing pulse).
            // Mirror the Lepu Android `RtParam` semantics by surfacing
            // a NaN-sentinel of -1 so the Dart layer's existing
            // probe-off heuristic (`spo2 < 50`) keeps working without
            // changes. PI gets 0.0 since negative PI is meaningless.
            BOOL probeOff = (spo2Raw == 0xFF) || (prRaw == 0xFF);
            BOOL pulseSearching = !probeOff && (spo2Raw == 0x7F || prRaw == 0x7F);
            int spo2 = probeOff ? -1 : (int)spo2Raw;
            int pr   = probeOff ? -1 : (int)prRaw;
            float pi = (piRaw == 0xFF) ? 0.0f : (piRaw / 10.0f);

            [self sendEvent:@{@"event":            @"rtData",
                              @"deviceType":       @"oximeter",
                              @"deviceFamily":     fam,
                              @"sdk":              @"pc60fw",
                              @"mac":              mac,
                              @"model":            @(self.connectedModel),
                              @"spo2":             @(spo2),
                              @"pr":               @(pr),
                              @"pi":               @(pi),
                              @"isProbeOff":       @(probeOff),
                              @"isPulseSearching": @(pulseSearching)}];
            break;
        }
        case 0x02: {
            // Pulse waveform — payload is `func` + N waveform samples.
            // Each sample is in the 0..0x7F PPG range; ONE sample per
            // pulse cycle (the third sample after the peak) has its
            // top bit set as a "spike marker". We fold spikes back
            // into range by clearing bit 7 — matches the Python
            // reference implementation (sza2/viatom_pc60fw README).
            if (payload.length < 2) return;
            NSMutableArray<NSNumber *> *samples = [NSMutableArray arrayWithCapacity:payload.length - 1];
            for (NSUInteger i = 1; i < payload.length; i++) {
                uint8_t s = p[i] & 0x7F;
                [samples addObject:@(s)];
            }
            [self sendEvent:@{@"event":        @"rtWaveform",
                              @"deviceType":   @"oximeter",
                              @"deviceFamily": fam,
                              @"sdk":          @"pc60fw",
                              @"mac":          mac,
                              @"model":        @(self.connectedModel),
                              @"waveData":     samples}];
            break;
        }
        default: {
            // Surface unknown frames as `raw` so future protocol
            // additions are visible to the Dart layer without
            // requiring an iOS plugin update first.
            [self sendEvent:@{@"event":   @"raw",
                              @"sdk":     @"pc60fw",
                              @"mac":     mac,
                              @"header":  @(header),
                              @"cmdType": @(func),
                              @"data":    [payload base64EncodedStringWithOptions:0]}];
            break;
        }
    }
}

@end
