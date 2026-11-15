# transport_usb_serial_jtag_demo (moved)

The USB-C demos that lived here moved on 2026-11-10 to [`examples/transport_pairs/`](../../examples/transport_pairs/),
one directory per board/Mac pair, each with its board program, its Mac peers, the expected output and a run script:

- `usb_basic_exchange`: the stage S-A exchange (one reading, one LED command; the board program was
  `board/apps/silica_33_transport_usb_serial_jtag_etf`, the Silica peer was `dangerous_usb_serial_jtag_peer.silica`
  here, the Erlang peer was `../transport_beam_demo/silica_peer.erl` behind the bridge).
- `usb_accel_led_erlang_and_silica`: stage S-D (a sequence of readings, LED commands back, the board drives the LED).
- `usb_silica_pair`: Silica on both ends, requests from both sides.

`find_usb_serial_jtag_port.py` is now `examples/transport_pairs/lib/find_usb_serial_jtag_port.py`; `run_peer.sh` is
replaced by each pair's `run.sh` and `examples/transport_pairs/lib/pair_lib.sh`. The serial-to-TCP bridge is still
`../transport_uart1_demo/serial_to_tcp_bridge.py`. Older documents (the stage log of
`compiler/design_documents/transport_esp32s3_wifi_plan.md`) name the files here as they were when the runs were made.
