#!/bin/sh
# Build Graphite desktop on Ubuntu and package it as a portable AppImage.
#
# No Void Linux, no xbps. This runs on a plain Ubuntu runner and drives
# Graphite's own build tool (`cargo run build desktop`), which downloads the
# branding assets, installs the npm deps, compiles the WebAssembly frontend,
# bundles it with Vite, generates the third-party license list, and links the
# native desktop binary. Upstream's Linux bundler is a stub
# ("Bundling for Linux is not yet implemented"), so the CEF runtime is bundled
# here — the same layout the Void package uses, which is known to run.
#
# Environment (all optional):
#   GRAPHITE_COMMIT   Source commit (empty = latest latest-stable)
#   VERSION           Version string (empty = 0.0.0git<shortcommit>)
#   CEF_VERSION / BINARYEN_VERSION / RUST_VERSION / WASM_BINDGEN_VERSION
#   WORKDIR           Build dir (default /tmp/graphite-build)
#   ARTIFACTS         Output dir (default ./artifacts)
#   INSTALL_DEPS      1 = apt-get build deps (default 1)
#   APPIMAGETOOL_URL / RUNTIME_URL
set -eu

GRAPHITE_COMMIT="${GRAPHITE_COMMIT:-}"
CEF_VERSION="${CEF_VERSION:-149.0.5+g6770623+chromium-149.0.7827.197}"
BINARYEN_VERSION="${BINARYEN_VERSION:-130}"
RUST_VERSION="${RUST_VERSION:-1.96.0}"
WASM_BINDGEN_VERSION="${WASM_BINDGEN_VERSION:-0.2.121}"
VERSION="${VERSION:-}"
WORKDIR="${WORKDIR:-/tmp/graphite-build}"
ARTIFACTS="${ARTIFACTS:-$PWD/artifacts}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
APPIMAGETOOL_URL="${APPIMAGETOOL_URL:-https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage}"
RUNTIME_URL="${RUNTIME_URL:-https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64}"

CEF_SHA256="38f18c0499afbcb88b7410e7881430c7b2e64c6188e7d01c7ac25d20b49ea9cb"
BINARYEN_SHA256="0a18362361ad05465118cd8eeb72edaeec89de6894bc283576ef4e07aa3babcc"

log() { printf '>> %s\n' "$*"; }

