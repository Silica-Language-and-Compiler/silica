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

// Route R1 spike, Wi-Fi (transport_ble_plan.md stage 12, part 6): lwIP above the station. ESP-IDF's
// own layer between the two (esp_netif) is not in the image; this is the least of it:
//
//   spike_net_core     starts lwIP's task, once: enough for 127.0.0.1 (lwIP's own loopback interface).
//                      Not safe against a second caller at the same moment: the first call is made
//                      where only one runs (the wrapper calls it from the actors' core).
//   spike_net_start    starts lwIP's task and adds one interface whose frames go out by
//                      esp_wifi_internal_tx and come in from the station's receive callback (each
//                      copied once, either way), then asks for an address by DHCP.
//   spike_net_address  the address DHCP gave, 0 until it has.
//   spike_net_exchange connects to a TCP peer, sends one frame behind a 4-byte length (what Erlang's
//                      gen_tcp {packet, 4} speaks) and reads one back.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "esp_wifi.h"
#include "esp_private/wifi.h"
#include "lwip/tcpip.h"
#include "lwip/netifapi.h"
#include "lwip/dhcp.h"
#include "lwip/etharp.h"
#include "lwip/sockets.h"
#include "netif/ethernet.h"

static struct netif station;
static uint8_t out_frame[1600];

static err_t frame_out(struct netif *netif, struct pbuf *p)
{
    (void)netif;
    if (p->tot_len > sizeof out_frame) {
        return ERR_BUF;
    }
    pbuf_copy_partial(p, out_frame, p->tot_len, 0);
    return esp_wifi_internal_tx(WIFI_IF_STA, out_frame, p->tot_len) == ESP_OK ? ERR_OK : ERR_IF;
}

uint32_t spike_net_frames_in, spike_net_bytes_in;

static esp_err_t frame_in(void *buffer, uint16_t len, void *eb)
{
    spike_net_frames_in++;
    spike_net_bytes_in += len;
    struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_RAM);
    if (p != NULL) {
        pbuf_take(p, buffer, len);
        if (station.input(p, &station) != ERR_OK) {
            pbuf_free(p);
        }
    }
    esp_wifi_internal_free_rx_buffer(eb);
    return ESP_OK;
}

static err_t station_init(struct netif *netif)
{
    netif->name[0] = 's';
    netif->name[1] = 't';
    netif->output = etharp_output;
    netif->linkoutput = frame_out;
    netif->mtu = 1500;
    netif->hwaddr_len = 6;
    esp_wifi_get_mac(WIFI_IF_STA, netif->hwaddr);
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_LINK_UP;
    return ERR_OK;
}

void spike_net_core(void)
{
    static int started;
    if (!started) {
        started = 1;
        tcpip_init(NULL, NULL);
    }
}

int spike_net_start(void)
{
    spike_net_core();
    if (netifapi_netif_add(&station, NULL, NULL, NULL, NULL, station_init, tcpip_input) != ERR_OK) {
        return 1;
    }
    netifapi_netif_set_default(&station);
    netifapi_netif_set_up(&station);
    if (esp_wifi_internal_reg_rxcb(WIFI_IF_STA, frame_in) != ESP_OK) {
        return 2;
    }
    return netifapi_dhcp_start(&station) == ERR_OK ? 0 : 3;
}

// in network byte order
uint32_t spike_net_address(void)
{
    return dhcp_supplied_address(&station) ? ip4_addr_get_u32(netif_ip4_addr(&station)) : 0;
}

static int read_all(int s, uint8_t *to, int n)
{
    int got = 0;
    while (got < n) {
        int r = lwip_recv(s, to + got, (size_t)(n - got), 0);
        if (r <= 0) {
            return -1;
        }
        got += r;
    }
    return got;
}

// 0 when the frame came back as sent; else the step that failed (1 socket, 2 connect, 3 send, 4 the
// length read, 5 the frame read, 6 not the same).
int spike_net_exchange(const char *peer, uint16_t port, const uint8_t *frame, uint32_t len, uint8_t *back)
{
    int s = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        return 1;
    }
    struct sockaddr_in to;
    memset(&to, 0, sizeof to);
    to.sin_family = AF_INET;
    to.sin_port = lwip_htons(port);
    to.sin_addr.s_addr = ipaddr_addr(peer);
    int step = 0;
    uint8_t head[4] = { (uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8), (uint8_t)len }, got[4];
    if (lwip_connect(s, (struct sockaddr *)&to, sizeof to) != 0) {
        step = 2;
    } else if (lwip_send(s, head, 4, 0) != 4 || lwip_send(s, frame, len, 0) != (int)len) {
        step = 3;
    } else if (read_all(s, got, 4) != 4 || memcmp(got, head, 4) != 0) {
        step = 4;
    } else if (read_all(s, back, (int)len) != (int)len) {
        step = 5;
    } else if (memcmp(back, frame, len) != 0) {
        step = 6;
    }
    lwip_close(s);
    return step;
}
