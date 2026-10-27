#!/usr/bin/env bash
# Faza budowania Xcode: kopiuje bifold-mtp obok programu w pakiecie (Contents/MacOS) i podpisuje go
# (podpis pakietu wymaga podpisanych programów w środku; wydanie podpisuje je ponownie: scripts/signing.sh).
set -euo pipefail
SRC="$SRCROOT/ThirdParty/build/bifold-mtp"
DEST="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/bifold-mtp"
# Faza działa przy każdym budowaniu (pomocnik mógł powstać od nowa po aktualizacji libmtp) — kopiuje tylko
# nowszy plik, żeby budowanie bez zmian nie zmieniało pakietu.
if [ -x "$SRC" ]; then
    [ -e "$DEST" ] && [ ! "$SRC" -nt "$DEST" ] && exit 0
    cp -f "$SRC" "$DEST"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DEST"
else
    rm -f "$DEST"
fi
