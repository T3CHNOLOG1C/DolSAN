#!/usr/bin/env bash
# Applies DolSAN's patch series (patches/series) on top of the vendored,
# pristine llvm-project checkout. Run this once per fresh clone/reset before
# building compiler-rt (see Phase 3 of extern/dolsan/PLANNING.md).
#
# The vendored tree is expected to be clean at llvm-project's pinned tag --
# this script fails loudly instead of silently re-applying (or half-applying)
# patches on top of an already-patched or otherwise dirty tree.
set -euo pipefail

DOLSAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLVM_DIR="${DOLSAN_ROOT}/llvm-project"
PATCH_DIR="${DOLSAN_ROOT}/patches"
SERIES="${PATCH_DIR}/series"

if [[ ! -d "${LLVM_DIR}/.git" ]]; then
    echo "error: ${LLVM_DIR} is not a git checkout -- run 'git submodule update --init' first" >&2
    exit 1
fi

if ! git -C "${LLVM_DIR}" diff --quiet -- compiler-rt || ! git -C "${LLVM_DIR}" diff --cached --quiet -- compiler-rt; then
    echo "error: ${LLVM_DIR}/compiler-rt has local changes -- refusing to apply patches on top of" \
         "a dirty tree. Run 'git -C ${LLVM_DIR} checkout -- compiler-rt' to reset it first." >&2
    exit 1
fi

if [[ ! -f "${SERIES}" ]]; then
    echo "error: ${SERIES} not found" >&2
    exit 1
fi

while IFS= read -r patch || [[ -n "${patch}" ]]; do
    [[ -z "${patch}" || "${patch}" == \#* ]] && continue
    echo "Applying ${patch}..."
    git -C "${LLVM_DIR}" apply --whitespace=nowarn "${PATCH_DIR}/${patch}"
done < "${SERIES}"

echo "All patches applied cleanly."
