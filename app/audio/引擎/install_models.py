"""Install published model files pinned by the desktop engine."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--with-karaoke", action="store_true")
    options = parser.parse_args()
    verified_modes_path = ROOT / '已验证模式.json'
    verified_modes = json.loads(verified_modes_path.read_text(encoding='utf-8')) if verified_modes_path.is_file() else []
    model_dir = ROOT / '模型'
    model_dir.mkdir(exist_ok=True)
    models = json.loads((ROOT / '模型清单.json').read_text(encoding='utf-8'))
    for name, model in models.items():
        if model.get('optional') and not (options.with_karaoke or 'lead' in verified_modes or 'backing' in verified_modes):
            continue
        destination = model_dir / model['filename']
        if destination.is_file() and digest(destination) == model['sha256']:
            print(f'{name} 已校验', flush=True)
            continue
        print(f'下载 {name}，{model["bytes"] / 1e6:.0f} MB…', flush=True)
        with tempfile.TemporaryDirectory(prefix='.模型下载-', dir=model_dir) as tmp:
            draft = Path(tmp) / destination.name
            with urlopen(model['url'], timeout=90) as remote, draft.open('wb') as output:
                shutil.copyfileobj(remote, output)
            if draft.stat().st_size != model['bytes'] or digest(draft) != model['sha256']:
                raise ValueError(f'{name} 的文件校验失败，请重新运行安装脚本。')
            draft.replace(destination)


if __name__ == '__main__':
    main()
