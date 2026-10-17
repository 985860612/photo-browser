"""Verify ACR panorama preview and DNG output using generated overlapping TIFFs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--automatic", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True, exist_ok=True)
    assert not list(args.output.glob("*.dng")), "Panorama test requires a fresh output directory"
    subprocess.run(["swift", str(root / "Tests/CameraRawHostChecks/PanoramaFixtures.swift"), str(args.output)], check=True)
    images = sorted(args.output.glob("overlap-*.tif"))
    hashes = [hashlib.sha256(image.read_bytes()).hexdigest() for image in images]
    request, result = args.output / "request.json", args.output / "result.json"
    request.write_text(json.dumps({"version": 1, "images": [str(image) for image in images]}))
    log = args.output / "panorama.log"
    with log.open("wb") as stream:
        process = subprocess.Popen([str(args.binary),
            "/Library/Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin",
            str(request), str(result), "panorama-auto" if args.automatic else "panorama"], stdout=stream, stderr=subprocess.STDOUT)
        (args.output / "pid").write_text(str(process.pid))
        try:
            code = process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
            raise AssertionError(f"Panorama test timed out: {log}")
    print(log.read_text(errors="replace")[-6000:], flush=True)
    status = json.loads(result.read_text())
    assert code == 0 and status["status"] == "closed" and status["inputCount"] == 3, status
    outputs = list(args.output.glob("*.dng"))
    assert len(outputs) == 1, outputs
    metadata = json.loads(subprocess.check_output(["exiftool", "-j", "-ImageWidth", "-ImageHeight", "-DNGVersion", str(outputs[0])]))[0]
    assert metadata.get("DNGVersion") and metadata["ImageWidth"] > 768 and metadata["ImageHeight"] > 0, metadata
    assert hashes == [hashlib.sha256(image.read_bytes()).hexdigest() for image in images], "Panorama merge changed the source TIFFs"
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2))
    print(f"PASS three-image panorama saved and independently decoded: {metadata}", flush=True)


if __name__ == "__main__":
    main()
