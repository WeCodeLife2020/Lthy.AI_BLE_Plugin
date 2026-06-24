//
//  VTMDeviceTypeMapper.m
//  lthy_ble_plugin
//

#import "VTMDeviceTypeMapper.h"

#pragma mark - Android-compatible Lepu model ids
// These constants MUST match `com.lepu.blepro.objs.Bluetooth.MODEL_*` in the
// Android Lepu SDK so the Dart layer can treat both platforms uniformly.
// Values were dumped from `lepu-blepro-1.2.0.aar` (see README for procedure).
static const NSInteger kModelER1       = 7;    // MODEL_ER1
static const NSInteger kModelER1N      = 16;   // MODEL_ER1_N
static const NSInteger kModelER1S_Old  = 127;  // MODEL_ER1S (legacy no-underscore)
static const NSInteger kModelER1S      = 145;  // MODEL_ER1_S (current)
static const NSInteger kModelER1H      = 146;  // MODEL_ER1_H
static const NSInteger kModelER1W      = 147;  // MODEL_ER1_W
static const NSInteger kModelER1L      = 148;  // MODEL_ER1_L  (ER1-LW shares this id)
static const NSInteger kModelER2       = 33;   // MODEL_ER2
static const NSInteger kModelDuoEK     = 8;    // MODEL_DUOEK
static const NSInteger kModelER2S      = 149;  // MODEL_ER2_S
static const NSInteger kModelBP2       = 19;   // MODEL_BP2
static const NSInteger kModelBP2A      = 23;   // MODEL_BP2A
static const NSInteger kModelBP2T      = 31;   // MODEL_BP2T
static const NSInteger kModelBP2W      = 32;   // MODEL_BP2W
static const NSInteger kModelBP3A      = 118;  // MODEL_BP3A
static const NSInteger kModelBP3B      = 119;  // MODEL_BP3B
static const NSInteger kModelBP3C      = 155;  // MODEL_BP3C
static const NSInteger kModelO2Ring    = 4;    // MODEL_O2RING
static const NSInteger kModelO2M       = 25;   // MODEL_O2M
static const NSInteger kModelBabyO2    = 13;   // MODEL_BABYO2
static const NSInteger kModelCheckO2   = 1;    // MODEL_CHECKO2
static const NSInteger kModelSleepO2   = 3;    // MODEL_SLEEPO2
static const NSInteger kModelSnoreO2   = 2;    // MODEL_SNOREO2
static const NSInteger kModelSleepU    = 6;    // MODEL_SLEEPU
static const NSInteger kModelOxyLink   = 10;   // MODEL_OXYLINK
static const NSInteger kModelKidsO2    = 11;   // MODEL_KIDSO2
static const NSInteger kModelOxyfit    = 20;   // MODEL_OXYFIT
static const NSInteger kModelOxyRing   = 63;   // MODEL_OXYRING
static const NSInteger kModelBBSMS1    = 64;   // MODEL_BBSM_S1
static const NSInteger kModelBBSMS2    = 65;   // MODEL_BBSM_S2
static const NSInteger kModelO2RingS   = 124;  // MODEL_O2RING_S
static const NSInteger kModelPF10AW    = 85;   // MODEL_PF_10AW
static const NSInteger kModelPF10AW1   = 86;   // MODEL_PF_10AW1
static const NSInteger kModelPF10AW_1  = 123;  // MODEL_PF_10AW_1
static const NSInteger kModelPF10BW    = 87;   // MODEL_PF_10BW
static const NSInteger kModelPF10BW1   = 88;   // MODEL_PF_10BW1
static const NSInteger kModelPF10BWS   = 126;  // MODEL_PF_10BWS
static const NSInteger kModelER3       = 95;   // MODEL_ER3
static const NSInteger kModelM12       = 152;  // MODEL_M12
static const NSInteger kModelS1Scale   = 8888; // Viatom S1 scale — not in Lepu SDK
static const NSInteger kModelBBSMBS1   = 185;  // MODEL_BBSM_BS1 (baby patch)
static const NSInteger kModelAirBP     = 153;  // MODEL_AIRBP
static const NSInteger kModelF4Scale   = 47;   // MODEL_F4_SCALE (iComon path)

@implementation VTMDeviceMapping
@end

