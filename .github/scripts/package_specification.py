#!/usr/bin/env python3
"""Package the Silica specification and the markdown files it links to.

The specification is copied byte for byte. Nothing in the repository is
rewritten. Supporting files are the markdown files named by relative links in
compiler/design_documents/silica-specification.md. The tree keeps repository
paths, so those links still resolve after the zip is unpacked.

Links inside the supporting files are not followed. A link that does not name
a markdown file, or that points outside the repository, is reported and left
out. A markdown link in the specification that does not resolve is an error.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import zipfile

SPEC = "compiler/design_documents/silica-specification.md"
ZIP_NAME = "silica-specification.zip"
TREE_NAME = "silica-specification"

INLINE_LINK = re.compile(
    r"(?<!!)\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^)\s]+)"
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\s*\)"
)
REF_LINK = re.compile(r"^\s*\[[^\]]+\]:[ \t]*<?([^>\s]+)>?", re.MULTILINE)
AUTO_LINK = re.compile(r"<([^>\s:]+\.md)>")
INLINE_CODE = re.compile(r"``.*?``|`[^`\n]*`")


def visible_text(text: str) -> str:
    """Drop fenced and inline code so examples are not packaged as links."""
    lines = text.splitlines(keepends=True)
    kept = []
    fence_char = ""
    fence_len = 0
    for line in lines:
        stripped = line.lstrip()
        if not fence_char:
            match = re.match(r"(```+|~~~+)", stripped)
            if match:
                fence_char = match.group(1)[0]
                fence_len = len(match.group(1))
                continue
            kept.append(INLINE_CODE.sub("", line))
            continue
        if re.match(rf"{re.escape(fence_char)}{{{fence_len},}}\s*$", stripped):
            fence_char = ""
            fence_len = 0
        continue
    return "".join(kept)


def link_targets(text: str) -> list[str]:
    visible = visible_text(text)
    raw = [match.group(1) for match in INLINE_LINK.finditer(visible)]
    raw.extend(match.group(1) for match in REF_LINK.finditer(visible))
    raw.extend(match.group(1) for match in AUTO_LINK.finditer(visible))
    targets = []
    for url in raw:
        if url.startswith("<") and url.endswith(">"):
            url = url[1:-1]
        url = url.strip()
        if not url or url.startswith("#") or "://" in url or url.startswith("mailto:"):
            continue
        path = url.split("#", 1)[0].split("?", 1)[0]
        path = path.replace("%20", " ")
        if path:
            targets.append(path)
    return targets


def resolve(src_rel: str, url_path: str) -> str | None:
    """Return a repo-relative path, or None when the link leaves the repo."""
    if os.path.isabs(url_path):
        return None
    joined = os.path.normpath(os.path.join(os.path.dirname(src_rel), url_path))
    joined = joined.replace(os.sep, "/")
    if joined == "." or joined.startswith("../") or "/../" in f"/{joined}":
        return None
    return joined


def is_file(root: str, rel: str) -> bool:
    """Case-sensitive file check. macOS would otherwise accept the wrong case."""
    current = root
    for part in rel.split("/"):
        if part in ("", "."):
            continue
        try:
            names = os.listdir(current)
        except FileNotFoundError:
            return False
        if part not in names:
            return False
        current = os.path.join(current, part)
    return os.path.isfile(current)


def markdown_links(root: str, rel: str) -> tuple[list[str], list[str]]:
    """Return (resolved markdown paths, notes about links that are not packaged)."""
    full = os.path.join(root, *rel.split("/"))
    text = open(full, encoding="utf-8", errors="replace").read()
    markdown = []
    notes = []
    for url_path in link_targets(text):
        resolved = resolve(rel, url_path)
        if resolved is None:
            notes.append(f"left out (outside the repository): {url_path}")
            continue
        if not resolved.endswith(".md"):
            notes.append(f"left out (not markdown): {url_path}")
            continue
        if not is_file(root, resolved):
            raise SystemExit(
                f"specification link does not resolve: {url_path} -> {resolved}"
            )
        markdown.append(resolved)
    return markdown, notes


def copy_tree(root: str, files: list[str], dest_tree: str) -> None:
    for rel in files:
        src = os.path.join(root, *rel.split("/"))
        dst = os.path.join(dest_tree, *rel.split("/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(src, "rb") as infile, open(dst, "wb") as outfile:
            outfile.write(infile.read())
        with open(src, "rb") as infile, open(dst, "rb") as outfile:
            if infile.read() != outfile.read():
                raise SystemExit(f"copy changed file bytes: {rel}")


def write_zip(tree: str, zip_path: str, files: list[str]) -> None:
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for rel in files:
            info = zipfile.ZipInfo(f"{TREE_NAME}/{rel}")
            info.date_time = (1980, 1, 1, 0, 0, 0)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            source = os.path.join(tree, *rel.split("/"))
            with open(source, "rb") as infile:
                archive.writestr(info, infile.read())


def check_zip(root: str, zip_path: str, files: list[str]) -> None:
    with zipfile.ZipFile(zip_path) as archive:
        names = set(archive.namelist())
        for rel in files:
            member = f"{TREE_NAME}/{rel}"
            if member not in names:
                raise SystemExit(f"zip is missing {member}")
            source = os.path.join(root, *rel.split("/"))
            with open(source, "rb") as infile:
                if archive.read(member) != infile.read():
                    raise SystemExit(f"zip bytes differ from the repository: {rel}")
        extra = sorted(names - {f"{TREE_NAME}/{rel}" for rel in files})
        if extra:
            raise SystemExit(f"zip has unexpected members: {extra}")


def package(root: str, dest: str) -> None:
    root = os.path.abspath(root)
    dest = os.path.abspath(dest)
    if not is_file(root, SPEC):
        raise SystemExit(f"specification is missing: {SPEC}")

    linked, notes = markdown_links(root, SPEC)
    files = sorted(set([SPEC, *linked]))
    basenames: dict[str, str] = {}
    for rel in files:
        name = os.path.basename(rel)
        previous = basenames.get(name)
        if previous is not None:
            raise SystemExit(
                f"unzipped release names would collide: {previous} and {rel}"
            )
        basenames[name] = rel

    tree = os.path.join(dest, TREE_NAME)
    os.makedirs(dest, exist_ok=True)
    if os.path.isdir(tree):
        raise SystemExit(f"refusing to replace an existing tree: {tree}")
    zip_path = os.path.join(dest, ZIP_NAME)
    if os.path.exists(zip_path):
        raise SystemExit(f"refusing to replace an existing zip: {zip_path}")

    copy_tree(root, files, tree)
    write_zip(tree, zip_path, files)
    check_zip(root, zip_path, files)

    # The specification's own links must land on a file in the tree.
    for rel in linked:
        packed = os.path.join(tree, *rel.split("/"))
        if not os.path.isfile(packed):
            raise SystemExit(f"packaged tree is missing a linked file: {rel}")

    print(f"packaged {len(files)} markdown files")
    for rel in files:
        print(rel)
    if notes:
        print("links not packaged:", file=sys.stderr)
        for note in notes:
            print(note, file=sys.stderr)
    print(f"tree: {tree}")
    print(f"zip: {zip_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.getcwd(), help="repository root")
    parser.add_argument("--dest", required=True, help="directory to write into")
    args = parser.parse_args()
    package(args.root, args.dest)


if __name__ == "__main__":
    main()
