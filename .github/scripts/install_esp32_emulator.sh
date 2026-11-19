#!/bin/bash
# Xtensa toolchain, esptool, and Espressif's qemu-system-xtensa for the ESP32-S3 trial shards.
# A stamp skips the download when the cache already has this set.
# Exports XTENSA_BIN, ESPTOOL, BOARD_PYTHON, SILICA_QEMU, and SILICA_BOARD_EMULATOR.

set -euo pipefail

root="${SILICA_ESP32_TOOLS:?}"
stamp_text="xtensa-esp-16.1.0_20260609 qemu-esp-develop-9.2.2-20261109 esptool-5.4.0"
xtensa_url="https://github.com/espressif/crosstool-NG/releases/download/esp-16.1.0_20260609/xtensa-esp-elf-16.1.0_20260609-aarch64-apple-darwin.tar.xz"
qemu_url="https://github.com/espressif/qemu/releases/download/esp-develop-9.2.2-20261109/qemu-xtensa-softmmu-esp_develop_9.2.2_20261109-aarch64-apple-darwin.tar.xz"

mkdir -p "$root"

first_file() {
    local found="" path
    while IFS= read -r path; do
        found=$path
        break
    done < <(find "$1" -name "$2" -type f)
    printf '%s\n' "$found"
}

ready() {
    [ -f "$root/stamp" ] && [ "$(cat "$root/stamp")" = "$stamp_text" ] \
        && [ -n "$(first_file "$root/xtensa" xtensa-esp32s3-elf-gcc)" ] \
        && [ -n "$(first_file "$root/qemu" qemu-system-xtensa)" ] \
        && "$root/py/bin/python" -c "import esptool, serial" >/dev/null 2>&1
}

fetch() {
    url=$1
    dir=$2
    rm -rf "$dir"
    mkdir -p "$dir"
    archive="${RUNNER_TEMP}/$(basename "$url")"
    curl -fL --retry 5 --retry-delay 2 -o "$archive" "$url"
    tar -xJf "$archive" -C "$dir"
    rm -f "$archive"
}

if ready; then
    echo "ESP32 emulator tools are already installed"
else
    fetch "$xtensa_url" "$root/xtensa"
    fetch "$qemu_url" "$root/qemu"
    rm -rf "$root/py"
    python3 -m venv "$root/py"
    "$root/py/bin/pip" install --disable-pip-version-check "esptool==5.4.0" pyserial
    printf '%s\n' "$stamp_text" > "$root/stamp"
fi

gcc=$(first_file "$root/xtensa" xtensa-esp32s3-elf-gcc)
qemu=$(first_file "$root/qemu" qemu-system-xtensa)
if [ -z "$gcc" ] || [ -z "$qemu" ]; then
    echo "toolchain or qemu did not unpack (gcc=${gcc:-missing} qemu=${qemu:-missing})" >&2
    exit 1
fi
chmod +x "$gcc" "$qemu" "$root/py/bin/esptool" "$root/py/bin/python"

{
    echo "XTENSA_BIN=$(dirname "$gcc")"
    echo "ESPTOOL=$root/py/bin/esptool"
    echo "BOARD_PYTHON=$root/py/bin/python"
    echo "SILICA_QEMU=$qemu"
    echo "SILICA_BOARD_EMULATOR=qemu"
} >> "${GITHUB_ENV:?}"
echo "XTENSA_BIN=$(dirname "$gcc")"
echo "SILICA_QEMU=$qemu"