@implementation VTMDeviceTypeMapper

+ (nullable VTMDeviceMapping *)mappingForAdvertisedName:(nullable NSString *)name {
    if (name.length == 0) return nil;
    NSString *n = [name lowercaseString];

    // ── ECG — ER1 / ER1S / ER1-N / VBeat / ER1H / ER1W / ER1L / ER1-LW ──
    // NB: VBeat is the consumer rebrand of ER1 (shares MODEL_ER1).
    if ([n hasPrefix:@"vbeat"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1 family:@"er1" type:@"ecg"];
    }
    if ([n hasPrefix:@"er1n"] || [n hasPrefix:@"er1-n"] || [n hasPrefix:@"er1_n"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1N family:@"er1" type:@"ecg"];
    }
    if ([n hasPrefix:@"er1-s"]) {
        // Newer "ER1-S" → MODEL_ER1_S (145).
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1S family:@"er1" type:@"ecg"];
    }
    if ([n hasPrefix:@"er1s"]) {
        // Older "ER1S" (no dash) → MODEL_ER1S (127).
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1S_Old family:@"er1" type:@"ecg"];
    }
    if ([n hasPrefix:@"er1h"] || [n hasPrefix:@"er1-h"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1H family:@"er1" type:@"ecg"];
    }
    // ER1-LW / ER1LW are consumer names for ER1-L with WiFi — the Lepu SDK
    // treats them as MODEL_ER1_L; check them BEFORE plain ER1-W so the "w"
    // tail isn't consumed by the W branch.
    if ([n hasPrefix:@"er1-lw"] || [n hasPrefix:@"er1lw"] || [n hasPrefix:@"er1_lw"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1L family:@"er1" type:@"ecg"];
    }
    if ([n hasPrefix:@"er1w"] || [n hasPrefix:@"er1-w"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1W family:@"er1" type:@"ecg"];
    }
    if ([n hasPrefix:@"er1l"] || [n hasPrefix:@"er1-l"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1L family:@"er1" type:@"ecg"];
    }
    if ([n hasPrefix:@"er1"] || [n hasPrefix:@"hhm"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER1 family:@"er1" type:@"ecg"];
    }

    // ── ECG — ER2 / ER2-S / DuoEK ───────────────────────────────────────
    if ([n hasPrefix:@"duo"] || [n hasPrefix:@"duoek"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelDuoEK family:@"er2" type:@"ecg"];
    }
    // ER2-S must be checked BEFORE ER2 — otherwise "er2-s" / "er2s" gets
    // swallowed by the generic ER2 branch.
    if ([n hasPrefix:@"er2s"] || [n hasPrefix:@"er2-s"] || [n hasPrefix:@"er2_s"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER2S family:@"er2" type:@"ecg"];
    }
    if ([n hasPrefix:@"er2"]) {
        return [self buildUrat:VTMDeviceTypeECG model:kModelER2 family:@"er2" type:@"ecg"];
    }

    // ── ECG — ER3 / M-series (Lepod Pro) ───────────────────────────────
    if ([n hasPrefix:@"lepod"] || [n hasPrefix:@"lpm"]) {
        return [self buildUrat:VTMDeviceTypeER3 model:kModelER3 family:@"er3" type:@"ecg"];
    }
    if ([n hasPrefix:@"m12"] || [n hasPrefix:@"m5"] ||
        [n hasPrefix:@"m-12"] || [n hasPrefix:@"m-5"]) {
        return [self buildUrat:VTMDeviceTypeMSeries model:kModelM12 family:@"mseries" type:@"ecg"];
    }

    // ── BP — BP2 family / BP3 family ────────────────────────────────────
    if ([n hasPrefix:@"bp2a"]) {
        return [self buildUrat:VTMDeviceTypeBP model:kModelBP2A family:@"bp2" type:@"bp"];
    }
    if ([n hasPrefix:@"bp2t"]) {
        return [self buildUrat:VTMDeviceTypeBP model:kModelBP2T family:@"bp2" type:@"bp"];
    }
    if ([n hasPrefix:@"bp2w"]) {
        return [self buildUrat:VTMDeviceTypeBP model:kModelBP2W family:@"bp2" type:@"bp"];
    }
    if ([n hasPrefix:@"bp2"]) {
        return [self buildUrat:VTMDeviceTypeBP model:kModelBP2 family:@"bp2" type:@"bp"];
    }
    if ([n hasPrefix:@"bp3a"]) {
        return [self buildUrat:VTMDeviceTypeBP model:kModelBP3A family:@"bp3" type:@"bp"];
    }
    if ([n hasPrefix:@"bp3b"]) {
        return [self buildUrat:VTMDeviceTypeBP model:kModelBP3B family:@"bp3" type:@"bp"];
    }
    if ([n hasPrefix:@"bp3"]) {
        return [self buildUrat:VTMDeviceTypeBP model:kModelBP3C family:@"bp3" type:@"bp"];
    }

    // ── Wearable Oximeter — O2Ring S ────────────────────────────────────
    if ([n containsString:@"o2ring s"] || [n hasPrefix:@"o2s"]) {
        return [self buildUrat:VTMDeviceTypeWOxi model:kModelO2RingS family:@"woxi" type:@"oximeter"];
    }

    // ── Finger Oximeter — PF-10 family ──────────────────────────────────
    // The PF-10 lineup splits across TWO incompatible GATT profiles:
    //
    //   • PC60FW family   — PF-10AW / PF-10AW1 / PF-10BW / PF-10BW1
    //     (Lepu ids 85/86/87/88). Older 0xA5-incompatible profile that
    //     advertises the Nordic UART service (6E400001) with a custom
    //     0xAA55-sync + CRC8/MAXIM framing. NOT supported by VTMProductLib
    //     (no `VTMDeviceTypePC60Fw` exists) — must be driven directly via
    //     CoreBluetooth, mirroring the Lepu Android SDK's PC60Fw path.
    //
    //   • FOxi family     — PF-10AW_1 (underscore-one, id 123) and
    //     PF-10BWS (id 126). Newer URAT/0xA5-framed profile that the
    //     VTMProductLib SDK natively understands via `VTMDeviceTypeFOxi`
    //     and `VTMURATUtils foxi_*` helpers.
    //
    // Order matters: check longer/more-specific suffixes first so that
    // e.g. "PF-10AW1" (PC60Fw, id 86) doesn't get eaten by the bare
    // "pf-10aw" rule (PC60Fw, id 85). "PF-10AW_1" (FOxi, id 123) MUST be
    // checked before "PF-10AW1" because lowercase normalisation does NOT
    // remove the underscore but `hasPrefix:` will happily match the
    // prefix without it.
    if ([n hasPrefix:@"pf-10bws"] || [n hasPrefix:@"pf10bws"]) {
        return [self buildUrat:VTMDeviceTypeFOxi model:kModelPF10BWS family:@"foxi" type:@"oximeter"];
    }
    if ([n hasPrefix:@"pf-10bw1"] || [n hasPrefix:@"pf10bw1"]) {
        return [self buildPC60Fw:kModelPF10BW1 family:@"pc60fw"];
    }
    if ([n hasPrefix:@"pf-10bw"] || [n hasPrefix:@"pf10bw"]) {
        return [self buildPC60Fw:kModelPF10BW family:@"pc60fw"];
    }
    if ([n hasPrefix:@"pf-10aw_1"] || [n hasPrefix:@"pf10aw_1"]) {
        return [self buildUrat:VTMDeviceTypeFOxi model:kModelPF10AW_1 family:@"foxi" type:@"oximeter"];
    }
    if ([n hasPrefix:@"pf-10aw1"] || [n hasPrefix:@"pf10aw1"]) {
        return [self buildPC60Fw:kModelPF10AW1 family:@"pc60fw"];
    }
    if ([n hasPrefix:@"pf-10aw"] || [n hasPrefix:@"pf10aw"]) {
        return [self buildPC60Fw:kModelPF10AW family:@"pc60fw"];
    }
    // Legacy / generic fallback — bare "PF-10" with no AW/BW suffix is
    // almost always the older PC60Fw-protocol device (the newer PF-10BWS
    // never appears without its "BWS" suffix). Route to PC60Fw with the
    // PF-10AW model id so the Dart layer sees a sensible default.
    if ([n hasPrefix:@"pf-10"] || [n hasPrefix:@"pf10"]) {
        return [self buildPC60Fw:kModelPF10AW family:@"pc60fw"];
    }

    // ── Baby patch — BBSM P1 ────────────────────────────────────────────
    if ([n hasPrefix:@"bbsm-p"] || [n hasPrefix:@"bbsmp"]) {
        return [self buildUrat:VTMDeviceTypeBabyPatch model:kModelBBSMBS1 family:@"baby" type:@"baby"];
    }

    // ── Legacy 0xAA O2Ring family (Checkme O2 / SleepO2 / SleepU / etc.) ─
    if ([n hasPrefix:@"o2ring"]) {
        return [self buildO2Legacy:kModelO2Ring family:@"oxy"];
    }
    if ([n hasPrefix:@"o2m"]) {
        return [self buildO2Legacy:kModelO2M family:@"oxy"];
    }
    if ([n hasPrefix:@"babyo2"] || [n hasPrefix:@"baby_o2"] || [n hasPrefix:@"baby-o2"]) {
        return [self buildO2Legacy:kModelBabyO2 family:@"oxy"];
    }
    if ([n hasPrefix:@"checko2"] || [n hasPrefix:@"checkme o2"] || [n hasPrefix:@"checkmeo2"]) {
        return [self buildO2Legacy:kModelCheckO2 family:@"oxy"];
    }
    if ([n hasPrefix:@"sleepo2"] || [n hasPrefix:@"sleep-o2"]) {
        return [self buildO2Legacy:kModelSleepO2 family:@"oxy"];
    }
    if ([n hasPrefix:@"snoreo2"]) {
        return [self buildO2Legacy:kModelSnoreO2 family:@"oxy"];
    }
    if ([n hasPrefix:@"sleepu"]) {
        return [self buildO2Legacy:kModelSleepU family:@"oxy"];
    }
    if ([n hasPrefix:@"oxylink"]) {
        return [self buildO2Legacy:kModelOxyLink family:@"oxy"];
    }
    if ([n hasPrefix:@"kidso2"]) {
        return [self buildO2Legacy:kModelKidsO2 family:@"oxy"];
    }
    if ([n hasPrefix:@"oxyfit"]) {
        return [self buildO2Legacy:kModelOxyfit family:@"oxy"];
    }
    if ([n hasPrefix:@"oxyring"]) {
        return [self buildO2Legacy:kModelOxyRing family:@"oxy"];
    }
    if ([n hasPrefix:@"bbsm-s1"] || [n hasPrefix:@"bbsms1"]) {
        return [self buildO2Legacy:kModelBBSMS1 family:@"oxy"];
    }
    if ([n hasPrefix:@"bbsm-s2"] || [n hasPrefix:@"bbsms2"]) {
        return [self buildO2Legacy:kModelBBSMS2 family:@"oxy"];
    }

    // ── Scale — S1 ─────────────────────────────────────────────────────
    if ([n hasPrefix:@"s1 "] || [n isEqualToString:@"s1"] || [n hasPrefix:@"viatom s1"]) {
        return [self buildUrat:VTMDeviceTypeScale model:kModelS1Scale family:@"scale" type:@"scale"];
    }

    // ── Viatom AirBP / SmartBP (standalone UART protocol) ─────────────
    if ([n hasPrefix:@"airbp"] || [n hasPrefix:@"smartbp"]) {
        return [self buildAirBP:kModelAirBP];
    }

    return nil;
}

