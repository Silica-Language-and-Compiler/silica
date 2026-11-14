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

/* The Mac's check of the board's advertising (transport_ble_plan.md stage 6): scans for peripherals
   that advertise a service and prints, for each five seconds, how many advertisements of each it
   heard, with its name and signal strength. Built and run by find_service.sh.

     find_service [uuid] [seconds]

   uuid: the service's UUID, by default the Nordic UART Service. Exit 0 when at least one
   advertisement was heard in every five-second window, 1 otherwise. */

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <stdio.h>
#include <stdlib.h>

@interface Finder : NSObject <CBCentralManagerDelegate>
@property (strong) CBCentralManager *manager;
@property (strong) CBUUID *service;
@property (strong) NSMutableDictionary<NSUUID *, NSMutableDictionary *> *seen;
@property int state;
@end

@implementation Finder
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    self.state = (int)central.state;
    if (central.state == CBManagerStatePoweredOn)
        [central scanForPeripheralsWithServices:@[ self.service ]
                                        options:@{ CBCentralManagerScanOptionAllowDuplicatesKey : @YES }];
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)data RSSI:(NSNumber *)rssi {
    @synchronized (self) {
        NSMutableDictionary *e = self.seen[peripheral.identifier];
        if (e == nil) { e = [@{ @"count" : @0, @"name" : @"" } mutableCopy]; self.seen[peripheral.identifier] = e; }
        e[@"count"] = @([e[@"count"] intValue] + 1);
        e[@"rssi"] = rssi;
        NSString *name = data[CBAdvertisementDataLocalNameKey] ?: peripheral.name;
        if (name != nil) e[@"name"] = name;
    }
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *uuid = argc > 1 && argv[1][0] != 0 ? @(argv[1]) : @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
        int seconds = argc > 2 ? atoi(argv[2]) : 30;
        Finder *f = [Finder new];
        @try { f.service = [CBUUID UUIDWithString:uuid]; }
        @catch (NSException *e) { fprintf(stderr, "find_service: %s is no UUID\n", uuid.UTF8String); return 2; }
        f.seen = [NSMutableDictionary new];
        f.manager = [[CBCentralManager alloc] initWithDelegate:f queue:dispatch_queue_create("find_service", DISPATCH_QUEUE_SERIAL)];
        int silent = 0, windows = 0;
        for (int t = 5; t <= seconds; t += 5) {
            [NSThread sleepForTimeInterval:5.0];
            if (f.state != CBManagerStatePoweredOn) { printf("%3d s: the adapter is not on (state %d)\n", t, f.state); silent++; windows++; continue; }
            @synchronized (f) {
                windows++;
                if (f.seen.count == 0) { printf("%3d s: nothing heard\n", t); silent++; }
                for (NSUUID *k in f.seen) {
                    NSDictionary *e = f.seen[k];
                    printf("%3d s: %d advertisements from \"%s\" (rssi %d)\n", t, [e[@"count"] intValue], [e[@"name"] UTF8String], [e[@"rssi"] intValue]);
                }
                [f.seen removeAllObjects];
            }
            fflush(stdout);
        }
        printf("find_service: %d of %d windows heard the service\n", windows - silent, windows);
        return silent == 0 && windows > 0 ? 0 : 1;
    }
}
