#!/usr/bin/env bash
#
# Turn `flutter build linux --release` output into a .deb and an AppImage.
#
#   bash linux/packaging/build_packages.sh 2026.7.27
#
# Run from the project root, after the Flutter build. Both packages carry the
# same bundle; the .deb is for Debian and Ubuntu, the AppImage for everything
# else. Results land in dist/.

set -euo pipefail

VERSION="${1:?usage: build_packages.sh <version>}"
APP_ID="site.spencersmith.council"
BUNDLE="build/linux/x64/release/bundle"
DESKTOP="linux/packaging/${APP_ID}.desktop"
ICON="assets/icon/icon.png"
OUT="dist"

[ -d "$BUNDLE" ] || { echo "No bundle at $BUNDLE — run 'flutter build linux --release' first." >&2; exit 1; }

mkdir -p "$OUT"

# ---------------------------------------------------------------- .deb --------
# The bundle goes to /opt rather than being scattered across /usr: Flutter links
# its libraries with an rpath of $ORIGIN/lib, so the executable and its lib/
# directory have to stay side by side. /usr/bin/council is a symlink into it.
DEB_ROOT="$(mktemp -d)/council_${VERSION}_amd64"
install -d "$DEB_ROOT/DEBIAN" \
           "$DEB_ROOT/opt/council" \
           "$DEB_ROOT/usr/bin" \
           "$DEB_ROOT/usr/share/applications" \
           "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps"

cp -r "$BUNDLE"/. "$DEB_ROOT/opt/council/"
chmod +x "$DEB_ROOT/opt/council/council"
ln -s /opt/council/council "$DEB_ROOT/usr/bin/council"
cp "$ICON" "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps/${APP_ID}.png"
cp "$DESKTOP" "$DEB_ROOT/usr/share/applications/${APP_ID}.desktop"

# Only the shared libraries the bundle actually links against outside its own
# lib/ directory. Keep this in step with `ldd build/linux/x64/release/bundle/council`.
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: council
Version: ${VERSION}
Section: education
Priority: optional
Architecture: amd64
Depends: libc6, libgtk-3-0, libglib2.0-0, libstdc++6, liblzma5
Maintainer: Spencer Smith <council@spencersmith.site>
Homepage: https://spencersmith.site/council/
Description: Offline-first theology research app
 Council is a research tool for theological texts. The King James Version is
 built in, together with a search index and an on-device embedding model, so it
 works with no network connection and no account. Further works are downloaded
 from inside the app on request.
 .
 An AI backend is optional: Council can talk to Ollama on your own hardware or
 to a provider you hold the key for, and works fully as a search tool without
 either.
EOF

dpkg-deb --build --root-owner-group "$DEB_ROOT" "$OUT/Council-linux-amd64.deb"

# ------------------------------------------------------------ AppImage --------
APPDIR="$(mktemp -d)/Council.AppDir"
install -d "$APPDIR/usr/bin" \
           "$APPDIR/usr/share/applications" \
           "$APPDIR/usr/share/icons/hicolor/512x512/apps"

cp -r "$BUNDLE"/. "$APPDIR/usr/bin/"
chmod +x "$APPDIR/usr/bin/council"
cp "$DESKTOP" "$APPDIR/usr/share/applications/${APP_ID}.desktop"
cp "$ICON" "$APPDIR/usr/share/icons/hicolor/512x512/apps/${APP_ID}.png"

# appimagetool looks for the desktop entry and icon at the AppDir root, by name.
cp "$DESKTOP" "$APPDIR/${APP_ID}.desktop"
cp "$ICON" "$APPDIR/${APP_ID}.png"
ln -sf "${APP_ID}.png" "$APPDIR/.DirIcon"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
# Resolve through the symlink the AppImage runtime creates, so the binary is
# found next to its bundled lib/ directory whatever the mountpoint is.
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$PATH"
exec "$HERE/usr/bin/council" "$@"
EOF
chmod +x "$APPDIR/AppRun"

TOOL="$(mktemp -d)/appimagetool"
curl -fsSL -o "$TOOL" \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$TOOL"

# --appimage-extract-and-run avoids needing FUSE on the build machine; the
# resulting AppImage still uses FUSE normally on the user's machine.
ARCH=x86_64 "$TOOL" --appimage-extract-and-run \
  "$APPDIR" "$OUT/Council-linux-x86_64.AppImage"

chmod +x "$OUT/Council-linux-x86_64.AppImage"

echo
echo "Built:"
ls -lh "$OUT"
