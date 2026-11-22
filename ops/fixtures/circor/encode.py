"""Prepare the verified CirCor audio input and its 20-ms Opus preview."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

import imageio_ffmpeg


def main(target: Path):
    manifest = Path(__file__).with_name("MANIFEST.json")
    fixture = json.loads(manifest.read_text(encoding="utf-8"))["fixtures"][0]

    wav = target / fixture["file"]
    with TemporaryDirectory(dir=target) as work:
        work = Path(work)
        if not wav.is_file():
            candidate = work / wav.name
            subprocess.run(
                [
                    "curl", "--fail", "--silent", "--show-error", "--location",
                    "--connect-timeout", "8", "--max-time", "25",
                    "--retry", "3", "--retry-all-errors",
                    "--output", str(candidate), fixture["source_url"],
                ],
                check=True,
            )
            verify(candidate, fixture["file_sha256"])
            candidate.replace(wav)
        verify(wav, fixture["file_sha256"])

        preview = work / wav.with_suffix(".opus").name
        subprocess.run(
            [
                imageio_ffmpeg.get_ffmpeg_exe(),
                "-nostdin", "-loglevel", "error",
                "-i", str(wav), "-map_metadata", "-1", "-ac", "1", "-ar", "48000",
                "-c:a", "libopus", "-frame_duration", "20",
                "-f", "ogg", str(preview),
            ],
            check=True,
        )
        preview.replace(target / preview.name)

    print(wav)
    print(target / wav.with_suffix(".opus").name)


def verify(path: Path, expected: str):
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Checksum mismatch for {path}. Remove it and run preparation again.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
