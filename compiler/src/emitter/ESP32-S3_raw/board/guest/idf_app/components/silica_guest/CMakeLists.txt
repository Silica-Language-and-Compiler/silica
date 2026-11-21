# What ESP-IDF builds of the Silica guest: the two scheduler tasks and the calls the Silica runtime
# makes into FreeRTOS. The runtime itself and the program are not in this component: they are added
# to the application's link by ../../../tools/build_image.sh, one image at a time.
idf_component_register(SRCS "guest.c" "guest_consts.S"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES esp_system esp_timer esp_rom bt nvs_flash)
# Keep the Bluetooth controller's and NVS's libraries on the link line for the foreign wrappers a
# program brings; the linker drops what a program does not call.
