#!/usr/bin/env python3
"""Checks that every language has the same keys and the same format placeholders as English."""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent / "Resources"
pattern = re.compile(r'^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)
placeholders = re.compile(r'%(?:\d+\$)?[@dsx0-9]+')


def load(path):
    return {m.group(1): m.group(2) for m in pattern.finditer(path.read_text(encoding="utf-8"))}


base = load(root / "en.lproj" / "Localizable.strings")
ok = True
for lproj in sorted(root.glob("*.lproj")):
    if lproj.name == "en.lproj":
        continue
    other = load(lproj / "Localizable.strings")
    missing = sorted(set(base) - set(other))
    extra = sorted(set(other) - set(base))
    bad = [k for k in base if k in other and sorted(placeholders.findall(base[k])) != sorted(placeholders.findall(other[k]))]
    if missing or extra or bad:
        ok = False
        print(f"{lproj.name}: missing={missing} extra={extra} placeholder-mismatch={bad}")
print(f"strings OK: {len(base)} keys in {len(list(root.glob('*.lproj')))} languages" if ok else "strings check FAILED")
sys.exit(0 if ok else 1)