+ (nullable VTMDeviceMapping *)mappingForLepuModel:(NSInteger)model {
    switch (model) {
        case kModelER1: case kModelER1N:
        case kModelER1S_Old: case kModelER1S:
        case kModelER1H: case kModelER1W: case kModelER1L:
            return [self buildUrat:VTMDeviceTypeECG model:model family:@"er1" type:@"ecg"];
        case kModelER2: case kModelDuoEK: case kModelER2S:
            return [self buildUrat:VTMDeviceTypeECG model:model family:@"er2" type:@"ecg"];
        case kModelER3:
            return [self buildUrat:VTMDeviceTypeER3 model:model family:@"er3" type:@"ecg"];
        case kModelM12:
            return [self buildUrat:VTMDeviceTypeMSeries model:model family:@"mseries" type:@"ecg"];
        case kModelBP2: case kModelBP2A: case kModelBP2T: case kModelBP2W:
            return [self buildUrat:VTMDeviceTypeBP model:model family:@"bp2" type:@"bp"];
        case kModelBP3A: case kModelBP3B: case kModelBP3C:
            return [self buildUrat:VTMDeviceTypeBP model:model family:@"bp3" type:@"bp"];
        case kModelO2RingS:
            return [self buildUrat:VTMDeviceTypeWOxi model:model family:@"woxi" type:@"oximeter"];
        case kModelPF10AW_1: case kModelPF10BWS:
            // Newer FOxi family — handled by VTMURATUtils foxi_* helpers.
            return [self buildUrat:VTMDeviceTypeFOxi model:model family:@"foxi" type:@"oximeter"];
        case kModelPF10AW: case kModelPF10AW1:
        case kModelPF10BW: case kModelPF10BW1:
            // Older PC60Fw family — direct CoreBluetooth via Nordic UART.
            return [self buildPC60Fw:model family:@"pc60fw"];
        case kModelS1Scale:
            return [self buildUrat:VTMDeviceTypeScale model:model family:@"scale" type:@"scale"];
        case kModelBBSMBS1:
            return [self buildUrat:VTMDeviceTypeBabyPatch model:model family:@"baby" type:@"baby"];
        case kModelO2Ring: case kModelO2M: case kModelBabyO2:
        case kModelCheckO2: case kModelSleepO2: case kModelSnoreO2:
        case kModelSleepU: case kModelOxyLink: case kModelKidsO2:
        case kModelOxyfit: case kModelOxyRing: case kModelBBSMS1:
        case kModelBBSMS2:
            return [self buildO2Legacy:model family:@"oxy"];
        case kModelAirBP:
            return [self buildAirBP:model];
        case kModelF4Scale:
            // LESCALE F4 isn't driven by VTProductLib — on iOS it's routed
            // through the LescaleController on the Dart side (flutter_blue_plus),
            // so this branch is only useful when Android code round-trips the
            // id to the Dart layer.
            return [self buildIComon:model family:@"icomon"];
        default:
            return nil;
    }
}

