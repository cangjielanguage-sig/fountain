#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""旧版 fountain 项目 import 重写（fountain-developer 技能 · 工作流 I 第 4.1 步）。

把 SDK 1.0.x / fountain 1.0.x 时代的两种包名写法改成当前写法：

  聚合根写法（老项目默认依赖 `fountain = {path/git}`）：
      import fountain.mvc.*            -> import fountain::f_mvc.*
      import fountain.mvc.macros.*     -> import fountain::f_mvc.macros.*
  旧扁平模块名（老项目直接依赖子模块时）：
      import f_mvc.*                   -> import fountain::f_mvc.*

依据（实测 release-1.0.54 -> release-1.3.16.alpha）：
  旧：src/mvc/mvc.cj = `package fountain.mvc` + `public import f_mvc.*`；f_mvc/src/*.cj = `package f_mvc`
  新：src/mvc/mvc.cj = `package fountain::fountain.mvc` + `public import fountain::f_mvc.*`；
      f_mvc/src/*.cj = `package fountain::f_mvc`

默认**只报告不改**（dry-run）；确认无误后加 `--apply` 落盘。落盘前请确保工作区干净
（`git status`），便于 `git diff` 复核、`git checkout --` 回退。

用法：
  python migrate_fountain_imports.py <项目根>              # 预演：列出将改写的行（不改文件）
  python migrate_fountain_imports.py <项目根> --apply      # 落盘
  python migrate_fountain_imports.py <项目根> --apply --quiet

只依赖 Python 3 标准库；Windows / WSL / Linux 通用。只改 `import` 行，其余一律不动。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# 老聚合根子包名（src/<seg>/<seg>.cj 的 `package fountain.<seg>`）-> 当前模块名。
# 依据 `git ls-tree release-1.0.54 -- src` 与 `git ls-tree HEAD -- src`。
AGGREGATE = {
    "app": "f_app",
    "aspect": "f_aspect",
    "base": "f_base",
    "bean": "f_bean",
    "cache": "f_cache",
    "collection": "f_collection",
    "concurrent": "f_concurrent",
    "config": "f_config",
    "data": "f_data",
    "exception": "f_exception",
    "http": "f_http",
    "httpclient": "f_httpclient",
    "io": "f_io",
    "jwt": "f_jwt",
    "log": "f_log",
    "macros": "f_macros",
    "mockdb": "f_mockdb",
    "mvc": "f_mvc",
    "net": "f_net",
    "orm": "f_orm",
    "pool": "f_pool",
    "process": "f_process",
    "random": "f_random",
    "regex": "f_regex",
    "rx": "f_rx",
    "security": "f_security",
    "ticktock": "f_ticktock",
    "time": "f_time",
    "util": "f_util",
    "version": "f_version",
}

# 当前 fountain 的库模块（`fountain::f_<x>`）；用于判断旧扁平 import `f_<x>` 是否该改写。
# 依据：仓库根各 `f_*/cjpm.toml` 与 `.modules` 的 [include]（f_llm / fleet 不发布，但同样能改写）。
MODULES = {
    "f_app", "f_aspect", "f_base", "f_bean", "f_bloom", "f_cache", "f_cmd", "f_codec",
    "f_collection", "f_concurrent", "f_config", "f_crypto", "f_data", "f_dbpool", "f_egraph",
    "f_exception", "f_health", "f_http", "f_httpclient", "f_io", "f_jwt", "f_log", "f_macros",
    "f_mockdb", "f_mvc", "f_net", "f_orm", "f_pool", "f_process", "f_protocol", "f_random",
    "f_regex", "f_rpc", "f_rx", "f_security", "f_store", "f_ticktock", "f_time", "f_uring",
    "f_util", "f_version",
}

SKIP_DIRS = {"target", ".git", ".build-logs", "node_modules", ".cache", ".assets"}

# import [修饰符] <模块>.<子包…>[.*]   （不含换行；行尾空白允许）
IMPORT_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<kw>(?:(?:public|protected|internal|private)[ \t]+)?import)[ \t]+"
    r"(?P<mod>[A-Za-z_][A-Za-z0-9_]*)(?P<rest>(?:\.[A-Za-z0-9_*]+)*)[ \t]*$"
)
# 非 import 行里的完全限定引用（需人工确认，如 `fountain.orm.DatabasePool`）
QUALIFIED_RE = re.compile(r"(?<![\w:])fountain\.[A-Za-z_]")


def rewrite_body(body: str) -> "tuple[str, str] | None":
    """返回 (新行内容, 命中类型) 或 None（不改）。"""
    m = IMPORT_RE.match(body)
    if not m:
        return None
    mod, rest = m.group("mod"), m.group("rest")
    if mod == "fountain":
        segs = [s for s in rest.split(".") if s]
        if not segs:
            return None
        new_mod = AGGREGATE.get(segs[0])
        if new_mod is None:
            return None
        tail = "".join("." + s for s in segs[1:])
        return f"{m.group('indent')}{m.group('kw')} fountain::{new_mod}{tail}", "聚合根"
    if mod in MODULES:
        return f"{m.group('indent')}{m.group('kw')} fountain::{mod}{rest}", "扁平模块名"
    return None


def iter_cj_files(root: Path):
    for p in sorted(root.rglob("*.cj")):
        if any(part in SKIP_DIRS for part in p.relative_to(root).parts):
            continue
        yield p


def scan_or_apply(path: Path, root: Path, apply: bool, quiet: bool):
    """返回 (改写数, {命中类型: 条数}, [未识别 import], [完全限定引用]) 或 None（读不了）。"""
    try:
        raw = path.read_bytes()
    except OSError as e:
        print(f"[跳过] {path}: 读取失败 {e}", file=sys.stderr)
        return None
    bom = b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b""
    try:
        text = raw[len(bom):].decode("utf-8")
    except UnicodeDecodeError:
        print(f"[跳过] {path}: 不是 UTF-8 文本", file=sys.stderr)
        return None

    out, changed, kinds, unknown, manual = [], 0, {}, [], []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        nl = line[len(body):]
        hit = rewrite_body(body)
        if hit is None:
            out.append(line)
            if body.lstrip().startswith("//"):
                continue
            m2 = IMPORT_RE.match(body)
            # 只收 fountain 系（fountain.* / f_*）的 import；std / 第三方 / 自研包名不报
            if m2 and (m2.group("mod") == "fountain" or m2.group("mod").startswith("f_")):
                unknown.append((path, body.strip()))
            elif QUALIFIED_RE.search(body):
                manual.append((path, body.strip()))  # 非 import 行的完全限定引用
            continue
        new_body, kind = hit
        out.append(new_body + nl)
        changed += 1
        kinds[kind] = kinds.get(kind, 0) + 1
        if not quiet:
            print(f"  {path.relative_to(root).as_posix()}: {body.strip()}  ->  {new_body.strip()}")

    if changed and apply:
        path.write_bytes(bom + "".join(out).encode("utf-8"))
    return changed, kinds, unknown, manual


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass

    ap = argparse.ArgumentParser(
        prog="migrate_fountain_imports.py",
        description="把旧版 fountain 包名 import（fountain.<seg> / f_<seg>）改写为 fountain::f_<seg>。",
    )
    ap.add_argument("project", help="项目根目录（workspace 根）")
    ap.add_argument("--apply", action="store_true", help="落盘改写（默认只预演）")
    ap.add_argument("--quiet", action="store_true", help="不逐行打印，只给汇总")
    args = ap.parse_args()

    root = Path(args.project).resolve()
    if not root.is_dir():
        print(f"项目根不存在或不是目录: {root}", file=sys.stderr)
        sys.exit(1)

    files = list(iter_cj_files(root))
    total, affected, kinds, unknown, manual = 0, 0, {}, [], []
    if not args.quiet:
        print(f"== {'改写' if args.apply else '预演'}（{root}）==")
    for f in files:
        got = scan_or_apply(f, root, args.apply, args.quiet)
        if got is None:
            continue
        changed, k, unk, m = got
        total += changed
        affected += 1 if changed else 0
        for key, v in k.items():
            kinds[key] = kinds.get(key, 0) + v
        unknown.extend(unk)
        manual.extend(m)

    print()
    print(f"== 汇总 ==")
    print(f"扫描 {len(files)} 个 .cj 文件；{'改写' if args.apply else '待改写'} {total} 行（{affected} 个文件）")
    for key, v in sorted(kinds.items()):
        print(f"  {key}: {v} 行")
    if total == 0:
        print("没有命中老写法 import（可能已升级，或项目用的是别的包名形式）。")
    for label, items in (
        ("未识别的 import（需人工确认）", unknown),
        ("非 import 行的 fountain.<seg> 完全限定引用（需人工确认）", manual),
    ):
        if not items:
            continue
        print(f"{label} {len(items)} 处：")
        for path, text in items[:20]:
            print(f"  {path.relative_to(root).as_posix()}: {text[:120]}")
        if len(items) > 20:
            print(f"  … 其余 {len(items) - 20} 处省略")
    print()
    if args.apply:
        print("已落盘。复验：grep -rn \"import fountain\\.\\|import f_\" --include='*.cj' . 应无输出；随后 fboot build。")
    else:
        print("预演结束（未改动）。确认后加 --apply 落盘。")


if __name__ == "__main__":
    main()
