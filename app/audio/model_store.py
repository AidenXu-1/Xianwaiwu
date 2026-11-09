"""Fetch pinned public artifacts into a writable cache; never write inside the App."""
import hashlib
import os
from pathlib import Path
import re
import ssl
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def ensure_files(records, directory, notify):
    directory = Path(directory)
    if directory.is_symlink():
        raise ValueError("模型目录不能是替身或链接，请更换资料库位置。")
    directory.mkdir(parents=True, exist_ok=True)
    for item in records:
        name = item["filename"]
        url = urllib.parse.urlsplit(item["url"])
        if (Path(name).name != name or name in ("", ".", "..") or
                not isinstance(item["bytes"], int) or item["bytes"] <= 0 or
                re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) is None or
                url.scheme != "https" or not url.netloc or url.username or url.password):
            raise ValueError("模型来源记录无效，请重新下载完整 App。")
    total = sum(item["bytes"] for item in records)
    completed = 0
    for item in records:
        target = directory / item["filename"]
        if target.is_symlink():
            raise ValueError("模型文件不能是替身或链接，请恢复模型缓存。")
        if target.is_file() and target.stat().st_size == item["bytes"] and digest(target) == item["sha256"]:
            completed += item["bytes"]
            notify(completed, total, item["filename"])
            continue
        notify(completed, total, item["filename"])
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
        temporary = None
        try:
            request = urllib.request.Request(item["url"], headers={"User-Agent": "Xianwaiwu-models/1.3.8"})
            with urllib.request.urlopen(request, context=context, timeout=20) as remote:
                if urllib.parse.urlsplit(remote.geturl()).scheme != "https":
                    raise ValueError("模型来源未使用安全连接，下载已停止。")
                with tempfile.NamedTemporaryFile(dir=directory, prefix=".download-", delete=False) as output:
                    temporary = Path(output.name)
                    downloaded = 0
                    checksum = hashlib.sha256()
                    last_notice = time.monotonic()
                    while True:
                        part = remote.read(min(256 * 1024, item["bytes"] - downloaded + 1))
                        if not part:
                            break
                        downloaded += len(part)
                        if downloaded > item["bytes"]:
                            raise ValueError("模型下载大小不符，已有文件保持保留，请重试。")
                        checksum.update(part)
                        output.write(part)
                        if time.monotonic() - last_notice >= 0.2:
                            notify(completed + downloaded, total, item["filename"])
                            last_notice = time.monotonic()
                    output.flush()
                    if downloaded != item["bytes"] or checksum.hexdigest() != item["sha256"]:
                        raise ValueError("模型下载不完整或校验失败，已有文件保持保留，请重试。")
                    os.fsync(output.fileno())
                temporary.replace(target)
                temporary = None
        except (urllib.error.URLError, TimeoutError) as error:
            raise ValueError("首次使用需要联网准备模型。这次下载未完成，已有内容已保留；联网后重试即可。") from error
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        completed += item["bytes"]
        notify(completed, total, item["filename"])
