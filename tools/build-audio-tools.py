#!/usr/bin/env python3
"""Build small LGPL audio executables from pinned source; Python 3.11+."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

SOURCES = [
    {"name": "ffmpeg-9.0.2.tar.xz", "url": "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz", "sha256": "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"},
    {"name": "lame-3.100.tar.gz", "url": "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz", "sha256": "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"},
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    sources = workspace / "dependency-sources"
    build = workspace / "audio-build"
    prefix = workspace / "audio-tools"
    sources.mkdir(parents=True, exist_ok=True)
    build.mkdir(parents=True, exist_ok=True)
    for record in SOURCES:
        archive = sources / record["name"]
        if not archive.exists():
            urllib.request.urlretrieve(record["url"], archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError("Source checksum mismatch: " + archive.name)
        with tarfile.open(archive) as stream:
            stream.extractall(build, filter="data")
    environment = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0")
    environment["CFLAGS"] = "-O2 -arch arm64 -mmacosx-version-min=14.0"
    environment["LDFLAGS"] = "-arch arm64 -mmacosx-version-min=14.0"
    def run(command, cwd):
        subprocess.run(command, cwd=cwd, env=environment, check=True)
    jobs = str(min(8, os.cpu_count() or 2))
    lame = build / "lame-3.100"
    run(["./configure", "--prefix=/usr/local", "--disable-shared", "--enable-static", "--disable-frontend", "--disable-decoder", "--disable-dependency-tracking", "--with-pic"], lame)
    run(["make", "-j" + jobs], lame)
    run(["make", "install", "DESTDIR=" + str(build / "lame-stage")], lame)
    ffmpeg = build / "ffmpeg-9.0.2"
    configure = ["./configure", "--prefix=/usr/local", "--arch=arm64", "--target-os=darwin", "--cc=clang", "--disable-autodetect", "--disable-everything", "--disable-shared", "--enable-static", "--disable-doc", "--disable-debug", "--disable-ffplay", "--disable-avdevice", "--disable-swscale", "--disable-network", "--enable-small", "--enable-ffmpeg", "--enable-ffprobe", "--enable-avformat", "--enable-avcodec", "--enable-avfilter", "--enable-swresample", "--enable-libmp3lame", "--extra-cflags=-I../lame-stage/usr/local/include -mmacosx-version-min=14.0", "--extra-ldflags=-L../lame-stage/usr/local/lib -mmacosx-version-min=14.0", "--enable-protocol=file,pipe,fd", "--enable-demuxer=wav,mp3,flac,aiff,mov,matroska,ogg,aac,ape,asf,pcm_f32le,pcm_f64le,pcm_s16le,pcm_s24le,pcm_s32le", "--enable-muxer=wav,flac,mp3,aiff,ipod,mov,adts,null,pcm_f32le,pcm_s16le", "--enable-decoder=aac,aac_fixed,alac,mp3,mp3float,flac,vorbis,opus,ape,wmav1,wmav2,wmapro,wmalossless,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,pcm_u16le,pcm_u16be", "--enable-encoder=pcm_s16le,pcm_s24le,pcm_s24be,pcm_f32le,flac,libmp3lame,aac", "--enable-parser=aac,aac_latm,mpegaudio,flac,opus,vorbis", "--enable-filter=aresample,aformat,anull,amix,volume,astats,atrim,asetpts,asplit,apad,anullsink,anullsrc"]
    run(configure, ffmpeg)
    run(["make", "-j" + jobs], ffmpeg)
    (prefix / "bin").mkdir(parents=True, exist_ok=True)
    for name in ("ffmpeg", "ffprobe"):
        shutil.copy2(ffmpeg / name, prefix / "bin" / name)
        run(["/usr/bin/strip", "-S", "-x", str(prefix / "bin" / name)], ffmpeg)
    # Exercise the actual float pipe used by separation before accepting a build.
    import struct
    import wave
    check_input = build / "pipe-check.wav"
    samples = [0, 4096, -8192, 16384] * 100
    with wave.open(str(check_input), "wb") as stream:
        stream.setparams((1, 2, 44100, 0, "NONE", "not compressed"))
        stream.writeframes(struct.pack("<" + "h" * len(samples), *samples))
    decoded = subprocess.run([str(prefix / "bin/ffmpeg"), "-v", "error", "-i", str(check_input), "-f", "f32le", "-ac", "1", "-ar", "44100", "pipe:1"], capture_output=True, check=True).stdout
    values = struct.unpack("<" + "f" * len(samples), decoded)
    assert all(abs(value - sample / 32768) < 1e-7 for value, sample in zip(values, samples))
    check_output = build / "pipe-check-restored.wav"
    subprocess.run([str(prefix / "bin/ffmpeg"), "-v", "error", "-y", "-f", "f32le", "-ac", "1", "-ar", "44100", "-i", "pipe:0", "-c:a", "pcm_s16le", str(check_output)], input=decoded, capture_output=True, check=True)
    with wave.open(str(check_output), "rb") as stream:
        assert stream.readframes(stream.getnframes()) == struct.pack("<" + "h" * len(samples), *samples)
    (prefix / "float-pipe-check.json").write_text(json.dumps({"samples": len(samples), "decode": "passed", "encode": "passed", "bit_exact_pcm16_roundtrip": True}) + "\n")
    notices = prefix / "licenses"
    notices.mkdir(exist_ok=True)
    shutil.copy2(ffmpeg / "COPYING.LGPLv2.1", notices / "FFmpeg-LGPL-2.1.txt")
    shutil.copy2(lame / "COPYING", notices / "LAME-COPYING.txt")
    (prefix / "build.json").write_text(json.dumps({"sources": SOURCES, "configure": configure, "minimum_macos": "14.0", "network_protocols": False, "external_dylibs": "system only; verify with otool"}, indent=2) + "\n")
    print("AUDIO_TOOLS_READY", prefix, flush=True)


if __name__ == "__main__":
    main()
