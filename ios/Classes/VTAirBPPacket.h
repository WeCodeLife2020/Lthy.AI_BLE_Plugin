//
//  VTAirBPPacket.h
//  lthy_ble_plugin
//
//  Standalone builder/parser for Viatom AirBP / SmartBP blood-pressure
//  monitors. This protocol is NOT covered by VTProductLib, so we implement
//  it directly. It is a plain 0xA5-header UART protocol over Nordic UART
//  (service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E).
//
//  Packet format (9 bytes + payload):
//
//      byte 0 : 0xA5  (header)
//      byte 1 : 0x00  (reserved)
//      byte 2 : seq
//      byte 3 : cmd
//      byte 4..5 : payload length (little-endian uint16)
//      byte 6..7 : reserved (0x00 0x00)
//      byte 8..N-2 : payload bytes (may be absent when length==0)
//      byte N-1 : CRC-8 over bytes 0..N-2
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, VTAirBPCmd) {
    VTAirBPCmdGetInfo            = 0xE1,
    VTAirBPCmdGetBattery         = 0xE4,
    VTAirBPCmdStartMeasure       = 0x04,
    VTAirBPCmdStopMeasure        = 0x05,
    VTAirBPCmdRunningStatus      = 0x06,
    VTAirBPCmdMeasureResult      = 0x07,
    VTAirBPCmdEngineeringStart   = 0x08,
};

@interface VTAirBPPacket : NSObject

/// Build a command packet with an optional payload.
+ (NSData *)buildCommand:(uint8_t)cmd payload:(nullable NSData *)payload;

/// Parse a response frame: validates 0xA5 header + CRC, and on success returns
/// the inner payload bytes (skipping the 8-byte header and the trailing CRC).
/// On failure returns nil and fills *outCmd/*outOk with zero.
+ (nullable NSData *)parseFrame:(NSData *)frame cmd:(nullable uint8_t *)outCmd;

/// CRC-8 (polynomial 0x07, init 0x00) as used by the Viatom UART family.
+ (uint8_t)crc8:(const uint8_t *)buf length:(NSUInteger)len;

@end

NS_ASSUME_NONNULL_END
