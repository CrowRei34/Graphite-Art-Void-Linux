#!/bin/sh
# Build Graphite desktop for Void Linux and package it as an .xbps file.
#
# Designed to run inside a Void Linux (glibc) container, but it also works
# on any Void machine: just `sh ci/build.sh`.
#
# All build logic mirrors srcpkgs/graphite/template so the result matches a
# native xbps-src build (minus the masterdir chroot, which CI doesn't need).
#
# Configuration is via environment variables (all have sensible defaults):
#   GRAPHITE_COMMIT     Source commit (empty = auto-detect latest latest-stable)
#   VERSION             Package version string (empty = 0.0.0git<shortcommit>)
#   REVISION            Package revision (default 1)
#   CEF_VERSION         Chromium Embedded Framework version
#   BINARYEN_VERSION    binaryen version (provides wasm-opt)
#   RUST_VERSION        rustup toolchain version
#   WASM_BINDGEN_VERSION  wasm-bindgen-cli version (must match Cargo.lock)
#   BRANDING_COMMIT     graphite-branded-assets commit
#   WORKDIR             Build directory (default /tmp/graphite-build)
#   ARTIFACTS           Where to write the .xbps (default /work/artifacts)
#   INSTALL_DEPS        1 = install Void build deps via xbps-install (default 1)
#   CARGO_BUILD_JOBS    Parallel cargo jobs (default 2)
set -eu

GRAPHITE_COMMIT="${GRAPHITE_COMMIT:-}"
CEF_VERSION="${CEF_VERSION:-149.0.5+g6770623+chromium-149.0.7827.197}"
BINARYEN_VERSION="${BINARYEN_VERSION:-130}"
RUST_VERSION="${RUST_VERSION:-1.96.0}"
WASM_BINDGEN_VERSION="${WASM_BINDGEN_VERSION:-0.2.121}"
BRANDING_COMMIT="${BRANDING_COMMIT:-0d004aa61e6b48d316e8e5db6d59ccc4788f192d}"
VERSION="${VERSION:-}"
REVISION="${REVISION:-1}"
WORKDIR="${WORKDIR:-/tmp/graphite-build}"
ARTIFACTS="${ARTIFACTS:-/work/artifacts}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"

# Fixed distfile checksums (these pinned versions never change).
CEF_SHA256="38f18c0499afbcb88b7410e7881430c7b2e64c6188e7d01c7ac25d20b49ea9cb"
BINARYEN_SHA256="0a18362361ad05465118cd8eeb72edaeec89de6894bc283576ef4e07aa3babcc"
BRANDING_SHA256="772d64518be43c99977ba56f69e574531c56e83d2df2f42ab066f77f74b0dd1f"

log() { printf '>> %s\n' "$*"; }

