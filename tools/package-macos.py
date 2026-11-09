#!/usr/bin/env python3
"""Assemble a relocatable Apple-silicon App and drag-install DMG from local pinned dependencies."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

MAGIC = {bytes.fromhex(x) for x in ("cffaedfe", "feedfacf", "cafebabe", "bebafeca", "cefaedfe")}

def run(command, **kwargs):
    return subprocess.run([str(x) for x in command], check=True, text=True, capture_output=True, **kwargs).stdout


def copy_tree(source, target):
    shutil.copytree(source, target, dirs_exist_ok=True, symlinks=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".DS_Store", "weights", ".venv", ".下载缓存"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--python-base", type=Path, help="Optional extracted CPython 3.11.15 / 20260414 distribution")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    workspace = args.workspace.resolve()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    stage = workspace / "package"
    if stage.exists():
        raise SystemExit("Package staging directory already exists; move it aside before rebuilding.")
    stage.mkdir(parents=True)
    app = stage / "弦外屋.app"
    run(["/usr/bin/ditto", args.app.resolve(), app])
    runtime = app / "Contents/Resources/Runtime"
    runtime.mkdir()
    python_source = args.python_base.resolve() if args.python_base else (root / "app/audio/引擎/.venv/bin/python").resolve().parents[1]
    source_env = dict(os.environ)
    source_env.pop("PYTHONHOME", None); source_env.pop("PYTHONPATH", None)
    actual_python = run([python_source / "bin/python3.11", "-c", "import platform;print(platform.python_version())"], env=source_env).strip()
    actual_build = (python_source / "BUILD").read_text().strip()
    if (actual_python, actual_build) != ("3.11.15", "20260414"):
        raise ValueError("This release requires CPython 3.11.15 / build 20260414; supply the pinned distribution with --python-base or update the runtime sources and version together.")
    python = runtime / "Python"
    copy_tree(python_source / "lib", python / "lib")
    (python / "bin").mkdir()
    shutil.copy2(python_source / "bin/python3.11", python / "bin/python3.11")
    (python / "bin/python3").symlink_to("python3.11")
    packages = root / "app/audio/引擎/.venv/lib/python3.11/site-packages"
    copy_tree(packages, python / "lib/python3.11/site-packages")
    for config in python.glob("lib/python3.11/_sysconfigdata*.py"):
        text = config.read_text().replace(str(python_source), "@XIANWAIWU_PYTHON@")
        text += '\nimport sys as _sys\nbuild_time_vars = {k: v.replace("@XIANWAIWU_PYTHON@", _sys.base_prefix) if isinstance(v, str) else v for k, v in build_time_vars.items()}\n'
        config.write_text(text)
    for f in python.rglob("direct_url.json"):
        if "file:" in f.read_text(): f.unlink()
    for f in python.rglob("*.pth"):
        if "/Users/" in f.read_text():
            raise ValueError("Nonportable package path: " + str(f.relative_to(runtime)))
    for folder in ("app/audio/引擎", "app/macos/源码", "bin"):
        (runtime / folder).mkdir(parents=True, exist_ok=True)
    for name in ("run-engine.command", "run_engine.py", "uvr_mdx.py", "模型清单.json", "已验证模式.json"):
        shutil.copy2(root / "app/audio/引擎" / name, runtime / "app/audio/引擎" / name)
    shutil.copy2(root / "app/audio/model_store.py", runtime / "app/audio/model_store.py")
    shutil.copy2(root / "app/macos/源码/audio_job.py", runtime / "app/macos/源码/audio_job.py")
    copy_tree(root / "app/audio/乐谱", runtime / "app/audio/乐谱")
    sample = runtime / "app/audio/样本"; sample.mkdir()
    shutil.copy2(root / "app/audio/样本/create_demo.py", sample / "create_demo.py")
    environment = dict(os.environ, PYTHONHOME=str(python), PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1")
    environment.pop("PYTHONPATH", None); environment.pop("VIRTUAL_ENV", None)
    run([python / "bin/python3.11", "-B", sample / "create_demo.py"], env=environment)
    for name in ("ffmpeg", "ffprobe"):
        shutil.copy2(workspace / "audio-tools/bin" / name, runtime / "bin" / name)
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(root / name, runtime / name)
    notices = runtime / "ThirdPartyLicenses"
    copy_tree(workspace / "audio-tools/licenses", notices / "audio-tools")
    if not any((workspace / "python-licenses").glob("LICENSE*")):
        raise ValueError("Python distribution license texts were not collected")
    copy_tree(workspace / "python-licenses", notices / "python-standalone")
    distributions = []
    for distribution in sorted(importlib.metadata.distributions(path=[str(packages)]), key=lambda d:d.metadata["Name"].lower()):
        distributions.append({"name":distribution.metadata["Name"], "version":distribution.version,
                              "license":distribution.metadata.get("License-Expression") or distribution.metadata.get("License") or "See bundled dist-info"})
    (notices / "python-packages.json").write_text(json.dumps(distributions, ensure_ascii=False, indent=2) + "\n")
    shutil.copy2(workspace / "audio-tools/build.json", notices / "audio-build.json")
    shutil.copy2(workspace / "audio-tools/float-pipe-check.json", notices / "audio-float-pipe-check.json")
    for f in app.rglob("*"):
        if f.is_symlink() and not f.resolve().is_relative_to(app):
            raise ValueError("External symlink: " + str(f.relative_to(app)))
    machos = []
    minimum = (14, 0)
    for f in app.rglob("*"):
        if not f.is_file() or f.is_symlink(): continue
        with f.open("rb") as stream: magic = stream.read(4)
        if magic not in MAGIC: continue
        # Normalize the library identity, without rewriting genuine dependencies.
        identities = run(["/usr/bin/otool", "-D", f]).splitlines()
        if any(line.startswith("/") and not line.endswith(":") for line in identities):
            run(["/usr/bin/install_name_tool", "-id", "@rpath/" + f.name, f])
        libraries = run(["/usr/bin/otool", "-L", f])
        for dependency in re.findall(r"^\t(.+?) \(", libraries, re.M):
            if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise ValueError("External native dependency: " + str(f.relative_to(app)) + " -> " + dependency)
        headers = run(["/usr/bin/otool", "-l", f])
        versions = re.findall(r"\bminos ([0-9.]+)", headers)
        versions += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)", headers)
        for version in versions: minimum = max(minimum, tuple(int(x) for x in version.split(".")))
        machos.append(f)
    minimum_text = ".".join(str(x) for x in minimum)
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as stream: info = plistlib.load(stream)
    info["LSMinimumSystemVersion"] = minimum_text
    with info_path.open("wb") as stream: plistlib.dump(info, stream)
    runtime_metadata = {"version":info["CFBundleShortVersionString"], "python":"3.11.15", "architecture":"arm64",
                        "minimum_macos":minimum_text, "model_delivery":"on demand, pinned SHA-256, writable user cache",
                        "bundled_model_weights":False, "native_files_checked":len(machos), "external_non_system_dylibs":0,
                        "signature":"ad hoc; not Apple-notarized"}
    (runtime / "runtime.json").write_text(json.dumps(runtime_metadata,ensure_ascii=False,indent=2) + "\n")
    run(["/usr/bin/xattr", "-cr", app])
    run(["/usr/bin/strip", "-S", "-x", app / "Contents/MacOS/Xianwaiwu"])
    for f in machos: run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", f])
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", app])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    image_root = stage
    (image_root / "Applications").symlink_to("/Applications")
    (image_root / "安装说明.txt").write_text("将弦外屋拖到 Applications 后打开。\n这是商店外自用版本，未作 Apple 公证。若首次打开受阻，在系统设置的隐私与安全性中选择仍要打开。\n首次使用分离或乐谱时自动下载所需模型，后续可离线使用；无需安装 Python、Homebrew 或配置 API。\n兼容 Apple 芯片，macOS " + minimum_text + " 或更新版本。\n模型和项目保存在用户资料目录，更新 App 保留既有数据。\n")
    version = info["CFBundleShortVersionString"]
    dmg = output / ("Xianwaiwu-" + version + "-arm64.dmg")
    if dmg.exists(): raise ValueError("Release image already exists; preserve it before rebuilding")
    run(["/usr/bin/hdiutil", "create", "-volname", "弦外屋 " + version, "-srcfolder", image_root, "-format", "UDZO", "-ov", dmg])
    record = {**runtime_metadata, "dmg":dmg.name, "bytes":dmg.stat().st_size,
              "sha256":hashlib.sha256(dmg.read_bytes()).hexdigest()}
    (output / "package.json").write_text(json.dumps(record,ensure_ascii=False,indent=2) + "\n")
    print(json.dumps(record, ensure_ascii=False), flush=True)

if __name__ == "__main__": main()
