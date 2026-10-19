#!/usr/bin/env bash
# Faza budowania Xcode: kopiuje bifold-mtp obok programu w pakiecie (Contents/MacOS) i podpisuje go
# (podpis pakietu wymaga podpisanych programów w środku; wydanie podpisuje je ponownie: scripts/signing.sh).
set -euo pipefail
SRC="$SRCROOT/ThirdParty/build/bifold-mtp"
DEST="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/bifold-mtp"
if [ -x "$SRC" ]; then
    cp -f "$SRC" "$DEST"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DEST"
else
    rm -f "$DEST"
fi
