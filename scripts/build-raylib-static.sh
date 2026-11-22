#!/usr/bin/env sh
# build-raylib-static.sh — build raylib statically and install it where
# Odin's vendor:raylib bindings expect it (vendor/raylib/linux/libraylib.a).
#
# Why: Odin's bindings declare raylib 6.0.0 and link either a shared
# libraylib.so.600 or a static linux/libraylib.a. Distro packages ship a newer
# shared lib (6.2), and the vendor tree contains no x86-64 static archive, so
# a default `odin build` fails at link time. Building the matching static
# archive once lets bin/vibehw64 carry raylib inside it, with no raylib
# dependency for anyone who runs the binary.
#
# Usage:
#   scripts/build-raylib-static.sh             # build + install (sudo for install)
#   scripts/build-raylib-static.sh --build-only # build into temp/ only
#   scripts/build-raylib-static.sh --force      # rebuild even if installed
#
# Env:
#   RAYLIB_TAG   raylib git tag to build        (default 6.0)
#   RAYLIB_SRC   clone location                 (default <repo>/temp/raylib-<tag>)
#   ODIN_ROOT    Odin install root              (default `odin root`)

set -eu

TAG="${RAYLIB_TAG:-6.0}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT="${RAYLIB_SRC:-$SCRIPT_DIR/temp/raylib-$TAG}"
ODIN_ROOT="${ODIN_ROOT:-$(odin root)}"
DEST="$ODIN_ROOT/vendor/raylib/linux/libraylib.a"

BUILD_ONLY=0
FORCE=0
for arg in "$@"; do
	case "$arg" in
		--build-only) BUILD_ONLY=1 ;;
		--force)      FORCE=1 ;;
		-h|--help)    sed -n '2,26p' "$0"; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

say() { printf '>> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v odin >/dev/null || die "odin not found in PATH"
command -v git  >/dev/null || die "git not found in PATH"
command -v make >/dev/null || die "make not found in PATH"

if [ "$FORCE" -eq 0 ] && [ -f "$DEST" ] && [ ! -L "$DEST" ]; then
	say "already installed: $DEST"
	say "pass --force to rebuild"
	exit 0
fi

if [ ! -d "$ROOT/src" ]; then
	say "cloning raylib $TAG -> $ROOT"
	mkdir -p "$(dirname "$ROOT")"
	git clone --depth 1 --branch "$TAG" https://github.com/raysan5/raylib "$ROOT"
fi

# GLFW is vendored in raylib's tree on some tags and a submodule on others.
if [ ! -f "$ROOT/src/external/glfw/include/GLFW/glfw3.h" ]; then
	say "initialising glfw submodule"
	git -C "$ROOT" submodule update --init --recursive --depth 1
fi

say "building libraylib.a (raylib $TAG, X11 + Wayland backends)"
make -C "$ROOT/src" PLATFORM=PLATFORM_DESKTOP \
	GLFW_LINUX_ENABLE_X11=TRUE \
	GLFW_LINUX_ENABLE_WAYLAND=TRUE \
	-j"$(nproc)"

[ -f "$ROOT/src/libraylib.a" ] || die "build produced no $ROOT/src/libraylib.a"

if [ "$BUILD_ONLY" -eq 1 ]; then
	say "build-only: archive at $ROOT/src/libraylib.a"
	exit 0
fi

say "installing -> $DEST (needs root)"
sudo install -D -m 644 "$ROOT/src/libraylib.a" "$DEST"
say "done"
