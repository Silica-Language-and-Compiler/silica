# transport_ble_board_addition

Board-only trials of the `(:ble_gatt)` carrier on the ESP32-S3's own radio (`transport_ble_plan.md` stages 7, 9 and 10):
`carried_on phone: (:ble_gatt) (:bluetooth, 0);`, the carrier `dangerous_ble_gatt_board_carrier` above the radio
actor `dangerous_ble_radio` and NimBLE, ESP-IDF's Bluetooth host. The programs only spawn, cast and wait; the
framing module, the NimBLE bindings, the radio actor and the carrier are named by the Makefile from
`compiler/stdlib/`.

The radio needs ESP-IDF's libraries, so the trials run on the trial target `ESP32-S3_idf` only (the board as a
guest of ESP-IDF). `guest_c_sources` names the Fifi wrapper around NimBLE, `compiler/stdlib/ble/silica_ble_nimble.c`;
the board driver compiles it into each program's image as ESP-IDF code and skips the suite's programs on
`ESP32-S3_raw` (`trials/targets/README.md`).

Nothing here needs a peer (links design decision 15: board trials go one direction). The two-way exchange with a
peer is `programmer_tools/transport_ble_demo/run_board_peer.sh` (the board as peripheral, or as central with
`--central`), outside `make integrate`.

| Trial | Shows |
| --- | --- |
| `dangerous_ble_gatt_link_central` | the declaration and `spawn_dangerous_carrier(phone, ...)` (expanded by the ESP32-S3 pack's `carrier_spawn` to `spawn({...}, dangerous_ble_gatt_board_carrier@carrier, ...)`, an `actor_ref`); `Carrier@mtu(phone)` is 20; `(:open, owner, "central:<uuid>")` with a UUID nothing nearby offers: the radio actor starts the controller and NimBLE and scans; a `:tx` while the link is not up is `(:tx_failed, :link_down)`; six seconds later `:close` ends the scan and answers `(:link_down, :closed)` |
| `dangerous_ble_gatt_link_bad_service` | `(:open, owner, "peripheral:not-a-uuid")`: the carrier spawns the radio actor, the wrapper refuses the service before the host starts, and the owner gets `(:link_down, :fault)` |
| `dangerous_ble_gatt_link_second_carrier` | the board holds one link: with one carrier open as a peripheral, `(:open, owner, "peripheral:")` to a second carrier answers `(:link_down, :fault)`, and the first then closes with `(:link_down, :closed)` |
| `dangerous_ble_gatt_link_open_close` | `(:open, owner, "peripheral:")`: the radio actor publishes the Nordic UART Service, starts the controller and NimBLE and advertises; a `:tx` while no central has subscribed is `(:tx_failed, :link_down)`; six seconds later `:close` stops the advertising and answers `(:link_down, :closed)`. The board is on the air as "Silica" for those seconds |

## Goldens and targets

- The trials carry `<stem>.ESP32-S3_idf.scout` only. On a hosted target the suite is `INTEGRATE_PENDING` (skipped
  and not counted by the host run): the carrier module is the board's.
- `<stem>.esp32_s3.ascomp` is the ESP32-S3 compiler's own output for the program, written by
  `trials/targets/gen_board_ascomp.sh ESP32-S3_idf` after a board run matched the `.scout`. The goldens depend on the
  suite's whole compile set (atom indices are assigned across the `silica.config`), so a change to the radio actor
  or the carrier that adds or removes an atom means regenerating them (delete the stale golden first).
- The goldens are hand-derived from the source: the output does not depend on a peer.

Board run: `make integrate TRIAL_TARGET=ESP32-S3_idf TRIAL_SUITES=transport_ble_board_addition` from `trials/`.
