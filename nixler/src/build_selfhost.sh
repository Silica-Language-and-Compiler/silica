#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
binaries_dir="$repo_root/binaries"
selfhost_compiler="$binaries_dir/silica-compiler"

detect_binary_platform() {
    local os arch distro id_like

    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            case "$arch" in
                arm64) echo "macos-applesilicon" ;;
                x86_64) echo "macos-x86_64" ;;
                *) return 1 ;;
            esac
            ;;
        Linux)
            distro="unknown"
            id_like=""
            if [[ -r /etc/os-release ]]; then
                local ID="" ID_LIKE=""
                # shellcheck disable=SC1091
                . /etc/os-release
                distro="${ID:-unknown}"
                id_like="${ID_LIKE:-}"
            fi
            case "${distro}:${arch}" in
                debian:aarch64|ubuntu:aarch64) echo "debian-aarch64" ;;
                debian:x86_64|ubuntu:x86_64) echo "debian-x86_64" ;;
                *)
                    case " ${id_like} " in
                        *" debian "*)
                            case "$arch" in
                                aarch64) echo "debian-aarch64" ;;
                                x86_64) echo "debian-x86_64" ;;
                                *) return 1 ;;
                            esac
                            ;;
                        *) return 1 ;;
                    esac
                    ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

platform="${BUILD_SELFHOST_PLATFORM:-$(detect_binary_platform)}"

cd -- "$repo_root"

"$binaries_dir/update_silica_compiler_link.bash" "$platform"

exec make -C "$script_dir" SILICA_COMPILER="$selfhost_compiler" "$@"
