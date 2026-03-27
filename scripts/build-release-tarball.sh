#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:-${REPO_ROOT}/dist}"

version="$(sed -n 's/^KB_VERSION="\([^"]*\)"$/\1/p' "${REPO_ROOT}/bin/kb")"
if [[ -z "${version}" ]]; then
    echo "error: unable to determine kb version from bin/kb" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

stage_dir="${workdir}/kb-${version}"
mkdir -p "${stage_dir}"

cp -R \
    "${REPO_ROOT}/LICENSE" \
    "${REPO_ROOT}/Makefile" \
    "${REPO_ROOT}/README.md" \
    "${REPO_ROOT}/bin" \
    "${REPO_ROOT}/hooks" \
    "${REPO_ROOT}/lib" \
    "${REPO_ROOT}/templates" \
    "${stage_dir}/"

tarball="${OUTPUT_DIR}/kb-${version}.tar.gz"
tar -C "${workdir}" -czf "${tarball}" "kb-${version}"

printf '%s\n' "${tarball}"
