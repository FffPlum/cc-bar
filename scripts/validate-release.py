#!/usr/bin/env python3
"""Validate committed release inputs before compiling or accessing signing tools."""

import argparse
import base64
import binascii
import os
from pathlib import Path
import re
import sys


VERSION = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"


def validate(root: Path, tag: str | None = None) -> str:
    project = (root / "ccbar.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    blocks = re.findall(r"\bbuildSettings\s*=\s*\{(.*?)^\s*\};", project, flags=re.DOTALL | re.MULTILINE)
    app_blocks = [block for block in blocks if re.search(
        r'\bPRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?com\.fffplum\.ccbar"?\s*;', block
    )]
    versions = [version.strip().strip('"') for block in app_blocks
                for version in re.findall(r"\bMARKETING_VERSION\s*=\s*([^;]+);", block)]
    if len(versions) != 2 or len(set(versions)) != 1 or not re.fullmatch(VERSION, versions[0]):
        raise ValueError("Debug / Release 必须恰有两处相同的 X.Y.Z MARKETING_VERSION")
    version = versions[0]
    if tag is not None:
        if not re.fullmatch("v" + VERSION, tag):
            raise ValueError("发布 tag 必须为 vX.Y.Z（不接受预发布后缀或前导零）")
        if tag != "v" + version:
            raise ValueError("tag 与 Debug / Release 的 MARKETING_VERSION 不一致")
        notes = root / "release-notes" / f"{tag}.md"
        if not notes.is_file():
            raise ValueError(f"缺少 release-notes/{tag}.md")
        visible = re.sub(r"<!--.*?-->", "", notes.read_text(encoding="utf-8"), flags=re.DOTALL)
        if not visible.strip():
            raise ValueError("发布说明为空或只有 HTML 注释")
    return version


def validate_signing(environ: dict[str, str]) -> None:
    for name, lengths in (
        ("SPARKLE_PUBLIC_ED_KEY", (32,)),
        ("SPARKLE_PRIVATE_ED_KEY", (32, 96)),
    ):
        try:
            value = base64.b64decode(environ.get(name, "").strip(), validate=True)
        except (ValueError, binascii.Error):
            raise ValueError(f"{name} 必须是 Sparkle generate_keys 导出的有效 base64") from None
        if len(value) not in lengths:
            raise ValueError(f"{name} 缺失或长度无效；见 docs/打包发布.md")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag")
    parser.add_argument("--signing", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version = validate(root, args.tag)
    if args.signing:
        validate_signing(dict(os.environ))
    print(f"发布输入校验通过：{args.tag or version}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"发布输入校验失败：{error}", file=sys.stderr)
        sys.exit(1)
