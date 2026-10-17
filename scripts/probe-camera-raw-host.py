#!/usr/bin/env -S uv run
"""Compile and run isolated Camera Raw ABI probes; this is not an editor launcher."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import struct
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
MODES = ("load", "initialize", "prepare", "read")


def write_fixture(path: Path) -> None:
    """Write a minimal uncompressed RGB TIFF without external dependencies."""
    width = height = 64
    fields = [
        (256, 4, 1, width), (257, 4, 1, height), (258, 3, 3, 0),
        (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, 0),
        (277, 3, 1, 3), (278, 4, 1, height),
        (279, 4, 1, width * height * 3), (284, 3, 1, 1),
    ]
    extra_offset = 8 + 2 + len(fields) * 12 + 4
    pixel_offset = extra_offset + 6
    data = bytearray(b"II" + struct.pack("<HIH", 42, 8, len(fields)))
    for tag, kind, count, value in fields:
        value = extra_offset if tag == 258 else pixel_offset if tag == 273 else value
        data.extend(struct.pack("<HHII", tag, kind, count, value))
    data.extend(struct.pack("<IHHH", 0, 8, 8, 8))
    for y in range(height):
        for x in range(width):
            data.extend((x * 4, y * 4, 128))
    path.write_bytes(data)


def run_probe(binary: Path, plugin: Path, mode: str, image: Path, timeout: float,
              log: Path, host_signature: str, api_version: int, services: str,
              app_environment: bool, resource_map: bool, capture_window: bool, automation: str) -> dict:
    command = [str(binary), str(plugin), mode, str(image), host_signature, str(api_version), services,
               "app" if app_environment else "cli", "resources" if resource_map else "no-resources",
               str(log.parent) if capture_window else "", automation]
    print(f"\n--- {mode} (timeout {timeout:g}s) ---", flush=True)
    with log.open("wb") as log_stream:
        process = subprocess.Popen(command, stdout=log_stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        (log.parent / f"{mode}.pid").write_text(str(process.pid) + "\n")
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Only signal this probe's new process group, never a name/pattern match.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
    message = log.read_text(errors="replace")
    message += f"\nSupervisor: returncode={process.returncode} timed_out={timed_out}\n"
    log.write_text(message)
    prefixes = ("Resource map", "Plugin:", "Diagnostic", "Calling selector", "Returned selector",
                "Window:", "Window capture", "Automation", "***", "Supervisor")
    print("\n".join(line for line in message.splitlines() if line.startswith(prefixes)), flush=True)
    return {"mode": mode, "returncode": process.returncode, "timed_out": timed_out,
            "window_opened": "Window: Camera Raw " in message,
               "dialog_closed": any(f"Returned selector={selector} result={code} " in message
                                    for selector in (2, 20) for code in (-128, 0)) and not timed_out,
            "log": str(log)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", action="store_true", help="Use the experimentally verified Camera Raw 18 GUI profile")
    parser.add_argument("--sdk", type=Path, default=ROOT / ".build/camera-raw-sdk")
    parser.add_argument("--plugin", type=Path, default=Path(
        "/Library/Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin"))
    parser.add_argument("--mode", choices=("all", *MODES, "settings"), default="all")
    parser.add_argument("--timeout", type=float)
    parser.add_argument("--image", type=Path, help="Copy a test image to the probe directory before opening")
    parser.add_argument("--host-signature", help="Four ASCII characters for ABI compatibility experiments")
    parser.add_argument("--api-version", help="Advertise an SDK API version, e.g. 25.0.0, for diagnostics")
    parser.add_argument("--services", choices=("minimal", "public"))
    parser.add_argument("--app-environment", action="store_true", help="Run inside a native .app bundle and finish AppKit launch")
    parser.add_argument("--resource-map", action="store_true", help="Open the plug-in bundle's native resource map")
    parser.add_argument("--capture-window", action="store_true", help="Capture only this helper's Camera Raw window using AppKit")
    parser.add_argument("--automation", choices=("none", "cancel", "edit-save"), default="none",
                        help="Exercise only this helper's native Camera Raw controls")
    args = parser.parse_args()
    args.timeout = args.timeout if args.timeout is not None else (300 if args.editor else 15)
    args.host_signature = args.host_signature or ("8BIM" if args.editor else "PBrw")
    args.api_version = args.api_version or ("25.0.0" if args.editor else None)
    args.services = args.services or ("public" if args.editor else "minimal")
    args.app_environment |= args.editor
    args.resource_map |= args.editor
    if args.editor:
        args.mode = "settings" if args.mode == "settings" else "read"
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if len(args.host_signature) != 4 or not args.host_signature.isascii():
        parser.error("--host-signature must contain four ASCII characters")
    if args.automation == "edit-save" and not shutil.which("exiftool"):
        parser.error("--automation edit-save requires ExifTool to verify the saved parameter")
    api_version = 0
    if args.api_version:
        try:
            major, minor, fix = (int(value) for value in args.api_version.split("."))
            if not (0 < major <= 65535 and 0 <= minor <= 255 and 0 <= fix <= 255):
                raise ValueError
            api_version = (major << 16) | (minor << 8) | fix
        except ValueError:
            parser.error("--api-version must be major.minor.fix with valid SDK field sizes")
    sdk = args.sdk.resolve() / "pluginsdk/photoshopapi"
    if sys.platform != "darwin" or not args.plugin.is_dir():
        parser.error("Requires macOS and an installed Camera Raw.plugin")
    if not (sdk / "photoshop/PIFormat.h").is_file():
        parser.error(f"Adobe SDK not found at {args.sdk}; see docs/camera-raw-host-probe.md")
    output = ROOT / ".build/camera-raw-host-results" / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    output.mkdir(parents=True)
    print(f"Results directory: {output}", flush=True)
    binary = output / "camera-raw-host-probe"
    if args.app_environment:
        contents = output / "Camera Raw Host Probe.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        binary = contents / "MacOS/camera-raw-host-probe"
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.photo-browser.camera-raw-host-probe",
            "CFBundleName": "Camera Raw Host Probe", "CFBundleExecutable": binary.name,
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1",
            "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
            "LSMinimumSystemVersion": "14.0",
        }))
    build = subprocess.run([
        "xcrun", "clang++", "-std=c++17", "-DMAC_ENV=1", "-Wno-deprecated-declarations",
        "-I", str(sdk / "photoshop"), "-I", str(sdk / "pica_sp"),
        "-framework", "Cocoa", "-framework", "Carbon",
        str(ROOT / "scripts/camera-raw-host-probe.mm"), "-o", str(binary),
    ], capture_output=True, text=True)
    (output / "build.log").write_text(build.stdout + build.stderr)
    if build.returncode:
        print(build.stdout + build.stderr, file=sys.stderr)
        return build.returncode
    image = output / "fixture.tif"
    if args.image:
        source = args.image.resolve(strict=True)
        image = output / ("fixture" + source.suffix)
        shutil.copyfile(source, image)  # Never expose an original or its existing XMP to the plug-in.
    else:
        write_fixture(image)
    revision = "unversioned SDK"
    if (args.sdk.resolve() / ".git").exists():
        revision = subprocess.run(["git", "-C", str(args.sdk.resolve()), "rev-parse", "HEAD"],
                                  capture_output=True, text=True, check=True).stdout.strip()
    modes = MODES if args.mode == "all" else (args.mode,)
    results = [run_probe(binary, args.plugin.resolve(), mode, image, args.timeout,
                         output / f"{mode}.log", args.host_signature, api_version, args.services,
                         args.app_environment, args.resource_map, args.capture_window, args.automation) for mode in modes]
    round_trip_verified = False
    if args.automation == "edit-save":
        metadata_sources = [image]
        sidecar = image.with_suffix(".xmp")
        if sidecar.is_file():
            metadata_sources.append(sidecar)
        metadata = subprocess.run(["exiftool", "-j", "-XMP-crs:HasSettings",
            "-XMP-crs:LuminanceAdjustmentRed", *(str(path) for path in metadata_sources)],
            capture_output=True, text=True, check=True)
        (output / "saved-metadata.json").write_text(metadata.stdout)
        records = json.loads(metadata.stdout)
        round_trip_verified = any(bool(saved.get("HasSettings"))
            and str(saved.get("LuminanceAdjustmentRed")) in ("1", "+1") for saved in records)
        print(f"HSL Reds luminance +1 persisted in XMP: {round_trip_verified}", flush=True)
    summary = {"os": platform.platform(), "architecture": platform.machine(), "sdk_revision": revision,
               "plugin": str(args.plugin.resolve()), "host_signature": args.host_signature,
               "api_version": args.api_version, "services": args.services,
               "app_environment": args.app_environment, "resource_map": args.resource_map, "results": results,
               "editor_window_opened": any(item["window_opened"] for item in results),
               "settings_round_trip_verified": round_trip_verified,
               "working_editor_verified": False}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Results: {output}", flush=True)
    print("Pixel transfer, full RAW compatibility and HDR output are not verified.", flush=True)
    if args.automation == "edit-save" and not round_trip_verified:
        return 1
    return int(any(item["timed_out"] or (item["returncode"] != 0
                   and not (item["window_opened"] and item["dialog_closed"])) for item in results))


if __name__ == "__main__":
    raise SystemExit(main())
