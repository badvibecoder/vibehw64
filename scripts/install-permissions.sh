#!/usr/bin/env sh
# install-permissions.sh — one-time setup so vibehw64 can read two things that are
# root-only by default.
#
#   1. RAPL energy counters (/sys/class/powercap/*/energy_uj)
#      Fixed with a udev rule: `energy_uj` is a sysfs *attribute*, so MODE=
#      cannot reach it; the rule chmods the attribute path for each powercap
#      device.
#
#   2. SMBIOS table (/sys/firmware/dmi/tables/DMI)
#      udev cannot help here at all: nothing in /sys/firmware/dmi has a uevent
#      or subsystem, so there is no device to match and RUN+= never fires. The
#      mode is therefore set by a small oneshot systemd unit that runs at boot,
#      and is started immediately on install.
#
# Both are re-applied automatically, so a reboot does not undo them.
#
# Usage:
#   scripts/install-permissions.sh              install (re-execs with sudo)
#   scripts/install-permissions.sh --uninstall  remove both again

set -eu

RULE_DIR=/etc/udev/rules.d
RULE="$RULE_DIR/99-vibehw64-power.rules"
UNIT=/etc/systemd/system/vibehw64-dmi-perms.service
DMI=/sys/firmware/dmi/tables/DMI

# Filenames used before the app was renamed to vibehw64. Removed on install and
# uninstall so a renamed app never leaves an orphaned rule or unit behind.
LEGACY_RULE="$RULE_DIR/99-odinhw-power.rules"
LEGACY_UNIT=/etc/systemd/system/odinhw-dmi-perms.service

if [ "$(id -u)" -ne 0 ]; then
	echo ">> elevation required (writes $RULE and $UNIT)"
	exec sudo "$0" "$@"
fi

if [ "${1:-}" = "--uninstall" ]; then
	rm -f "$RULE"
	rm -f "$LEGACY_RULE"
	if systemctl list-unit-files vibehw64-dmi-perms.service >/dev/null 2>&1; then
		systemctl disable --now vibehw64-dmi-perms.service >/dev/null 2>&1 || true
	fi
	if [ -f "$LEGACY_UNIT" ]; then
		systemctl disable --now odinhw-dmi-perms.service >/dev/null 2>&1 || true
	fi
	rm -f "$UNIT"
	rm -f "$LEGACY_UNIT"
	systemctl daemon-reload 2>/dev/null || true
	udevadm control --reload-rules 2>/dev/null || true
	echo ">> removed vibehw64 rules and unit (including any pre-rename leftovers)"
	echo ">> existing file modes stay until the files are recreated (reboot)"
	exit 0
fi

# --- 0. clean up pre-rename artefacts --------------------------------------
if [ -f "$LEGACY_RULE" ]; then
	rm -f "$LEGACY_RULE"
	echo ">> removed legacy $LEGACY_RULE"
fi
if [ -f "$LEGACY_UNIT" ]; then
	systemctl disable --now odinhw-dmi-perms.service >/dev/null 2>&1 || true
	rm -f "$LEGACY_UNIT"
	systemctl daemon-reload 2>/dev/null || true
	echo ">> removed legacy $LEGACY_UNIT"
fi

# --- 1. RAPL counters -------------------------------------------------------
cat > "$RULE" <<'EOF'
# vibehw64: allow unprivileged reads of RAPL energy counters (power sensors only).
ACTION=="add|change", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*",      RUN+="/bin/chmod 0444 /sys/class/powercap/%k/energy_uj"
ACTION=="add|change", SUBSYSTEM=="powercap", KERNEL=="intel-rapl-mmio:*", RUN+="/bin/chmod 0444 /sys/class/powercap/%k/energy_uj"
ACTION=="add|change", SUBSYSTEM=="powercap", KERNEL=="amd-rapl:*",        RUN+="/bin/chmod 0444 /sys/class/powercap/%k/energy_uj"
EOF
chmod 644 "$RULE"
udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=powercap

# --- 2. SMBIOS table --------------------------------------------------------
cat > "$UNIT" <<'EOF'
[Unit]
Description=vibehw64: allow unprivileged reads of the SMBIOS/DMI table
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'chmod 0444 /sys/firmware/dmi/tables/DMI 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT"
systemctl daemon-reload
systemctl enable --now vibehw64-dmi-perms.service >/dev/null 2>&1 || true

sleep 1

# --- verify -----------------------------------------------------------------
echo ">> installed $RULE"
echo ">> installed $UNIT (enabled at boot)"
FAILED=0
for f in /sys/class/powercap/*/energy_uj; do
	[ -e "$f" ] || continue
	printf '>> %s -> %s\n' "$f" "$(stat -c '%A' "$f")"
	case "$f" in
	*/intel-rapl:*|*/intel-rapl-mmio:*|*/amd-rapl:*)
		[ "$(stat -c '%a' "$f")" = "444" ] || FAILED=1
		;;
	esac
done
if [ -e "$DMI" ]; then
	printf '>> %s -> %s\n' "$DMI" "$(stat -c '%A' "$DMI")"
	[ "$(stat -c '%a' "$DMI")" = "444" ] || FAILED=1
else
	echo ">> no $DMI (kernel without dmi-sysfs); memory speed falls back to SPD"
fi

if [ "$FAILED" -ne 0 ]; then
	echo "!! some targets are still not 0444; re-run or inspect with 'systemctl status vibehw64-dmi-perms'" >&2
	exit 1
fi
echo ">> power and SMBIOS are readable now; start vibehw64"
