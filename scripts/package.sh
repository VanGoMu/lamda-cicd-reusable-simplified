#!/usr/bin/env bash
# Builds the deployment ZIP of a Python function: same sources and requirements, same bytes.
# usage: package.sh <source-dir> <output.zip> [runtime=python3.13] [architecture=arm64]
# requirements.txt, if any, sits next to <source-dir> (in its parent folder).
set -euo pipefail

usage="usage: package.sh <source-dir> <output.zip> [runtime] [architecture]"
src="${1:?${usage}}"
out="${2:?${usage}}"
runtime="${3:-python3.13}"
arch="${4:-arm64}"
requirements="$(dirname "${src}")/requirements.txt"

stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT
cp -R "${src}/." "${stage}/"

if [[ -f "${requirements}" ]]; then
  # Wheels for Lambda's platform, not the runner's: compiled packages must match it.
  platform=manylinux2014_x86_64
  [[ "${arch}" == x86_64 ]] || platform=manylinux2014_aarch64
  python3 -m pip install --quiet --no-compile --only-binary=:all: --platform "${platform}" \
    --python-version "${runtime#python}" --target "${stage}" -r "${requirements}"
fi

rm -rf "${stage:?}/bin"
find "${stage}" -name __pycache__ -prune -exec rm -rf {} +
# Fixed permissions, timestamps and file order: the ZIP no longer depends on the checkout.
chmod -R u=rwX,go=rX "${stage}"
find "${stage}" -exec touch -h -d @0 {} +
mkdir -p "$(dirname "${out}")"
out="$(cd "$(dirname "${out}")" && pwd)/$(basename "${out}")"
rm -f "${out}"
(cd "${stage}" && find . -mindepth 1 | LC_ALL=C sort | zip -X -q -@ "${out}")
sha256sum "${out}"
