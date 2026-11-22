/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this leaves the spike)

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

/* Stage 1 spike of compiler/design_documents/transport_ble_plan.md: a wrapper over CoreBluetooth in
   the shape of compiler/stdlib/net/silica_sockets.c, to find out whether a Fifi wrapper can be
   Objective-C, link a framework, and receive CoreBluetooth's callbacks in a program that runs no main
   run loop. Throwaway: one session per process, one fixed service.

   The managers deliver their callbacks on a private serial dispatch queue. Every wrapper call is
   bounded by a timeout in milliseconds and waits on a condition the callbacks signal, so a carrier
   actor can poll between its mailbox messages as the hosted carriers do.

   Result conventions (as silica_sockets.c): { tag, value, error_code } with tag 0 = ok, 1 = error,
   2 = timeout, 3 = link down. For silica_ble_open an error's error_code is 1000 + CBManagerState
   (1002 unsupported, 1003 unauthorized, 1004 powered off).

   Roles: 0 central (scans for the service, connects, subscribes), 1 peripheral (advertises the
   service, waits for a subscriber), 2 scan only (counts every advertiser seen; connects to nothing).

   Service: the Nordic UART Service. The central writes the RX characteristic with response; the
   peripheral sends on the TX characteristic by indication (plan §4: both are acknowledged). */

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

static NSString *const kServiceUUID = @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static NSString *const kRxUUID = @"6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; /* central to peripheral */
static NSString *const kTxUUID = @"6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; /* peripheral to central */

enum { PHASE_STARTING = 0, PHASE_SEEKING = 1, PHASE_UP = 2, PHASE_DOWN = 3 };

