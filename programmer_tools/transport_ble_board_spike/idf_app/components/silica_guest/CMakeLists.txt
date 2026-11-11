# Stage 4 spike: Silica's board runtime and one emitted program as an ESP-IDF component. gen/ is
# filled by ../../../run_guest.sh: the runtime's .S files (two of them patched, two left out) and
# the program's emitted assembly as .s files (no C preprocessing, as build_image.sh assembles them).
file(GLOB gen_S "gen/*.S")
file(GLOB gen_s "gen/*.s")
file(GLOB gen_c "gen/*.c")
idf_component_register(SRCS "rt_guest_start.S" "rt_guest_mem.S" "guest.c" ${gen_S} ${gen_s} ${gen_c}
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES bt
                       LDFRAGMENTS "linker.lf")
# libgcc's 64-bit helpers and the foreign wrappers are found by the normal link. Keep every runtime
# object: the emitted code names its entry points.
target_link_libraries(${COMPONENT_LIB} INTERFACE "-u main")
