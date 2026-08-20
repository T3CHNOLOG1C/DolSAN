#!/usr/bin/env bash
# Stages a Clang resource directory that consumers can pass via
# -resource-dir=... to get DolSAN's patched ASan runtime instead of the
# system one, while everything else (builtins, profile, etc.) stays
# system-provided. Mirrors the system resource dir, then overlays only the
# asan files this project actually rebuilds.
#
# Usage: build_resource_dir.sh <clang-binary> <compiler-rt-build-dir> <dest-dir>
set -euo pipefail

CLANG_BIN="${1:?usage: build_resource_dir.sh <clang-binary> <compiler-rt-build-dir> <dest-dir>}"
CRT_BUILD_DIR="${2:?missing compiler-rt build dir}"
DEST_DIR="${3:?missing dest dir}"

SYSTEM_RESOURCE_DIR="$("${CLANG_BIN}" -print-resource-dir)"
if [[ ! -d "${SYSTEM_RESOURCE_DIR}" ]]; then
    echo "error: '${CLANG_BIN} -print-resource-dir' -> '${SYSTEM_RESOURCE_DIR}', not a directory" >&2
    exit 1
fi

CRT_LIB_DIR="${CRT_BUILD_DIR}/lib/linux"
if [[ ! -d "${CRT_LIB_DIR}" ]]; then
    echo "error: ${CRT_LIB_DIR} not found -- build the 'asan' compiler-rt target first" >&2
    exit 1
fi

rm -rf "${DEST_DIR}"
mkdir -p "$(dirname "${DEST_DIR}")"
cp -r "${SYSTEM_RESOURCE_DIR}" "${DEST_DIR}"

# Exact file set a legacy per-OS-layout ASan install ships for one arch
# (verified this session against `pacman -Ql compiler-rt`'s x86_64 subset).
# Enumerated explicitly, not a glob-everything-asan copy, so a future
# compiler-rt layout change that adds unexpected files gets noticed (missing
# source file -> loud cp error) instead of silently shipping something
# unvetted.
asan_files=(
    libclang_rt.asan-x86_64.a
    libclang_rt.asan-x86_64.a.syms
    libclang_rt.asan-x86_64.so
    libclang_rt.asan-preinit-x86_64.a
    libclang_rt.asan_cxx-x86_64.a
    libclang_rt.asan_cxx-x86_64.a.syms
    libclang_rt.asan_static-x86_64.a
)

mkdir -p "${DEST_DIR}/lib/linux"
for f in "${asan_files[@]}"; do
    cp "${CRT_LIB_DIR}/${f}" "${DEST_DIR}/lib/linux/${f}"
done

echo "Staged DolSAN resource dir at ${DEST_DIR}"
