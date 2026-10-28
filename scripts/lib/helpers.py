#!/usr/bin/env python3
"""Small file/setting editors used by the Mint setup scripts.

Kept in Python because these edits (JSONC merging, GVariant lists, XML items)
are fragile to do with sed. Each subcommand is safe to re-run.
"""

import argparse
import ast
import json
import re
import shutil
import sys
import time
from pathlib import Path


# ----- shared ----------------------------------------------------------------
TRAILING_CLOSE = re.compile(r"\s*[}\]]")


def _scan_jsonc(text, on_char):
    """Walk text, calling on_char(i, c) for every character outside strings and comments."""
    out = []
    i, n, in_str = 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        if on_char(i, c):
            out.append(c)
        i += 1
    return "".join(out)


def load_jsonc(path):
    """Parse JSON that may contain comments and trailing commas (VS Code style)."""
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    text = _scan_jsonc(text, lambda i, c: True)
    # Second pass: drop commas that are directly followed by } or ].
    text = _scan_jsonc(text, lambda i, c: not (c == "," and TRAILING_CLOSE.match(text, i + 1)))
    return json.loads(text) if text.strip() else None


def write_if_changed(path, new_obj, old_obj):
    """Write JSON only when the content changes, keeping a timestamped backup."""
    if new_obj == old_obj and path.exists():
        print(f"{path}: already up to date")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name(f"{path.name}.bak.{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(path, backup)
        print(f"{path}: backed up to {backup.name}")
    path.write_text(json.dumps(new_obj, indent=2) + "\n", encoding="utf-8")
    print(f"{path}: updated")


def deep_merge(base, extra):
    """Merge extra into base: objects recurse, lists gain missing items, scalars are replaced."""
    if isinstance(base, dict) and isinstance(extra, dict):
        merged = dict(base)
        for key, value in extra.items():
            merged[key] = deep_merge(base[key], value) if key in base else value
        return merged
    if isinstance(base, list) and isinstance(extra, list):
        return base + [item for item in extra if item not in base]
    return extra


def parse_gvariant_list(text):
    text = text.strip()
    if text.startswith("@as"):
        text = text[3:].strip()
    try:
        value = ast.literal_eval(text)
    except (ValueError, SyntaxError):
        return []
    return list(value) if isinstance(value, (list, tuple)) else []


def format_gvariant_list(items):
    return "[" + ", ".join(repr(str(item)) for item in items) + "]"


# ----- subcommands -----------------------------------------------------------
def cmd_merge_json(args):
    target = Path(args.target)
    current = load_jsonc(target) or {}
    if not isinstance(current, dict):
        sys.exit(f"{target} is not a JSON object; leaving it alone")
    updated = {k: v for k, v in current.items() if k not in args.remove}
    updated = deep_merge(updated, load_jsonc(Path(args.source)) or {})
    write_if_changed(target, updated, current)


def cmd_merge_keybindings(args):
    target = Path(args.target)
    current = load_jsonc(target) or []
    if not isinstance(current, list):
        sys.exit(f"{target} is not a JSON array; leaving it alone")
    updated = [kb for kb in current if kb.get("command") not in args.remove_command]
    seen = {(kb.get("key"), kb.get("command")) for kb in updated}
    for kb in load_jsonc(Path(args.source)) or []:
        if (kb.get("key"), kb.get("command")) not in seen:
            updated.append(kb)
    write_if_changed(target, updated, current)


def cmd_list_edit(args):
    """Edit a GVariant string list such as org.cinnamon favorite-apps."""
    items = parse_gvariant_list(args.current)
    items = [i for i in items if not any(s.lower() in i.lower() for s in args.remove_contains)]
    for item in args.append:
        if item not in items:
            items.append(item)
    print(format_gvariant_list(items))


def cmd_list_set(args):
    """Set one index of a fixed-length GVariant string list (e.g. hotcorner-layout)."""
    items = parse_gvariant_list(args.current)
    items = (items + [args.fill] * args.length)[: args.length]
    items[args.index] = args.value
    print(format_gvariant_list(items))


def cmd_pin_apps(args):
    """Swap pinned launchers in a grouped-window-list applet config (e.g. Firefox -> Brave)."""
    path = Path(args.file)
    data = json.loads(path.read_text(encoding="utf-8"))
    pinned = data.get("pinned-apps")
    if not isinstance(pinned, dict) or not isinstance(pinned.get("value"), list):
        print(f"{path}: no pinned-apps list; skipping")
        return
    current = pinned["value"]
    updated = []
    for app in current:
        # The replacement takes the slot of the first replaced (or already present) launcher.
        if app.startswith(args.replace_prefix) or app == args.with_app:
            if args.with_app not in updated:
                updated.append(args.with_app)
        else:
            updated.append(app)
    if args.with_app not in updated:
        updated.append(args.with_app)
    if updated == current:
        print(f"{path}: already up to date")
        return
    pinned["value"] = updated
    path.write_text(json.dumps(data, indent=4, sort_keys=True), encoding="utf-8")
    print(f"{path}: pinned apps -> {updated}")


XCU_HEADER = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<oor:items xmlns:oor="http://openoffice.org/2001/registry" '
    'xmlns:xs="http://www.w3.org/2001/XMLSchema" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
    "</oor:items>\n"
)


