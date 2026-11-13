# The ESP-IDF application a Silica program runs in as a guest (transport_ble_plan.md §2.1). It is built
# once without a program (tools/build_image.sh --prepare); each image is then this application's link
# with the Silica runtime and one program's objects added.
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(silica_guest_app)