# --- Resolve the commit -------------------------------------------------
if [ -z "$GRAPHITE_COMMIT" ]; then
	GRAPHITE_COMMIT=$(git ls-remote https://github.com/GraphiteEditor/Graphite.git latest-stable | awk '{print $1}')
fi
SHORT=$(printf '%s' "$GRAPHITE_COMMIT" | cut -c1-7)
[ -z "$VERSION" ] && VERSION="0.0.0git${SHORT}"
log "Graphite commit : $GRAPHITE_COMMIT"
log "Version         : $VERSION"

# --- Ubuntu build dependencies ------------------------------------------
# Build tools + the -dev libraries Graphite links against (mapped from the
# upstream Nix flake's buildInputs), plus the runtime libraries CEF/Chromium
# needs so they can be bundled into the AppImage.
if [ "$INSTALL_DEPS" = 1 ]; then
	log "Installing build dependencies (apt)..."
	export DEBIAN_FRONTEND=noninteractive
	sudo apt-get update -qq
	sudo apt-get install -y --no-install-recommends \
		build-essential cmake ninja-build lld pkg-config git curl ca-certificates \
		python3 patchelf file desktop-file-utils \
		libwayland-dev libvulkan-dev libgl1-mesa-dev libegl1-mesa-dev \
		libssl-dev libraw-dev libxkbcommon-dev libxcursor-dev libxcb1-dev libx11-dev \
		libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libcups2 \
		libasound2 libdbus-1-3 libglib2.0-0 libcairo2 libpango-1.0-0 libexpat1 \
		libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 libgbm1 \
		libfontconfig1 libfreetype6
fi

mkdir -p "$WORKDIR" "$WORKDIR/distfiles" "$ARTIFACTS"
cd "$WORKDIR"

# --- Rust toolchain with the wasm32 target ------------------------------
export RUSTUP_HOME="${RUSTUP_HOME:-$WORKDIR/rustup}"
export CARGO_HOME="${CARGO_HOME:-$WORKDIR/cargo}"
export PATH="$CARGO_HOME/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
	curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal \
		--default-toolchain "$RUST_VERSION" --no-modify-path
fi
rustup toolchain install "$RUST_VERSION" --profile minimal
rustup default "$RUST_VERSION"
rustup target add wasm32-unknown-unknown

# --- Build helpers cargo-run expects on PATH ----------------------------
# wasm-opt (binaryen), wasm-bindgen (exact version), cargo-about.
if ! command -v wasm-opt >/dev/null 2>&1; then
	curl -fL --retry 3 -o distfiles/binaryen.tar.gz \
		"https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/binaryen-version_${BINARYEN_VERSION}-x86_64-linux.tar.gz"
	printf '%s  %s\n' "$BINARYEN_SHA256" distfiles/binaryen.tar.gz | sha256sum -c -
	mkdir -p binaryen && tar -xzf distfiles/binaryen.tar.gz -C binaryen --strip-components=1
	export PATH="$WORKDIR/binaryen/bin:$PATH"
fi
command -v wasm-bindgen >/dev/null 2>&1 || cargo install -f "wasm-bindgen-cli@${WASM_BINDGEN_VERSION}"
command -v cargo-about  >/dev/null 2>&1 || cargo install cargo-about

# --- CEF (linked against at build time, bundled at package time) ---------
log "Fetching CEF ${CEF_VERSION}..."
curl -fL --retry 3 -o distfiles/cef.tar.bz2 \
	"https://cef-builds.spotifycdn.com/cef_binary_${CEF_VERSION}_linux64_minimal.tar.bz2"
printf '%s  %s\n' "$CEF_SHA256" distfiles/cef.tar.bz2 | sha256sum -c -
rm -rf cef && mkdir -p cef && tar -xjf distfiles/cef.tar.bz2 -C cef --strip-components=1
export CEF_PATH="$WORKDIR/cef"

# --- Graphite source ----------------------------------------------------
log "Fetching Graphite source..."
curl -fL --retry 3 -o distfiles/graphite-src.tar.gz \
	"https://github.com/GraphiteEditor/Graphite/archive/${GRAPHITE_COMMIT}.tar.gz"
rm -rf src && mkdir -p src && tar -xzf distfiles/graphite-src.tar.gz -C src --strip-components=1
cd src

# Drop the desktop "gpu" feature: its raster shaders need the rust-gpu SPIR-V
# nightly toolchain. Raster nodes fall back to CPU; the rest is unaffected.
sed -i 's/recommended = \["gpu", "accelerated_paint"\]/recommended = ["accelerated_paint"]/' \
	desktop/Cargo.toml

# The source tarball has no .git, so hand the build the commit metadata.
export GRAPHITE_GIT_COMMIT_HASH="$GRAPHITE_COMMIT"
export GRAPHITE_GIT_COMMIT_BRANCH="latest-stable"
export GRAPHITE_GIT_COMMIT_DATE="$(date -u +%Y-%m-%dT00:00:00Z)"
export CARGO_PROFILE_RELEASE_LTO=off
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_INCREMENTAL=0
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=-fuse-ld=lld"

# --- The actual build ---------------------------------------------------
# cargo-run downloads branding, installs npm deps, builds+optimizes the wasm,
# runs Vite, generates the license list, and links target/release/graphite.
log "Building Graphite desktop (cargo run build desktop)..."
cargo run --locked build desktop

BIN="$WORKDIR/src/target/release/graphite"
[ -f "$BIN" ] || { log "expected binary not found at $BIN"; exit 1; }

# --- Assemble the AppDir ------------------------------------------------
log "Assembling AppDir..."
APPDIR="$WORKDIR/Graphite.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/lib/graphite/cef"

install -Dm755 "$BIN" "$APPDIR/usr/lib/graphite/graphite"
cp -a "$CEF_PATH/Release/." "$APPDIR/usr/lib/graphite/cef/"
cp -a "$CEF_PATH/Resources/." "$APPDIR/usr/lib/graphite/cef/"
# CEF runs with no-sandbox, so the setuid helper is unnecessary.
rm -f "$APPDIR/usr/lib/graphite/cef/chrome-sandbox"
# Trim CEF locales to en-US + Spanish (CEF falls back to en-US).
find "$APPDIR/usr/lib/graphite/cef/locales" -name '*.pak' \
	! -name 'en-US*' ! -name 'es*' -delete 2>/dev/null || true

# Bundle the Chromium system libraries next to libcef.so so the AppImage runs
# on distros that don't ship them. Skip the truly-system libs (glibc, the GL
# driver, core X) which must come from the host to match its kernel/drivers.
log "Bundling CEF's system libraries..."
EXCLUDE='libc\.so|libc-|libstdc++|libgcc_s|libm\.so|libdl\.so|libpthread|librt\.so|ld-linux|libGL\.so|libGLX|libEGL\.so|libGLdispatch|libdrm|libX11\.so|libxcb\.so|libXext|libwayland'
ldd "$APPDIR/usr/lib/graphite/cef/libcef.so" "$BIN" 2>/dev/null \
	| awk '/=> \// {print $3}' | sort -u \
	| grep -vE "$EXCLUDE" \
	| while read -r lib; do
		[ -f "$lib" ] && cp -Ln "$lib" "$APPDIR/usr/lib/graphite/cef/" 2>/dev/null || true
	done

# Point the binary at the bundled CEF, and pull in the GL libs CEF dlopen's,
# mirroring upstream's Nix rpath handling.
patchelf --set-rpath '$ORIGIN/cef' \
	--add-needed libGL.so --add-needed libEGL.so \
	"$APPDIR/usr/lib/graphite/graphite"

# AppRun: launch the bundled binary; LD_LIBRARY_PATH is a safety net over rpath.
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib/graphite/cef:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/lib/graphite/graphite" "$@"
APPRUN
chmod 755 "$APPDIR/AppRun"

# Desktop entry + icons (branding was downloaded into src/branding by cargo-run).
install -Dm644 desktop/assets/art.graphite.Graphite.desktop \
	"$APPDIR/usr/share/applications/art.graphite.Graphite.desktop"
cp desktop/assets/art.graphite.Graphite.desktop "$APPDIR/art.graphite.Graphite.desktop"
install -Dm644 branding/app-icons/graphite-256.png \
	"$APPDIR/usr/share/icons/hicolor/256x256/apps/art.graphite.Graphite.png"
cp branding/app-icons/graphite-256.png "$APPDIR/art.graphite.Graphite.png"
cp "$APPDIR/art.graphite.Graphite.png" "$APPDIR/.DirIcon"

# --- Build the AppImage -------------------------------------------------
log "Downloading appimagetool + runtime..."
curl -fL --retry 3 -o "$WORKDIR/appimagetool" "$APPIMAGETOOL_URL"
curl -fL --retry 3 -o "$WORKDIR/runtime-x86_64" "$RUNTIME_URL"
chmod +x "$WORKDIR/appimagetool"

OUT="$ARTIFACTS/Graphite-${VERSION}-x86_64.AppImage"
log "Building $OUT"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$WORKDIR/appimagetool" \
	--runtime-file "$WORKDIR/runtime-x86_64" --no-appstream \
	"$APPDIR" "$OUT"

chmod +x "$OUT"
( cd "$ARTIFACTS" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
log "Done: $OUT"
cat "$OUT.sha256"
