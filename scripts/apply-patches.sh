#!/usr/bin/env bash
# Applies DolSAN's patch series (patches/series) on top of the vendored
# llvm-project checkout. Run before building compiler-rt (Phase 3 of
# extern/dolsan/PLANNING.md); CMake also calls this on every configure
# (see CMakeLists.txt), so this script is idempotent: a patch already
# applied is skipped rather than re-applied or treated as an error. Only an
# unexpected state (tree modified some other way, patch doesn't apply and
# isn't already applied either) fails loudly.
set -euo pipefail

DOLSAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLVM_DIR="${DOLSAN_ROOT}/llvm-project"
PATCH_DIR="${DOLSAN_ROOT}/patches"
SERIES="${PATCH_DIR}/series"

if ! git -C "${LLVM_DIR}" rev-parse --git-dir &>/dev/null; then
    echo "error: ${LLVM_DIR} is not a git checkout -- run 'git submodule update --init' first" >&2
    exit 1
fi

if [[ ! -f "${SERIES}" ]]; then
    echo "error: ${SERIES} not found" >&2
    exit 1
fi

while IFS= read -r patch || [[ -n "${patch}" ]]; do
    [[ -z "${patch}" || "${patch}" == \#* ]] && continue
    patch_path="${PATCH_DIR}/${patch}"

    if git -C "${LLVM_DIR}" apply --check --whitespace=nowarn "${patch_path}" 2>/dev/null; then
        echo "Applying ${patch}..."
        git -C "${LLVM_DIR}" apply --whitespace=nowarn "${patch_path}"
    elif git -C "${LLVM_DIR}" apply --check --reverse --whitespace=nowarn "${patch_path}" 2>/dev/null; then
        echo "${patch} already applied, skipping."
    else
        echo "error: ${patch} does not apply cleanly and is not already applied -- the vendored" \
             "tree may have local changes from something else. Run" \
             "'git -C ${LLVM_DIR} checkout -- compiler-rt' to reset it, then retry." >&2
        exit 1
    fi
done < "${SERIES}"

echo "Patch series up to date."
