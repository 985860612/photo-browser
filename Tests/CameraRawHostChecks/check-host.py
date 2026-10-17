"""Exercise the built host on disposable images; --ui requires installed ACR and ExifTool."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("probe", ROOT / "scripts/probe-camera-raw-host.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--test-binary", type=Path)
    parser.add_argument("--launcher", type=Path)
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--panorama", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    image = args.output / '测试 $照片 `quote` "🌅.tif'
    probe.write_fixture(image)
    plugin = Path("/Library/Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin")

    def run(label, image, *, action=None, installed=True, valid=True):
        result = args.output / (label + ".json")
        images = image if isinstance(image, list) else [image]
        request = args.output / (label + "-request.json")
        request.write_text(json.dumps({"version": 1, "images": [str(p) for p in images]}))
        command = [str(args.test_binary if action else args.binary), str(plugin if installed else args.output),
                   str(request), str(result)]
        if action:
            command.append(action)
        with (args.output / (label + ".log")).open("wb") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=40)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise AssertionError(f"{label}: host timed out; see {log.name}")
        status = json.loads(result.read_text())
        if valid:
            assert code == 0 and status["status"] == "closed" and status["editorOpened"], status
            assert status["inputCount"] == len(images), status
        else:
            assert code != 0 and status["status"] == "failed" and not status["editorOpened"], status
        print(f"PASS {label}: {status}", flush=True)
        return status

    run("missing-image", image.with_suffix(".missing"), valid=False)
    assert run("missing-plugin", image, installed=False, valid=False)["stage"] == "plugin"
    # Test hooks must not be present in the production binary.
    assert b"Automation clicking" not in args.binary.read_bytes()
    print("PASS production host excludes UI test automation", flush=True)
    if not args.test_binary:
        return
    assert plugin.is_dir() and shutil.which("exiftool"), "UI checks require Camera Raw and ExifTool"
    original = digest(image)
    run("tiff-cancel", image, action="cancel")
    assert digest(image) == original, "Cancel changed the TIFF"
    run("tiff-save", image, action="edit-save")
    verify_settings(image)
    saved_tiff = digest(image)
    run("tiff-reopen", image, action="edit-cancel")
    verify_settings(image)
    assert digest(image) == saved_tiff, "Cancelling an actual mixer edit changed the TIFF"
    assert any(value in (args.output / "tiff-reopen.log").read_bytes() for value in (b"value=1 ", b"value=+1 ")), "Saved mixer value was not reloaded"
    if args.raw:
        raw = args.output / ("真实 RAW 测试" + args.raw.suffix)
        shutil.copyfile(args.raw, raw)
        original = digest(raw)
        run("raw-save", raw, action="edit-save")
        verify_settings(raw.with_suffix(".xmp"))
        assert digest(raw) == original, "Saving settings changed the original RAW"
        sidecar = digest(raw.with_suffix(".xmp"))
        run("raw-reopen-cancel", raw, action="edit-cancel")
        assert any(value in (args.output / "raw-reopen-cancel.log").read_bytes() for value in (b"value=1 ", b"value=+1 ")), "RAW XMP was not reloaded"
        assert digest(raw) == original and digest(raw.with_suffix(".xmp")) == sidecar, "Cancel changed RAW/XMP"
    if args.launcher:
        other = args.output / "另一个 照片.tif"
        probe.write_fixture(other)
        before = digest(other)
        run("multiple-cancel", [image, other], action="cancel")
        assert digest(other) == before and digest(image) == saved_tiff, "Multi-file Cancel changed photos"
        subprocess.run([str(args.launcher), "--launch", str(image), str(other)], check=True, timeout=45)
    if args.panorama:
        subprocess.run([sys.executable, str(ROOT / "Tests/CameraRawHostChecks/check-panorama.py"),
            "--binary", str(args.test_binary), "--output", str(args.output / "panorama"), "--automatic"], check=True)


def verify_settings(path):
    records = json.loads(subprocess.check_output(["exiftool", "-j", "-XMP-crs:HasSettings",
                         "-XMP-crs:LuminanceAdjustmentRed", str(path)]))
    assert any(record.get("HasSettings") and str(record.get("LuminanceAdjustmentRed")) in ("1", "+1")
               for record in records), records
    print(f"PASS independent XMP readback: {path.name}", flush=True)


if __name__ == "__main__":
    main()
