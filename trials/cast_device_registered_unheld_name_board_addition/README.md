# cast_device_registered_unheld_name_board_addition

Board-only trial: `cast_device_registered` to a name no device worker holds raises `actor_not_found`
(spec §20.3.1; device spec §1 "Split registries"), as `cast_registered` does. In `main` that is the
language-level failure: `actor_not_found` on the console, exit status 1. Its own directory keeps the
new atoms out of the existing suites' goldens.

Run: `make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=cast_device_registered_unheld_name_board_addition` from `trials/`.