def _xcu_key(line):
    path = re.search(r'oor:path="([^"]*)"', line)
    prop = re.search(r'<prop oor:name="([^"]*)"', line)
    return (path.group(1) if path else None, prop.group(1) if prop else None)


def cmd_xcu_merge(args):
    """Upsert single-line <item> entries into a LibreOffice registrymodifications.xcu."""
    target = Path(args.target)
    items = [l.strip() for l in Path(args.items).read_text(encoding="utf-8").splitlines()
             if l.strip().startswith("<item")]
    keys = {_xcu_key(i) for i in items}
    text = target.read_text(encoding="utf-8") if target.exists() else XCU_HEADER
    lines = [l for l in text.splitlines() if not (l.strip().startswith("<item") and _xcu_key(l) in keys)]
    try:
        end = next(i for i, l in enumerate(lines) if "</oor:items>" in l)
    except StopIteration:
        sys.exit(f"{target}: no </oor:items> found; leaving it alone")
    lines[end:end] = items
    new_text = "\n".join(lines) + "\n"
    if new_text == text:
        print(f"{target}: already up to date")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(new_text, encoding="utf-8")
    print(f"{target}: updated")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("merge-json", help="Deep-merge a JSON(C) object file into another")
    p.add_argument("target")
    p.add_argument("source")
    p.add_argument("--remove", action="append", default=[], help="Top-level key to drop first")
    p.set_defaults(func=cmd_merge_json)

    p = sub.add_parser("merge-keybindings", help="Merge VS Code keybindings arrays")
    p.add_argument("target")
    p.add_argument("source")
    p.add_argument("--remove-command", action="append", default=[])
    p.set_defaults(func=cmd_merge_keybindings)

    p = sub.add_parser("list-edit", help="Remove/append entries in a GVariant string list")
    p.add_argument("current")
    p.add_argument("--remove-contains", action="append", default=[])
    p.add_argument("--append", action="append", default=[])
    p.set_defaults(func=cmd_list_edit)

    p = sub.add_parser("list-set", help="Set one index in a fixed-length GVariant string list")
    p.add_argument("current")
    p.add_argument("--index", type=int, required=True)
    p.add_argument("--value", required=True)
    p.add_argument("--length", type=int, required=True)
    p.add_argument("--fill", required=True)
    p.set_defaults(func=cmd_list_set)

    p = sub.add_parser("pin-apps", help="Replace pinned panel launchers")
    p.add_argument("file")
    p.add_argument("--replace-prefix", required=True)
    p.add_argument("--with", dest="with_app", required=True)
    p.set_defaults(func=cmd_pin_apps)

    p = sub.add_parser("xcu-merge", help="Upsert LibreOffice registry items")
    p.add_argument("target")
    p.add_argument("items")
    p.set_defaults(func=cmd_xcu_merge)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
