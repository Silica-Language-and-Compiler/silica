/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

/* The Fifi wrapper under the hosted (:ble_gatt) carrier on macOS (transport_serialization_design.md
   §6.3, transport_ble_plan.md stage 3): CoreBluetooth in the shape of compiler/stdlib/net/silica_sockets.c. Objective-C,
   built with Apple's clang and -fobjc-arc, linked with -framework CoreBluetooth -framework Foundation.

   A session is one GATT link in one role. Its manager delivers callbacks on a private serial dispatch
   queue; every wrapper call is bounded by a timeout in milliseconds and waits on a condition the
   callbacks signal, so the carrier actor polls between its mailbox messages as the other hosted
   carriers do. The program needs no main run loop.

   Result conventions (as silica_sockets.c): { tag, value, error_code } with tag 0 = ok, 1 = error,
   2 = timeout, 3 = link down. Error codes: 1 no free session, 2 bad role, 3 no such session, 4 segment
   empty or longer than the link's mtu, 5 the peer refused the write, 6 bad UUID text, and for
   silica_ble_open 1000 + CBManagerState (1002 unsupported, 1003 unauthorized, 1004 powered off).

   Roles: 0 central (scans for the service, connects, subscribes), 1 peripheral (publishes and
   advertises the service, waits for a subscriber).

   Service. One service with one characteristic toward each side. The UUID given at open names the
   service: 4, 8 or 36 characters of the usual hexadecimal text, or empty for the Nordic UART Service.
     peripheral: the characteristic the central writes ("rx") is the service UUID plus 1 in its first
                 group and the one the peripheral indicates on ("tx") is the service UUID plus 2, the
                 pattern of the Nordic UART Service (6E400001, 6E400002, 6E400003). rx is Write (with
                 response) only; tx is Indicate only: both directions are acknowledged, which is what
                 makes the carrier :reliable_ordered.
     central:    the characteristics are found by their properties, not by UUID: the first that can be
                 written is rx (with response when the peer offers it), the first that indicates or
                 notifies is tx. A peer that only notifies, or only takes writes without response, is
                 accepted, and that direction is then not acknowledged.

   The link is up for a central when it has subscribed to tx and found rx; for a peripheral when a
   central has subscribed to tx. A peripheral learns that its central went away only by the
   unsubscription, so that ends the link. */

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct silica_ble_tagged {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_ble_tagged;

typedef struct silica_ble_bytes {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} silica_ble_bytes;

static NSString *const kDefaultService = @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E";

/* The phase a caller sees: 3, 4 and 5 are the three ways a link is down. */
enum { PHASE_STARTING = 0, PHASE_SEEKING = 1, PHASE_UP = 2, PHASE_CLOSED = 3, PHASE_TIMEOUT = 4, PHASE_FAULT = 5 };

#define SILICA_BLE_BUF 1024
#define SILICA_BLE_SESSIONS 4

static __thread uint8_t silica_ble_rx[SILICA_BLE_BUF];
static __thread uint64_t silica_ble_rx_len = 0;
static __thread int64_t silica_ble_arg_a = 0;
static __thread int64_t silica_ble_arg_b = 0;

static silica_ble_tagged ok(int64_t v) { silica_ble_tagged r = {0, v, 0}; return r; }
static silica_ble_tagged err(int64_t code) { silica_ble_tagged r = {1, 0, code}; return r; }
static silica_ble_tagged timed_out(void) { silica_ble_tagged r = {2, 0, 0}; return r; }
static silica_ble_tagged down(void) { silica_ble_tagged r = {3, 0, 0}; return r; }

@interface SilicaBle : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate>
@property(strong) NSCondition *cond;
@property(strong) dispatch_queue_t queue;
@property int role;
@property int phase;
@property NSInteger managerState;
@property NSInteger mtu;
@property NSInteger writesPending;
@property BOOL writeFailed;
@property BOOL canUpdate;
@property(strong) NSMutableArray<NSData *> *inbox;
@property(strong) CBUUID *serviceUUID;
@property(strong) CBUUID *rxUUID;
@property(strong) CBUUID *txUUID;
@property(strong) CBCentralManager *central;
@property(strong) CBPeripheral *peer;
@property(strong) CBCharacteristic *peerRx;
@property CBCharacteristicWriteType peerWriteType;
@property(strong) CBPeripheralManager *pm;
@property(strong) CBMutableCharacteristic *pmRx;
@property(strong) CBMutableCharacteristic *pmTx;
@end

/* SILICA_BLE_TRACE=1 prints each CoreBluetooth event on stderr. */
static void trace(NSString *what) {
    if (getenv("SILICA_BLE_TRACE") != NULL) fprintf(stderr, "ble: %s\n", what.UTF8String);
}

@implementation SilicaBle

- (void)setPhaseAndSignal:(int)p {
    [self.cond lock];
    self.phase = p;
    [self.cond broadcast];
    [self.cond unlock];
}

/* ---- central role ------------------------------------------------------------------------------ */

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    trace([NSString stringWithFormat:@"central manager state %ld", (long)central.state]);
    [self.cond lock];
    BOOL was_on = self.managerState == CBManagerStatePoweredOn;
    self.managerState = central.state;
    [self.cond broadcast];
    [self.cond unlock];
    if (central.state != CBManagerStatePoweredOn) {
        if (was_on) [self setPhaseAndSignal:PHASE_FAULT];
        return;
    }
    [central scanForPeripheralsWithServices:@[self.serviceUUID] options:nil];
    [self setPhaseAndSignal:PHASE_SEEKING];
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData RSSI:(NSNumber *)RSSI {
    if (self.peer != nil) return;
    trace([NSString stringWithFormat:@"found %@", peripheral.identifier]);
    self.peer = peripheral;
    [central stopScan];
    [central connectPeripheral:peripheral options:nil];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    trace(@"connected");
    peripheral.delegate = self;
    [peripheral discoverServices:@[self.serviceUUID]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    trace([NSString stringWithFormat:@"connect failed, error %@", error]);
    self.peer = nil;
    [central scanForPeripheralsWithServices:@[self.serviceUUID] options:nil];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    trace([NSString stringWithFormat:@"disconnected, error %@", error]);
    int p = PHASE_CLOSED;
    if (error != nil && [error.domain isEqualToString:CBErrorDomain]) {
        if (error.code == CBErrorConnectionTimeout) p = PHASE_TIMEOUT;
        else if (error.code != CBErrorPeripheralDisconnected) p = PHASE_FAULT;
    }
    [self setPhaseAndSignal:p];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    for (CBService *s in peripheral.services) {
        if ([s.UUID isEqual:self.serviceUUID]) [peripheral discoverCharacteristics:nil forService:s];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    CBCharacteristic *rx = nil;
    CBCharacteristic *tx = nil;
    for (CBCharacteristic *c in service.characteristics) {
        if (rx == nil && (c.properties & (CBCharacteristicPropertyWrite | CBCharacteristicPropertyWriteWithoutResponse))) rx = c;
        if (tx == nil && (c.properties & (CBCharacteristicPropertyIndicate | CBCharacteristicPropertyNotify))) tx = c;
    }
    trace([NSString stringWithFormat:@"characteristics: rx %@, tx %@", rx.UUID, tx.UUID]);
    if (rx == nil || tx == nil) { [self setPhaseAndSignal:PHASE_FAULT]; return; }
    self.peerRx = rx;
    self.peerWriteType = (rx.properties & CBCharacteristicPropertyWrite) ? CBCharacteristicWriteWithResponse : CBCharacteristicWriteWithoutResponse;
    [peripheral setNotifyValue:YES forCharacteristic:tx];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error != nil) { trace([NSString stringWithFormat:@"subscribe failed, error %@", error]); [self setPhaseAndSignal:PHASE_FAULT]; return; }
    if (!characteristic.isNotifying || self.peerRx == nil) return;
    [self.cond lock];
    self.mtu = (NSInteger)[peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
    self.phase = PHASE_UP;
    [self.cond broadcast];
    [self.cond unlock];
    trace([NSString stringWithFormat:@"up as central, mtu %ld", (long)self.mtu]);
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error != nil || characteristic.value == nil) return;
    [self.cond lock];
    [self.inbox addObject:[characteristic.value copy]];
    [self.cond broadcast];
    [self.cond unlock];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    [self.cond lock];
    if (self.writesPending > 0) self.writesPending -= 1;
    if (error != nil) self.writeFailed = YES;
    [self.cond broadcast];
    [self.cond unlock];
}

/* ---- peripheral role --------------------------------------------------------------------------- */

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
    trace([NSString stringWithFormat:@"peripheral manager state %ld", (long)peripheral.state]);
    [self.cond lock];
    BOOL was_on = self.managerState == CBManagerStatePoweredOn;
    self.managerState = peripheral.state;
    [self.cond broadcast];
    [self.cond unlock];
    if (peripheral.state != CBManagerStatePoweredOn) {
        if (was_on) [self setPhaseAndSignal:PHASE_FAULT];
        return;
    }
    self.pmRx = [[CBMutableCharacteristic alloc]
        initWithType:self.rxUUID
          properties:CBCharacteristicPropertyWrite
               value:nil
         permissions:CBAttributePermissionsWriteable];
    self.pmTx = [[CBMutableCharacteristic alloc]
        initWithType:self.txUUID
          properties:CBCharacteristicPropertyIndicate
               value:nil
         permissions:CBAttributePermissionsReadable];
    CBMutableService *service = [[CBMutableService alloc] initWithType:self.serviceUUID primary:YES];
    service.characteristics = @[self.pmRx, self.pmTx];
    [peripheral addService:service];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didAddService:(CBService *)service error:(NSError *)error {
    trace([NSString stringWithFormat:@"service added, error %@", error]);
    if (error != nil) { [self setPhaseAndSignal:PHASE_FAULT]; return; }
    [peripheral startAdvertising:@{
        CBAdvertisementDataLocalNameKey: @"Silica",
        CBAdvertisementDataServiceUUIDsKey: @[self.serviceUUID]
    }];
    [self setPhaseAndSignal:PHASE_SEEKING];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral central:(CBCentral *)central didSubscribeToCharacteristic:(CBCharacteristic *)characteristic {
    trace([NSString stringWithFormat:@"subscribed, max update %lu", (unsigned long)central.maximumUpdateValueLength]);
    [self.cond lock];
    self.mtu = (NSInteger)central.maximumUpdateValueLength;
    self.canUpdate = YES;
    self.phase = PHASE_UP;
    [self.cond broadcast];
    [self.cond unlock];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral central:(CBCentral *)central didUnsubscribeFromCharacteristic:(CBCharacteristic *)characteristic {
    trace(@"unsubscribed");
    [self.cond lock];
    if (self.phase == PHASE_UP) self.phase = PHASE_CLOSED;
    [self.cond broadcast];
    [self.cond unlock];
}

/* One callback is one segment: a long write arrives as several requests with rising offsets, which
   are joined. A write that arrives before the subscription waits in the inbox. */
- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveWriteRequests:(NSArray<CBATTRequest *> *)requests {
    NSMutableData *segment = [NSMutableData data];
    BOOL ours = YES;
    for (CBATTRequest *r in requests) {
        trace([NSString stringWithFormat:@"write request, %lu bytes at %lu on %@", (unsigned long)r.value.length, (unsigned long)r.offset, r.characteristic.UUID]);
        if (![r.characteristic.UUID isEqual:self.rxUUID] || r.offset != segment.length) { ours = NO; break; }
        if (r.value != nil) [segment appendData:r.value];
    }
    if (!ours) {
        [peripheral respondToRequest:requests.firstObject withResult:CBATTErrorWriteNotPermitted];
        return;
    }
    [self.cond lock];
    if (segment.length > 0) [self.inbox addObject:[segment copy]];
    [self.cond broadcast];
    [self.cond unlock];
    [peripheral respondToRequest:requests.firstObject withResult:CBATTErrorSuccess];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveReadRequest:(CBATTRequest *)request {
    [peripheral respondToRequest:request withResult:CBATTErrorReadNotPermitted];
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    trace([NSString stringWithFormat:@"advertising, error %@", error]);
    if (error != nil) [self setPhaseAndSignal:PHASE_FAULT];
}

- (void)peripheralManagerIsReadyToUpdateSubscribers:(CBPeripheralManager *)peripheral {
    [self.cond lock];
    self.canUpdate = YES;
    [self.cond broadcast];
    [self.cond unlock];
}

@end

/* ---- sessions ---------------------------------------------------------------------------------- */

static SilicaBle *sessions[SILICA_BLE_SESSIONS];
static NSLock *sessions_lock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

/* handle: 1 .. SILICA_BLE_SESSIONS */
static SilicaBle *session_of(int64_t handle) {
    if (handle < 1 || handle > SILICA_BLE_SESSIONS) return nil;
    [sessions_lock() lock];
    SilicaBle *s = sessions[handle - 1];
    [sessions_lock() unlock];
    return s;
}

static NSDate *deadline_in(int64_t timeout_ms) {
    return [NSDate dateWithTimeIntervalSinceNow:(timeout_ms < 0 ? 0 : (double)timeout_ms) / 1000.0];
}

static BOOL is_hex(NSString *s) {
    if (s.length == 0) return NO;
    NSCharacterSet *not_hex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
    return [s rangeOfCharacterFromSet:not_hex].location == NSNotFound;
}

/* CBUUID raises an exception on text it cannot read, so the text is checked first: 4 or 8
   hexadecimal digits, or 8-4-4-4-12. */
static BOOL uuid_text_ok(NSString *s) {
    if (s.length == 4 || s.length == 8) return is_hex(s);
    if (s.length != 36) return NO;
    NSArray<NSString *> *groups = [s componentsSeparatedByString:@"-"];
    if (groups.count != 5) return NO;
    NSUInteger want[5] = {8, 4, 4, 4, 12};
    for (NSUInteger i = 0; i < 5; i++) {
        if (groups[i].length != want[i] || !is_hex(groups[i])) return NO;
    }
    return YES;
}

/* The UUID whose first group is `add` more than the service's (see the header comment). */
static CBUUID *uuid_plus(NSString *service, unsigned add) {
    NSUInteger head = service.length == 4 ? 4 : 8;
    unsigned long long first = strtoull([service substringToIndex:head].UTF8String, NULL, 16);
    unsigned long long mask = head == 4 ? 0xFFFFull : 0xFFFFFFFFull;
    NSString *group = [NSString stringWithFormat:(head == 4 ? @"%04llX" : @"%08llX"), (first + add) & mask];
    return [CBUUID UUIDWithString:[group stringByAppendingString:[service substringFromIndex:head]]];
}

silica_ble_tagged silica_ble_set_args(int64_t a, int64_t b) {
    silica_ble_arg_a = a;
    silica_ble_arg_b = b;
    return ok(0);
}

/* Starts a session in a role and waits up to timeout_ms for the Bluetooth manager to report its
   state. ok(handle) when it is powered on (the scan or the advertisement has then been asked for).
   role: set_args a; timeout_ms: set_args b; the text is the service UUID, or empty. */
silica_ble_tagged silica_ble_open(const uint8_t *uuid_ptr, uint64_t uuid_len) {
    @autoreleasepool {
        int64_t role = silica_ble_arg_a;
        int64_t timeout_ms = silica_ble_arg_b;
        if (role < 0 || role > 1) return err(2);
        NSString *text = kDefaultService;
        if (uuid_ptr != 0 && uuid_len > 0) {
            text = [[NSString alloc] initWithBytes:uuid_ptr length:(NSUInteger)uuid_len encoding:NSASCIIStringEncoding];
            if (text == nil || !uuid_text_ok(text)) return err(6);
        }
        SilicaBle *s = [[SilicaBle alloc] init];
        s.cond = [[NSCondition alloc] init];
        s.queue = dispatch_queue_create("silica.ble", DISPATCH_QUEUE_SERIAL);
        s.inbox = [NSMutableArray array];
        s.role = (int)role;
        s.phase = PHASE_STARTING;
        s.managerState = CBManagerStateUnknown;
        s.mtu = 20;
        s.serviceUUID = [CBUUID UUIDWithString:text];
        s.rxUUID = uuid_plus(text, 1);
        s.txUUID = uuid_plus(text, 2);
        int64_t handle = 0;
        [sessions_lock() lock];
        for (int i = 0; i < SILICA_BLE_SESSIONS; i++) {
            if (sessions[i] == nil) { sessions[i] = s; handle = i + 1; break; }
        }
        [sessions_lock() unlock];
        if (handle == 0) return err(1);
        if (role == 1) s.pm = [[CBPeripheralManager alloc] initWithDelegate:s queue:s.queue];
        else s.central = [[CBCentralManager alloc] initWithDelegate:s queue:s.queue];
        NSDate *until = deadline_in(timeout_ms);
        [s.cond lock];
        while (s.managerState == CBManagerStateUnknown || s.managerState == CBManagerStateResetting) {
            if (![s.cond waitUntilDate:until]) break;
        }
        NSInteger st = s.managerState;
        [s.cond unlock];
        if (st == CBManagerStatePoweredOn) return ok(handle);
        [sessions_lock() lock];
        sessions[handle - 1] = nil;
        [sessions_lock() unlock];
        if (st == CBManagerStateUnknown || st == CBManagerStateResetting) return timed_out();
        return err(1000 + (int64_t)st);
    }
}

/* The session's phase: 0 starting, 1 scanning or advertising, 2 up, 3 closed by the peer, 4 lost
   (supervision timeout), 5 fault. Waits up to timeout_ms for it to differ from `from`, so a caller can
   block for a change instead of spinning. handle: set_args a; from: the first parameter. */
silica_ble_tagged silica_ble_phase(int64_t from, int64_t timeout_ms) {
    @autoreleasepool {
        SilicaBle *s = session_of(silica_ble_arg_a);
        if (s == nil) return err(3);
        NSDate *until = deadline_in(timeout_ms);
        [s.cond lock];
        while (s.phase == (int)from) {
            if (![s.cond waitUntilDate:until]) break;
        }
        int p = s.phase;
        [s.cond unlock];
        return ok(p);
    }
}

/* The largest segment: the negotiated ATT_MTU minus 3 once the link is up, 20 before. */
silica_ble_tagged silica_ble_mtu(int64_t handle) {
    SilicaBle *s = session_of(handle);
    if (s == nil) return err(3);
    [s.cond lock];
    NSInteger m = s.mtu;
    [s.cond unlock];
    return ok((int64_t)m);
}

/* Sends one segment and waits for it to be accepted (central: the peer's write response; peripheral:
   room in the indication queue). handle: set_args a; timeout_ms: set_args b */
silica_ble_tagged silica_ble_send(const uint8_t *data_ptr, uint64_t data_len) {
    @autoreleasepool {
        int64_t timeout_ms = silica_ble_arg_b;
        SilicaBle *s = session_of(silica_ble_arg_a);
        if (s == nil) return err(3);
        [s.cond lock];
        int phase = s.phase;
        NSInteger mtu = s.mtu;
        [s.cond unlock];
        if (phase != PHASE_UP) return down();
        if (data_ptr == 0 || data_len == 0 || data_len > (uint64_t)mtu) return err(4);
        NSData *data = [NSData dataWithBytes:data_ptr length:(NSUInteger)data_len];
        NSDate *until = deadline_in(timeout_ms);
        if (s.role == 0) {
            if (s.peerWriteType == CBCharacteristicWriteWithoutResponse) {
                dispatch_sync(s.queue, ^{
                    [s.peer writeValue:data forCharacteristic:s.peerRx type:CBCharacteristicWriteWithoutResponse];
                });
                return ok((int64_t)data_len);
            }
            [s.cond lock];
            s.writesPending += 1;
            s.writeFailed = NO;
            [s.cond unlock];
            dispatch_async(s.queue, ^{
                [s.peer writeValue:data forCharacteristic:s.peerRx type:CBCharacteristicWriteWithResponse];
            });
            [s.cond lock];
            BOOL in_time = YES;
            while (s.writesPending > 0 && s.phase == PHASE_UP) {
                if (![s.cond waitUntilDate:until]) { in_time = NO; break; }
            }
            BOOL failed = s.writeFailed;
            int now = s.phase;
            [s.cond unlock];
            if (now != PHASE_UP) return down();
            if (!in_time) return timed_out();
            if (failed) return err(5);
            return ok((int64_t)data_len);
        }
        for (;;) {
            __block BOOL sent = NO;
            dispatch_sync(s.queue, ^{
                sent = [s.pm updateValue:data forCharacteristic:s.pmTx onSubscribedCentrals:nil];
                if (!sent) {
                    [s.cond lock];
                    s.canUpdate = NO;
                    [s.cond unlock];
                }
            });
            if (sent) return ok((int64_t)data_len);
            [s.cond lock];
            BOOL in_time = YES;
            while (!s.canUpdate && s.phase == PHASE_UP) {
                if (![s.cond waitUntilDate:until]) { in_time = NO; break; }
            }
            int now = s.phase;
            [s.cond unlock];
            if (now != PHASE_UP) return down();
            if (!in_time) return timed_out();
        }
    }
}

/* Takes the oldest received segment into the thread's buffer; value is its length. A segment that
   arrived before the link went down is still answered. */
silica_ble_tagged silica_ble_recv(int64_t handle, int64_t max, int64_t timeout_ms) {
    @autoreleasepool {
        SilicaBle *s = session_of(handle);
        if (s == nil) return err(3);
        NSDate *until = deadline_in(timeout_ms);
        [s.cond lock];
        while (s.inbox.count == 0 && s.phase <= PHASE_UP) {
            if (![s.cond waitUntilDate:until]) break;
        }
        NSData *d = nil;
        if (s.inbox.count > 0) {
            d = s.inbox.firstObject;
            [s.inbox removeObjectAtIndex:0];
        }
        int phase = s.phase;
        [s.cond unlock];
        if (d == nil) return phase > PHASE_UP ? down() : timed_out();
        size_t cap = (max > 0 && max < SILICA_BLE_BUF) ? (size_t)max : SILICA_BLE_BUF;
        size_t n = d.length < cap ? d.length : cap;
        memcpy(silica_ble_rx, d.bytes, n);
        silica_ble_rx_len = (uint64_t)n;
        return ok((int64_t)n);
    }
}

/* The bytes of the last receive on this thread: a malloc'd span the compiler's string-out helper
   copies into a Silica string and frees (as silica_sockets_take). */
silica_ble_bytes silica_ble_take(int64_t handle) {
    silica_ble_bytes r;
    (void)handle;
    r.tag = 0;
    r.text_ptr = 0;
    r.text_len = 0;
    r.error_code = 0;
    if (silica_ble_rx_len > 0) {
        uint8_t *span = (uint8_t *)malloc(silica_ble_rx_len);
        if (span == 0) { r.tag = 1; r.error_code = 12; return r; }
        memcpy(span, silica_ble_rx, silica_ble_rx_len);
        r.text_ptr = span;
        r.text_len = silica_ble_rx_len;
    }
    return r;
}

/* Ends the session: stops the scan or the advertisement, drops the connection, frees the handle. */
silica_ble_tagged silica_ble_close(int64_t handle) {
    @autoreleasepool {
        SilicaBle *s = session_of(handle);
        if (s == nil) return err(3);
        dispatch_sync(s.queue, ^{
            if (s.central != nil) {
                if (s.central.state == CBManagerStatePoweredOn) [s.central stopScan];
                if (s.peer != nil) [s.central cancelPeripheralConnection:s.peer];
            }
            if (s.pm != nil) {
                [s.pm stopAdvertising];
                [s.pm removeAllServices];
            }
        });
        [s.cond lock];
        if (s.phase <= PHASE_UP) s.phase = PHASE_CLOSED;
        [s.cond broadcast];
        [s.cond unlock];
        [sessions_lock() lock];
        sessions[handle - 1] = nil;
        [sessions_lock() unlock];
        return ok(0);
    }
}
