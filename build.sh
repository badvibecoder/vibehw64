#!/usr/bin/env sh
# build.sh — build the release binary at bin/vibehw64.
#
# raylib is linked statically (see scripts/build-raylib-static.sh). The extra
# linker flags cover what the static archive needs but Odin's vendor:raylib
# import block does not declare: OpenGL, libm, and the X11 extension libraries
# used by the bundled GLFW backend.
#
# Prerequisites:
#   - odin
#   - scripts/build-raylib-static.sh has been run once (installs libraylib.a)
#   - at runtime: libX11, libGL, and the X extension libs (standard on any
#     desktop Linux; no raylib and no Odin needed on the target machine)

set -eu

ODIN_ROOT=$(odin root)
RAYLIB_A="$ODIN_ROOT/vendor/raylib/linux/libraylib.a"

if [ ! -f "$RAYLIB_A" ] || [ -L "$RAYLIB_A" ]; then
	echo "error: static raylib archive not found at $RAYLIB_A" >&2
	echo "       run scripts/build-raylib-static.sh first" >&2
	exit 1
fi

mkdir -p bin
odin build src \
	-out:bin/vibehw64 \
	-o:speed \
	-define:RAYLIB_SHARED=false \
	-extra-linker-flags:"-lGL -lm -lrt -lX11 -lXrandr -lXinerama -lXcursor -lXi -lXfixes -lwayland-client -lwayland-cursor -lwayland-egl -lxkbcommon"

printf 'built %s (%s)\n' bin/vibehw64 "$(du -h bin/vibehw64 | cut -f1)"
