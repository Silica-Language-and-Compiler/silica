#!/bin/bash
# Install the latest released Silica compiler for one trial target, the way silica-cli's
# README says to (https://github.com/Silica-Language-and-Compiler/silica-cli#install),
# then point binaries/ at it.
# Host targets replace binaries/silica-compiler. ESP32-S3_raw also installs the cross
# compiler and replaces binaries/silica-compiler-ESP32-S3_raw. STM32-L476RG_qemu (the emulated
# Nucleo) installs the STM32-L476RG_raw cross compiler as binaries/silica-compiler-STM32-L476RG_raw;
# the workflow runs this only when that compiler is released (released_compiler_exists.sh).
#
# This is the latest release, not a compiler built from this commit.

set -euo pipefail

target="${1:?emit target}"
export SILICA_HOME="${RUNNER_TEMP:?}/silica-home"
# Raises the GitHub API rate limit for the compiler download.
export GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

rm -rf "$SILICA_HOME"
curl -fsSL https://github.com/Silica-Language-and-Compiler/silica-cli/releases/latest/download/install.sh | bash

silica="$SILICA_HOME/bin/silica"
case "$target" in
    ESP32-S3_raw)
        "$silica" update --target "$target"
        installed="$SILICA_HOME/bin/silica-compiler-ESP32_S3_raw"
        link="silica-compiler-ESP32-S3_raw"
        ;;
    STM32-L476RG_qemu|STM32-L476RG_raw)
        "$silica" update --target STM32-L476RG_raw
        installed="$SILICA_HOME/bin/silica-compiler-STM32_L476RG_raw"
        link="silica-compiler-STM32-L476RG_raw"
        ;;
    *)
        installed="$SILICA_HOME/bin/silica-compiler"
        link="silica-compiler"
        ;;
esac

if [ ! -e "$installed" ]; then
    echo "silica-cli did not install ${installed}" >&2
    ls -la "$SILICA_HOME/bin" >&2
    exit 1
fi

# Resolve the link to the versioned file (silica-<NNNNNN>-...) and copy that.
real="$(readlink -f "$installed")"
name="$(basename "$real")"
mkdir -p binaries
cp -p "$real" "binaries/${name}"
chmod +x "binaries/${name}"
ln -sfn "$name" "binaries/${link}"
echo "installed binaries/${link} -> ${name} (latest release)"
"$silica" version
{
    echo "### Compiler"
    echo "Trials for \`${target}\` use the latest released compiler \`${name}\`, installed with silica-cli."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
