#!/usr/bin/env python3
"""Synthesize the AMD/Intel sysfs fixtures and run the probe against them.

The fixtures live in a temporary directory and are deleted afterwards unless
--keep is given. This replaces the old ARCHIVE/temp/fixture-* trees without
checking hundreds of tiny files into the repository.

Usage:
    ./build.sh
    python3 tests/run-fixtures.py
    python3 tests/run-fixtures.py --keep
"""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "bin" / "vibehw64"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def add_cpu(
    sysroot: Path,
    cpu: int,
    siblings: str,
    core_id: int,
    *,
    max_freq: int | None = None,
    cur_freq: int | None = None,
) -> None:
    base = sysroot / f"devices/system/cpu/cpu{cpu}"
    write(base / "topology/thread_siblings_list", siblings + "\n")
    write(base / "topology/core_id", f"{core_id}\n")
    write(base / "topology/physical_package_id", "0\n")
    if max_freq is not None:
        write(base / "cpufreq/cpuinfo_max_freq", f"{max_freq}\n")
    if cur_freq is not None:
        write(base / "cpufreq/scaling_cur_freq", f"{cur_freq}\n")


def add_ccd(sysroot: Path, cpu: int, shared: str, size: int) -> None:
    base = sysroot / f"devices/system/cpu/cpu{cpu}"
    write(base / "cache/index3/shared_cpu_list", shared + "\n")
    write(base / "cache/index3/size", f"{size}\n")


def make_amd(base: Path) -> Path:
    """5950X-like: 16 cores / 32 threads, two CCDs, one with a larger L3."""
    write(
        base / "proc/cpuinfo",
        "vendor_id\t: AuthenticAMD\n"
        "model name\t: AMD Ryzen 9 5950X 16-Core Processor\n",
    )
    sysroot = base / "sys"
    write(sysroot / "devices/system/cpu/online", "0-31\n")

    for cpu in range(16):
        add_cpu(
            sysroot,
            cpu,
            f"{cpu},{cpu + 16}",
            cpu % 8,
            max_freq=4900000,
            cur_freq=4000000 + cpu * 10,
        )
        shared = "0-7,16-23" if cpu < 8 else "8-15,24-31"
        add_ccd(sysroot, cpu, shared, 100663296 if cpu < 8 else 33554432)

    for cpu in range(16, 32):
        add_cpu(sysroot, cpu, f"{cpu - 16},{cpu}", (cpu - 16) % 8)

    return sysroot


def dmi_blob(dimms: list[tuple[str, str, int, int, int]]) -> bytes:
    """Minimal SMBIOS table with type 17 records + type 127 terminator."""
    out = bytearray()
    for index, (locator, part, size_mb, speed_mt, volt_mv) in enumerate(dimms):
        length = 0x54
        rec = bytearray(length)
        rec[0] = 17
        rec[1] = length
        struct.pack_into("<H", rec, 0x02, 0x1100 + index)
        struct.pack_into("<H", rec, 0x0C, size_mb)
        rec[0x10] = 1  # device locator string
        rec[0x11] = 2  # bank locator string
        struct.pack_into("<H", rec, 0x15, speed_mt)  # rated speed
        rec[0x1A] = 3  # part number string
        struct.pack_into("<H", rec, 0x20, speed_mt)  # configured speed
        struct.pack_into("<H", rec, 0x22, 1200)  # min voltage
        struct.pack_into("<H", rec, 0x24, 1350)  # max voltage
        struct.pack_into("<H", rec, 0x26, volt_mv)  # configured voltage
        out += rec
        for s in (locator, "BANK 0", part):
            out += s.encode("ascii") + b"\0"
        out += b"\0"

    term = bytearray(4)
    term[0] = 127
    term[1] = 4
    struct.pack_into("<H", term, 2, 0x7F00)
    out += term + b"\0\0"
    return bytes(out)


def make_intel(base: Path) -> Path:
    """12600K-like without PMU masks: 6 P + 4 E, P cores SMT."""
    write(
        base / "proc/cpuinfo",
        "vendor_id\t: GenuineIntel\n"
        "model name\t: 12th Gen Intel(R) Core(TM) i5-12600K\n",
    )
    sysroot = base / "sys"
    write(sysroot / "devices/system/cpu/online", "0-15\n")

    for cpu in range(6):
        add_cpu(
            sysroot,
            cpu,
            f"{cpu},{cpu + 6}",
            cpu,
            max_freq=4900000,
            cur_freq=4500000,
        )
    for cpu in range(6, 12):
        add_cpu(sysroot, cpu, f"{cpu - 6},{cpu}", cpu - 6)
    for cpu in range(12, 16):
        add_cpu(
            sysroot,
            cpu,
            f"{cpu}",
            cpu - 6,
            max_freq=3600000,
            cur_freq=3400000,
        )

    dmi = dmi_blob(
        [
            ("DIMM A1", "CMK32GX5M2B6000", 16384, 6000, 1350),
            ("DIMM B1", "CMK32GX5M2B6000", 16384, 6000, 1350),
        ]
    )
    (sysroot / "firmware/dmi/tables").mkdir(parents=True, exist_ok=True)
    (sysroot / "firmware/dmi/tables/DMI").write_bytes(dmi)
    return sysroot


def run_probe(sysroot: Path) -> str:
    proc = subprocess.run(
        [str(BIN), "--probe", "--ticks", "1", "--sys-root", str(sysroot)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"probe failed for {sysroot} (exit {proc.returncode})")
    return proc.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="keep generated trees")
    args = parser.parse_args()

    if not BIN.is_file():
        raise SystemExit(f"{BIN} not found; run ./build.sh first")

    work = Path(tempfile.mkdtemp(prefix="vibehw64-fixtures-"))
    try:
        amd = make_amd(work / "amd-5950x")
        intel = make_intel(work / "intel-12600k-fallback")

        amd_out = run_probe(amd)
        intel_out = run_probe(intel)

        checks = [
            (
                "AMD topology",
                amd_out,
                [
                    "16 physical cores",
                    "SMT yes",
                    "CCD 0 [3D]",
                    "CCD 1",
                    "Core 15",
                ],
            ),
            (
                "Intel frequency fallback + SMBIOS",
                intel_out,
                [
                    "10 physical cores",
                    "SMT yes",
                    "P-Cores",
                    "E-Cores",
                    "Installed Capacity",
                    "DIMM A1 Capacity",
                    "DIMM B1 Capacity",
                    "6000",
                ],
            ),
        ]
        failed = []
        for label, output, needles in checks:
            for needle in needles:
                if needle not in output:
                    failed.append(f"{label}: missing {needle!r}")
        if failed:
            for item in failed:
                print("FAIL:", item, file=sys.stderr)
            print("\n--- AMD probe ---\n" + amd_out)
            print("\n--- Intel probe ---\n" + intel_out)
            return 1

        print("PASS: AMD CCD/[3D] topology")
        print("PASS: Intel frequency-tier fallback")
        print("PASS: synthetic SMBIOS per-DIMM capacity/speed")
        if args.keep:
            print(f"fixtures kept at {work}")
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