# --- Resolve the Graphite commit to build -------------------------------
if [ -z "$GRAPHITE_COMMIT" ]; then
	GRAPHITE_COMMIT=$(git ls-remote https://github.com/GraphiteEditor/Graphite.git latest-stable | awk '{print $1}')
fi
SHORT=$(printf '%s' "$GRAPHITE_COMMIT" | cut -c1-7)
[ -z "$VERSION" ] && VERSION="0.0.0git${SHORT}"
PKGVER="graphite-${VERSION}_${REVISION}"
log "Graphite commit : $GRAPHITE_COMMIT"
log "Package version : $PKGVER"

# --- Install Void build dependencies (skip with INSTALL_DEPS=0) ---------
if [ "$INSTALL_DEPS" = 1 ]; then
	log "Installing build dependencies..."
	xbps-install -Sy xbps
	xbps-install -y base-devel git curl python3 nodejs rustup cmake ninja lld \
		patchelf pkg-config tar libarchive \
		MesaLib-devel libgbm-devel vulkan-loader-devel wayland-devel \
		openssl-devel libraw-devel libxkbcommon-devel libXcursor-devel \
		libxcb-devel libX11-devel fontconfig-devel freetype-devel
fi

mkdir -p "$WORKDIR" "$WORKDIR/distfiles" "$ARTIFACTS"
cd "$WORKDIR"

# --- Download distfiles (cached + checksum-verified where pinned) --------
download() {
	url="$1"; out="$2"; sha="${3:-}"
	if [ -f "$out" ] && [ -s "$out" ]; then
		log "cached: $(basename "$out")"
	else
		log "downloading: $(basename "$out")"
		curl -fL --retry 3 -o "$out" "$url"
	fi
	if [ -n "$sha" ]; then
		printf '%s  %s\n' "$sha" "$out" | sha256sum -c - \
			|| { log "checksum mismatch: $out"; exit 1; }
	fi
}

download "https://github.com/GraphiteEditor/Graphite/archive/${GRAPHITE_COMMIT}.tar.gz" \
	"$WORKDIR/distfiles/graphite-src.tar.gz"
download "https://cef-builds.spotifycdn.com/cef_binary_${CEF_VERSION}_linux64_minimal.tar.bz2" \
	"$WORKDIR/distfiles/cef.tar.bz2" "$CEF_SHA256"
download "https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/binaryen-version_${BINARYEN_VERSION}-x86_64-linux.tar.gz" \
	"$WORKDIR/distfiles/binaryen.tar.gz" "$BINARYEN_SHA256"
download "https://github.com/Keavon/graphite-branded-assets/archive/${BRANDING_COMMIT}.tar.gz" \
	"$WORKDIR/distfiles/branding.tar.gz" "$BRANDING_SHA256"

# --- Extract ------------------------------------------------------------
log "Extracting distfiles..."
rm -rf src cef .binaryen branding
mkdir -p src cef .binaryen branding
tar -xzf "$WORKDIR/distfiles/graphite-src.tar.gz" -C src --strip-components=1
tar -xjf "$WORKDIR/distfiles/cef.tar.bz2" -C cef --strip-components=1
tar -xzf "$WORKDIR/distfiles/binaryen.tar.gz" -C .binaryen --strip-components=1
tar -xzf "$WORKDIR/distfiles/branding.tar.gz" -C branding --strip-components=1

# --- Disable the "gpu" feature ------------------------------------------
# Needs the rust-gpu SPIR-V nightly toolchain (not packaged in Void).
# Raster nodes fall back to CPU; the rest of the editor is unaffected.
sed -i 's/recommended = \["gpu", "accelerated_paint"\]/recommended = ["accelerated_paint"]/' \
	src/desktop/Cargo.toml

# --- Rust toolchain with the wasm32 target ------------------------------
# Void's "rust" package lacks the wasm32-unknown-unknown target, so we
# install a rustup-managed toolchain. RUSTUP_HOME/CARGO_HOME point at
# persistent paths so CI cache mounts reuse them across runs.
export RUSTUP_HOME="/var/cache/graphite-rustup"
export CARGO_HOME="/var/cache/graphite-cargo"
mkdir -p "$CARGO_HOME/bin" "$RUSTUP_HOME"
export PATH="$CARGO_HOME/bin:$PATH"
rustup-init -y --profile minimal --default-toolchain "$RUST_VERSION" --no-modify-path
# rustup-init -c treats wasm32 as a component and skips it; add as a target.
rustup target add wasm32-unknown-unknown
cargo install --jobs 2 "wasm-bindgen-cli@${WASM_BINDGEN_VERSION}"

export PATH="$WORKDIR/.binaryen/bin:$PATH"
export CEF_PATH="$WORKDIR/cef"

# Source is a tarball (no .git), so feed commit metadata explicitly.
export GRAPHITE_GIT_COMMIT_HASH="$GRAPHITE_COMMIT"
export GRAPHITE_GIT_COMMIT_BRANCH="latest-stable"
export GRAPHITE_GIT_COMMIT_DATE="$(date -u +%Y-%m-%dT00:00:00Z)"

# Shrink release artifacts (upstream defaults to thin LTO + debuginfo).
export CARGO_PROFILE_RELEASE_LTO=off
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_INCREMENTAL=0
export CARGO_BUILD_JOBS="$CARGO_BUILD_JOBS"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
# Use lld only for the native x86_64 target (the wasm linker rejects -fuse-ld).
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=-fuse-ld=lld"
export CC=cc CXX=c++

cd "$WORKDIR/src"

# 1) Frontend npm dependencies
log "Installing npm dependencies..."
cd frontend
npm ci --include=dev --prefer-offline --no-audit --no-fund
cd "$WORKDIR/src"

# 2) Build the editor wasm wrapper (native feature, release)
log "Building WebAssembly wrapper..."
cargo build --lib --package graphite-wasm-wrapper \
	--target wasm32-unknown-unknown --release \
	--no-default-features --features native

# 3) Generate JS/wasm glue, then optimize the wasm for size
log "Running wasm-bindgen + wasm-opt..."
wasm-bindgen --target web --out-name graphite_wasm_wrapper \
	--out-dir frontend/wrapper/pkg --no-demangle \
	target/wasm32-unknown-unknown/release/graphite_wasm_wrapper.wasm
wasm-opt -Oz -g \
	frontend/wrapper/pkg/graphite_wasm_wrapper_bg.wasm \
	-o frontend/wrapper/pkg/graphite_wasm_wrapper_bg.wasm

# 4) Bundle the frontend with Vite (native mode -> frontend/dist)
log "Bundling frontend with Vite..."
cd frontend
node_modules/vite/bin/vite.js build --mode native
cd "$WORKDIR/src"

# Free the ~1 GB wasm build tree (native desktop build doesn't need it).
rm -rf target/wasm32-unknown-unknown

# graphite-desktop embeds desktop/third-party-licenses.txt.xz at compile time.
# The upstream generator links CEF and needs CEF runtime libs to run, which we
# don't have in the build env. Generate a placeholder .xz with python3+lzma.
log "Generating licenses placeholder..."
python3 -c 'import lzma,pathlib; p=pathlib.Path("'"$WORKDIR/src"'/desktop/third-party-licenses.txt.xz"); p.write_bytes(lzma.compress(b"Graphite - Third-party Licenses (placeholder)\n\nGraphite is licensed under the Apache License, Version 2.0.\nSee /usr/share/licenses/graphite/LICENSE.txt.\n\nThis package bundles the Chromium Embedded Framework (CEF) 149, licensed\nunder the BSD-3-Clause License, plus Chromium components under their\nrespective licenses. Full CEF/Chromium credits:\nhttps://cef-builds.spotifycdn.com/\n", preset=9))'

# 5) Build the desktop binary (release; gpu disabled above)
log "Building desktop binary (this is the long step)..."
cargo build --release --package graphite-desktop-platform-linux

# --- Assemble the package tree (mirrors do_install) ---------------------
log "Assembling package tree..."
DEST="$WORKDIR/pkg"
rm -rf "$DEST"
mkdir -p "$DEST/usr/lib/graphite/cef"
install -Dm755 "$WORKDIR/src/target/release/graphite" "$DEST/usr/lib/graphite/graphite"
cp -a "$WORKDIR/cef/Release/." "$DEST/usr/lib/graphite/cef/"
cp -a "$WORKDIR/cef/Resources/." "$DEST/usr/lib/graphite/cef/"
rm -f "$DEST/usr/lib/graphite/cef/chrome-sandbox"
# Trim CEF locales: keep en-US + Spanish, delete the rest (CEF falls back to en-US).
find "$DEST/usr/lib/graphite/cef/locales" -name '*.pak' \
	! -name 'en-US*' ! -name 'es*' -delete

# Point the binary at the bundled CEF libraries ($ORIGIN/cef).
patchelf --set-rpath '$ORIGIN/cef' "$DEST/usr/lib/graphite/graphite"

# Wrapper so the app is launchable as `graphite`.
mkdir -p "$DEST/usr/bin"
cat > "$DEST/usr/bin/graphite" <<'WRAPPER'
#!/bin/sh
exec /usr/lib/graphite/graphite "$@"
WRAPPER
chmod 755 "$DEST/usr/bin/graphite"

# Desktop entry + icons + license.
install -Dm644 "$WORKDIR/src/desktop/assets/art.graphite.Graphite.desktop" \
	"$DEST/usr/share/applications/art.graphite.Graphite.desktop"
install -Dm644 "$WORKDIR/branding/app-icons/graphite.svg" \
	"$DEST/usr/share/icons/hicolor/scalable/apps/art.graphite.Graphite.svg"
for s in 128 256 512; do
	install -Dm644 "$WORKDIR/branding/app-icons/graphite-${s}.png" \
		"$DEST/usr/share/icons/hicolor/${s}x${s}/apps/art.graphite.Graphite.png"
done
install -Dm644 "$WORKDIR/src/LICENSE.txt" \
	"$DEST/usr/share/licenses/graphite/LICENSE.txt"

# --- Create the .xbps ---------------------------------------------------
DEPS="mesa mesa-dri libglvnd libgbm vulkan-loader wayland openssl libraw \
libxkbcommon libXcursor libxcb libX11 libXcomposite libXdamage libXext \
libXfixes libXrandr nss nspr libcups alsa-lib dbus-libs glib cairo pango atk \
at-spi2-core expat eudev-libudev fontconfig freetype hicolor-icon-theme \
desktop-file-utils"

log "Creating XBPS package: $PKGVER"
cd "$WORKDIR"
xbps-create -A x86_64 -n "$PKGVER" \
	-s "Node-based procedural 2D vector & raster graphics editor (desktop, alpha)" \
	-H "https://graphite.art" \
	-l "Apache-2.0" \
	-m "CrowRei34 <235182716+CrowRei34@users.noreply.github.com>" \
	-c "https://github.com/GraphiteEditor/Graphite/releases" \
	-P "cmd:graphite-${VERSION}_${REVISION}" \
	-D "$DEPS" \
	-B "ci-build" \
	"$DEST"

mv "$PKGVER.x86_64.xbps" "$ARTIFACTS/"
( cd "$ARTIFACTS" && sha256sum "$PKGVER.x86_64.xbps" > "$PKGVER.x86_64.xbps.sha256" )
log "Done: $ARTIFACTS/$PKGVER.x86_64.xbps"
cat "$ARTIFACTS/$PKGVER.x86_64.xbps.sha256"
