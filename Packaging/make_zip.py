#!/usr/bin/env python3
"""Create a UTF-8 named macOS app archive without carrying Finder metadata."""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


def add_path(archive: ZipFile, path: Path, archive_name: str) -> None:
    info = ZipInfo(archive_name)
    info.create_system = 3  # Unix; keeps executable bits in the archive.
    info.flag_bits |= 0x800  # UTF-8 filename flag for Chinese app names.
    mode = stat.S_IMODE(path.lstat().st_mode)

    if path.is_dir():
        info.external_attr = ((stat.S_IFDIR | mode) & 0xFFFF) << 16
        archive.writestr(info, b"")
        for child in sorted(path.iterdir(), key=lambda item: item.name):
            child_name = f"{archive_name}{child.name}"
            if child.is_dir():
                child_name += "/"
            add_path(archive, child, child_name)
        return

    if path.is_symlink():
        info.external_attr = ((stat.S_IFLNK | mode) & 0xFFFF) << 16
        archive.writestr(info, os.readlink(path).encode("utf-8"))
        return

    info.external_attr = ((stat.S_IFREG | mode) & 0xFFFF) << 16
    archive.writestr(info, path.read_bytes())


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: make_zip.py APP_PATH OUTPUT_ZIP")
    app_path = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=6) as archive:
        add_path(archive, app_path, app_path.name + "/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
