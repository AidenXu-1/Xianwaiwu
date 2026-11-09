#!/usr/bin/env python3
"""Collect pinned runtime source archives and Python distribution license texts."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

SOURCES = [{'name': 'ffmpeg-9.0.2.tar.xz', 'url': 'https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz', 'sha256': '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e', 'bytes': 12040788}, {'name': 'lame-3.100.tar.gz', 'url': 'https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz', 'sha256': 'ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e', 'bytes': 1524133}, {'name': 'python-build-standalone-20260414.tar.gz', 'url': 'https://codeload.github.com/astral-sh/python-build-standalone/tar.gz/refs/tags/20260414', 'sha256': 'a9e21da5b91bfac1f70888f37ba751dba7cb6bb7cd50e42b2b14409d55b7cf2e'}, {'name': 'soxr-1.1.0.tar.gz', 'url': 'https://files.pythonhosted.org/packages/ed/11/27cebce4a108f77afea7c80545115536b45e3f11ebfb914f638fdd9ba847/soxr-1.1.0.tar.gz', 'sha256': '9f228ae21c78fa9359ca98d8a5e8e91f30639e438e574133dace62c5b5309e44'}, {'name': 'soundfile-0.14.0.tar.gz', 'url': 'https://files.pythonhosted.org/packages/d2/db/949331952a6fb1c5b12e9de80fd08747966c2039d1a61db4764fbd3981c2/soundfile-0.14.0.tar.gz', 'sha256': 'ba1c1a2d618bca5c406647c83b89f07cc8810fa506a50622a6993ba130c1de11'}, {'name': 'lameenc-1.9.0.tar.gz', 'url': 'https://codeload.github.com/chrisstaite/lameenc/tar.gz/refs/tags/v1.9.0', 'sha256': '1d96b6d818d00d5d479ecfc01c8939f3fde1ee002a133577d6f42354181044f7'}, {'name': 'libsndfile-1.2.2.tar.gz', 'url': 'https://codeload.github.com/libsndfile/libsndfile/tar.gz/refs/tags/1.2.2', 'sha256': 'ffe12ef8add3eaca876f04087734e6e8e029350082f3251f565fa9da55b52121'}, {'name': 'mlx_audio_io-1.3.24.tar.gz', 'url': 'https://files.pythonhosted.org/packages/36/12/c338f0e83d3827650a746a211d2e7e0012789164419e0010affcf02cc128/mlx_audio_io-1.3.24.tar.gz', 'sha256': 'e7404707d090be8ea218b0b7de6ec90ea382e05be86f56e742c3cfd005a38ee1'}, {'name': 'soxr-0.1.3-Source.tar.xz', 'url': 'https://downloads.sourceforge.net/project/soxr/soxr-0.1.3-Source.tar.xz', 'sha256': 'b111c15fdc8c029989330ff559184198c161100a59312f5dc19ddeb9b5a15889'}]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    sources = args.workspace.resolve() / "dependency-sources"
    sources.mkdir(parents=True, exist_ok=True)
    for item in SOURCES:
        target = sources / item["name"]
        def valid():
            return target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == item["sha256"]
        if not valid():
            with tempfile.NamedTemporaryFile(dir=sources, prefix=".source-", delete=False) as stream:
                temporary = Path(stream.name)
                try:
                    with urllib.request.urlopen(item["url"], timeout=90) as response:
                        shutil.copyfileobj(response, stream)
                    stream.flush()
                    if hashlib.sha256(temporary.read_bytes()).hexdigest() != item["sha256"]:
                        raise ValueError("Source checksum mismatch: " + item["name"])
                    temporary.replace(target)
                finally:
                    temporary.unlink(missing_ok=True)
        print("Verified source", target.name, flush=True)
    licenses = args.workspace.resolve() / "python-licenses"
    licenses.mkdir(exist_ok=True)
    with tarfile.open(sources / "python-build-standalone-20260414.tar.gz") as archive:
        for item in archive.getmembers():
            name = Path(item.name)
            if item.isfile() and len(name.parts) == 2 and name.name.startswith("LICENSE"):
                with archive.extractfile(item) as stream, (licenses / name.name).open("wb") as target:
                    shutil.copyfileobj(stream, target)
    (sources / "source-manifest.json").write_text(json.dumps(SOURCES, indent=2) + "\n")
    print("Python license files", len(list(licenses.glob("LICENSE*"))), flush=True)

if __name__ == "__main__": main()
