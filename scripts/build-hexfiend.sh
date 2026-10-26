#!/bin/bash
# Buduje HexFiend.framework (submoduł ThirdParty/HexFiend) do ThirdParty/build/.
# Wywoływany przez `make bootstrap` i jako krok przed budowaniem celu Bifold (tylko gdy brak frameworka).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ThirdParty/build"
if [ -d "$OUT/HexFiend.framework" ] && [ "${1:-}" != "--force" ]; then
  exit 0
fi
if [ ! -f "$ROOT/ThirdParty/HexFiend/HexFiend_2.xcodeproj/project.pbxproj" ]; then
  echo "error: brak submodułu HexFiend — uruchom: git submodule update --init" >&2
  exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Czyste środowisko: zmienne budowania Xcode z zewnętrznego procesu nie mogą przeciekać.
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
  xcodebuild -project "$ROOT/ThirdParty/HexFiend/HexFiend_2.xcodeproj" -target HexFiend_Framework \
  -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET=27.0 \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$TMP" OBJROOT="$TMP/obj" build -quiet
mkdir -p "$OUT"
rm -rf "$OUT/HexFiend.framework"
cp -R "$TMP/Release/HexFiend.framework" "$OUT/"
echo "HexFiend.framework → $OUT"