#define SILICA_BLE_BUF 1024

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
@property NSInteger seen;
@property NSInteger writesPending;
@property BOOL writeFailed;
@property BOOL canUpdate;
@property(strong) NSMutableArray<NSData *> *inbox;
@property(strong) CBCentralManager *central;
@property(strong) CBPeripheral *peer;
@property(strong) CBCharacteristic *peerRx;
@property(strong) CBPeripheralManager *pm;
@property(strong) CBMutableCharacteristic *pmTx;
@property(strong) CBCentral *subscriber;
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
    [self.cond lock];
    self.managerState = central.state;
    [self.cond broadcast];
    [self.cond unlock];
    if (central.state != CBManagerStatePoweredOn) return;
    NSArray *services = self.role == 2 ? nil : @[[CBUUID UUIDWithString:kServiceUUID]];
    [central scanForPeripheralsWithServices:services options:nil];
    [self setPhaseAndSignal:PHASE_SEEKING];
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData RSSI:(NSNumber *)RSSI {
    [self.cond lock];
    self.seen += 1;
    [self.cond broadcast];
    [self.cond unlock];
    if (self.role == 2 || self.peer != nil) return;
    self.peer = peripheral;
    [central stopScan];
    [central connectPeripheral:peripheral options:nil];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    peripheral.delegate = self;
    [peripheral discoverServices:@[[CBUUID UUIDWithString:kServiceUUID]]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    self.peer = nil;
    [central scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:kServiceUUID]] options:nil];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [self setPhaseAndSignal:PHASE_DOWN];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    for (CBService *s in peripheral.services) {
        [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:kRxUUID], [CBUUID UUIDWithString:kTxUUID]] forService:s];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID isEqual:[CBUUID UUIDWithString:kRxUUID]]) self.peerRx = c;
        if ([c.UUID isEqual:[CBUUID UUIDWithString:kTxUUID]]) [peripheral setNotifyValue:YES forCharacteristic:c];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error != nil || !characteristic.isNotifying || self.peerRx == nil) return;
    [self.cond lock];
    self.mtu = (NSInteger)[peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
    self.phase = PHASE_UP;
    [self.cond broadcast];
    [self.cond unlock];
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
    [self.cond lock];
    self.managerState = peripheral.state;
    [self.cond broadcast];
    [self.cond unlock];
    if (peripheral.state != CBManagerStatePoweredOn) return;
    CBMutableCharacteristic *rx = [[CBMutableCharacteristic alloc]
        initWithType:[CBUUID UUIDWithString:kRxUUID]
          properties:CBCharacteristicPropertyWrite
               value:nil
         permissions:CBAttributePermissionsWriteable];
    self.pmTx = [[CBMutableCharacteristic alloc]
        initWithType:[CBUUID UUIDWithString:kTxUUID]
          properties:CBCharacteristicPropertyIndicate
               value:nil
         permissions:CBAttributePermissionsReadable];
    CBMutableService *service = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:kServiceUUID] primary:YES];
    service.characteristics = @[rx, self.pmTx];
    [peripheral addService:service];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didAddService:(CBService *)service error:(NSError *)error {
    trace([NSString stringWithFormat:@"service added, error %@", error]);
    if (error != nil) { [self setPhaseAndSignal:PHASE_DOWN]; return; }
    [peripheral startAdvertising:@{
        CBAdvertisementDataLocalNameKey: @"Silica",
        CBAdvertisementDataServiceUUIDsKey: @[[CBUUID UUIDWithString:kServiceUUID]]
    }];
    [self setPhaseAndSignal:PHASE_SEEKING];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral central:(CBCentral *)central didSubscribeToCharacteristic:(CBCharacteristic *)characteristic {
    trace([NSString stringWithFormat:@"subscribed, max update %lu", (unsigned long)central.maximumUpdateValueLength]);
    [self.cond lock];
    self.subscriber = central;
    self.mtu = (NSInteger)central.maximumUpdateValueLength;
    self.canUpdate = YES;
    self.phase = PHASE_UP;
    [self.cond broadcast];
    [self.cond unlock];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral central:(CBCentral *)central didUnsubscribeFromCharacteristic:(CBCharacteristic *)characteristic {
    /* Not the end of the link: the central may still write, and may subscribe again. */
    trace(@"unsubscribed");
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveWriteRequests:(NSArray<CBATTRequest *> *)requests {
    trace([NSString stringWithFormat:@"write callback, %lu requests", (unsigned long)requests.count]);
    [self.cond lock];
    for (CBATTRequest *r in requests) {
        trace([NSString stringWithFormat:@"write request, %lu bytes on %@", (unsigned long)r.value.length, r.characteristic.UUID]);
        if (r.value != nil) [self.inbox addObject:[r.value copy]];
    }
    /* A central that writes before it subscribes is a peer all the same. */
    if (self.phase != PHASE_UP) {
        self.mtu = (NSInteger)requests.firstObject.central.maximumUpdateValueLength;
        self.canUpdate = YES;
        self.phase = PHASE_UP;
    }
    [self.cond broadcast];
    [self.cond unlock];
    [peripheral respondToRequest:requests.firstObject withResult:CBATTErrorSuccess];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveReadRequest:(CBATTRequest *)request {
    trace([NSString stringWithFormat:@"read request on %@", request.characteristic.UUID]);
    request.value = [NSData data];
    [peripheral respondToRequest:request withResult:CBATTErrorSuccess];
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    trace([NSString stringWithFormat:@"advertising, error %@", error]);
}

- (void)peripheralManagerIsReadyToUpdateSubscribers:(CBPeripheralManager *)peripheral {
    [self.cond lock];
    self.canUpdate = YES;
    [self.cond broadcast];
    [self.cond unlock];
}

@end

static SilicaBle *g = nil;

static NSDate *deadline_in(int64_t timeout_ms) {
    return [NSDate dateWithTimeIntervalSinceNow:(timeout_ms < 0 ? 0 : (double)timeout_ms) / 1000.0];
}

silica_ble_tagged silica_ble_set_args(int64_t a, int64_t b) {
    silica_ble_arg_a = a;
    silica_ble_arg_b = b;
    return ok(0);
}

/* Starts the role and waits up to timeout_ms for the Bluetooth manager to report its state. ok(1)
   when it is powered on (the scan or the advertisement has then been asked for). */
silica_ble_tagged silica_ble_open(int64_t role, int64_t timeout_ms) {
    @autoreleasepool {
        if (g != nil) return err(1);
        if (role < 0 || role > 2) return err(2);
        SilicaBle *s = [[SilicaBle alloc] init];
        s.cond = [[NSCondition alloc] init];
        s.queue = dispatch_queue_create("silica.ble", DISPATCH_QUEUE_SERIAL);
        s.inbox = [NSMutableArray array];
        s.role = (int)role;
        s.phase = PHASE_STARTING;
        s.managerState = CBManagerStateUnknown;
        s.mtu = 20;
        g = s;
        if (role == 1) s.pm = [[CBPeripheralManager alloc] initWithDelegate:s queue:s.queue];
        else s.central = [[CBCentralManager alloc] initWithDelegate:s queue:s.queue];
        NSDate *until = deadline_in(timeout_ms);
        [s.cond lock];
        while (s.managerState == CBManagerStateUnknown || s.managerState == CBManagerStateResetting) {
            if (![s.cond waitUntilDate:until]) break;
        }
        NSInteger st = s.managerState;
        [s.cond unlock];
        if (st == CBManagerStatePoweredOn) return ok(1);
        if (st == CBManagerStateUnknown || st == CBManagerStateResetting) return timed_out();
        return err(1000 + (int64_t)st);
    }
}

/* 0 starting, 1 scanning or advertising, 2 up, 3 down. Waits up to timeout_ms for the phase to
   differ from `from`, so a caller can block for a change instead of spinning. */
silica_ble_tagged silica_ble_phase(int64_t from, int64_t timeout_ms) {
    @autoreleasepool {
        if (g == nil) return err(3);
        NSDate *until = deadline_in(timeout_ms);
        [g.cond lock];
        while (g.phase == (int)from) {
            if (![g.cond waitUntilDate:until]) break;
        }
        int p = g.phase;
        [g.cond unlock];
        return ok(p);
    }
}

/* The largest segment: the negotiated ATT_MTU minus 3 once the link is up, 20 before. */
silica_ble_tagged silica_ble_mtu(int64_t handle) {
    (void)handle;
    if (g == nil) return err(3);
    [g.cond lock];
    NSInteger m = g.mtu;
    [g.cond unlock];
    return ok((int64_t)m);
}

/* Advertisers seen so far (role 2 counts all of them; role 0 only those with the service). */
silica_ble_tagged silica_ble_seen(int64_t handle) {
    (void)handle;
    if (g == nil) return err(3);
    [g.cond lock];
    NSInteger n = g.seen;
    [g.cond unlock];
    return ok((int64_t)n);
}

/* Sends one segment and waits for it to be accepted (central: the peer's write response; peripheral:
   room in the indication queue). timeout_ms: set_args b */
silica_ble_tagged silica_ble_send(const uint8_t *data_ptr, uint64_t data_len) {
    @autoreleasepool {
        int64_t timeout_ms = silica_ble_arg_b;
        if (g == nil) return err(3);
        if (data_ptr == 0 || data_len == 0 || data_len > 512) return err(4);
        SilicaBle *s = g;
        NSData *data = [NSData dataWithBytes:data_ptr length:(NSUInteger)data_len];
        NSDate *until = deadline_in(timeout_ms);
        [s.cond lock];
        int phase = s.phase;
        [s.cond unlock];
        if (phase != PHASE_UP) return down();
        if (s.role == 0) {
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

/* Takes the oldest received segment into the thread's buffer; value is its length. */
silica_ble_tagged silica_ble_recv(int64_t handle, int64_t max, int64_t timeout_ms) {
    @autoreleasepool {
        (void)handle;
        if (g == nil) return err(3);
        SilicaBle *s = g;
        NSDate *until = deadline_in(timeout_ms);
        [s.cond lock];
        while (s.inbox.count == 0 && s.phase != PHASE_DOWN) {
            if (![s.cond waitUntilDate:until]) break;
        }
        NSData *d = nil;
        if (s.inbox.count > 0) {
            d = s.inbox.firstObject;
            [s.inbox removeObjectAtIndex:0];
        }
        int phase = s.phase;
        [s.cond unlock];
        if (d == nil) return phase == PHASE_DOWN ? down() : timed_out();
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

silica_ble_tagged silica_ble_close(int64_t handle) {
    @autoreleasepool {
        (void)handle;
        if (g == nil) return err(3);
        SilicaBle *s = g;
        dispatch_sync(s.queue, ^{
            if (s.central != nil) {
                [s.central stopScan];
                if (s.peer != nil) [s.central cancelPeripheralConnection:s.peer];
            }
            if (s.pm != nil) {
                [s.pm stopAdvertising];
                [s.pm removeAllServices];
            }
        });
        [s setPhaseAndSignal:PHASE_DOWN];
        g = nil;
        return ok(0);
    }
}