#pragma mark - Private builders

+ (VTMDeviceMapping *)buildUrat:(VTMDeviceType)type
                          model:(NSInteger)model
                         family:(NSString *)family
                           type:(NSString *)deviceType {
    VTMDeviceMapping *m = [VTMDeviceMapping new];
    m.vtmDeviceType = type;
    m.lepuModel     = model;
    m.protocolPath  = VTMProtocolPathURAT;
    m.family        = family;
    m.deviceType    = deviceType;
    return m;
}

+ (VTMDeviceMapping *)buildO2Legacy:(NSInteger)model family:(NSString *)family {
    VTMDeviceMapping *m = [VTMDeviceMapping new];
    m.vtmDeviceType = VTMDeviceTypeUnknown;
    m.lepuModel     = model;
    m.protocolPath  = VTMProtocolPathO2Legacy;
    m.family        = family;
    m.deviceType    = @"oximeter";
    return m;
}

+ (VTMDeviceMapping *)buildAirBP:(NSInteger)model {
    VTMDeviceMapping *m = [VTMDeviceMapping new];
    m.vtmDeviceType = VTMDeviceTypeUnknown;
    m.lepuModel     = model;
    m.protocolPath  = VTMProtocolPathAirBP;
    m.family        = @"airbp";
    m.deviceType    = @"bp";
    return m;
}

+ (VTMDeviceMapping *)buildPC60Fw:(NSInteger)model family:(NSString *)family {
    VTMDeviceMapping *m = [VTMDeviceMapping new];
    m.vtmDeviceType = VTMDeviceTypeUnknown;  // not represented in VTMProductLib
    m.lepuModel     = model;
    m.protocolPath  = VTMProtocolPathPC60Fw;
    m.family        = family;
    m.deviceType    = @"oximeter";
    return m;
}

+ (VTMDeviceMapping *)buildIComon:(NSInteger)model family:(NSString *)family {
    VTMDeviceMapping *m = [VTMDeviceMapping new];
    m.vtmDeviceType = VTMDeviceTypeScale;
    m.lepuModel     = model;
    m.protocolPath  = VTMProtocolPathIComon;
    m.family        = family;
    m.deviceType    = @"scale";
    return m;
}

@end
