#!/usr/bin/env python3
"""fountain-tag 技能：把版本号 a.b.c 批量改成 x.y.z（本脚本只改文件；提交、推送、合入 master、打 tag 由技能 Step 3 起完成）。

用法：
    python bump_version.py <x.y.z> --old <a.b.c> --root <仓库根> [--dry-run]
    python bump_version.py <x.y.z> --root <仓库根>          # --old 省略时从最新 tag 推导

改动范围：
    1. 仓库内所有 cjpm.toml 的 version 节点 -> version = "x.y.z"
       （默认按值匹配，只替换值正好等于 a.b.c 的节点；
         fdemo/、frpcdemo/ 子树下的 cjpm.toml 不论当前值一律同步，因为它们跟随发布走）
    2. f_version/src/FountainVersion.cj："a.b.c"  ->  "x.y.z"

根 README.md / README_en.md 不参与替换：其模块文档链接已改为版本无关形态
（https://gitcode.com/Cangjie-SIG/fountain/blob/master/<模块>/README.md）。

按字节读写，保留原有换行（LF/CRLF）与 BOM 状态。
退出码：0 = 有替换；2 = 一个都没替换（多半是 --old 传错）；1 = 参数/环境错误。
"""
import argparse
import os
import re
import subprocess
import sys

VER = re.compile(r"^\d+\.\d+\.\d+$")
VER_NODE = re.compile(r'^([ \t]*)version = "\d+\.\d+\.\d+"', re.M)
TAG_VER = re.compile(r"^release-(\d+\.\d+\.\d+)(?:\.(?:alpha|beta))?$")
FORCE_DIRS = ("fdemo/", "frpcdemo/")
VERSION_CJ = os.path.join("f_version", "src", "FountainVersion.cj")


def run_git(root, *args):
    return subprocess.run(("git", "-C", root) + args, capture_output=True, check=True).stdout


def repo_files(root):
    """仓库内受版本控制的文件；不是 git 仓库时退回遍历目录。"""
    try:
        out = run_git(root, "ls-files", "-z")
        return [p.decode("utf-8") for p in out.split(b"\0") if p]
    except Exception:
        skip = {".git", "target", ".worktrees", "build", "node_modules"}
        found = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in skip]
            found += [os.path.relpath(os.path.join(dirpath, f), root) for f in filenames]
        return found


def latest_tag_version(root):
    out = run_git(root, "tag", "--sort=-creatordate").decode("utf-8", "replace")
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if not lines:
        raise SystemExit("错误：仓库里没有 tag，无法推导 a.b.c，请用 --old 显式指定。")
    m = TAG_VER.match(lines[0])
    if not m:
        raise SystemExit("错误：最新 tag %s 不符合 release-x.y.z[.alpha|beta]，请用 --old 显式指定。" % lines[0])
    return m.group(1)


def read_text(path):
    with open(path, "rb") as fh:
        data = fh.read()
    return data.decode("utf-8-sig"), data.startswith(b"\xef\xbb\xbf")


def write_text(path, text, bom):
    with open(path, "wb") as fh:
        fh.write((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8"))


def apply(path, transform, dry_run):
    """transform(text) -> (新文本, 命中数)；命中数为 0 时不动这个文件。"""
    if not os.path.isfile(path):
        print("跳过（文件不存在）: %s" % path)
        return 0
    text, bom = read_text(path)
    result, hits = transform(text)
    if not hits:
        return 0
    if not dry_run:
        write_text(path, result, bom)
    print("%-6s %-52s x%d" % ("[dry]" if dry_run else "改", path, hits))
    return hits


def bump(path, old, new, dry_run):
    """把片段 old 替换成片段 new。"""
    return apply(path, lambda t: (t.replace(old, new), t.count(old)), dry_run)


def bump_version_nodes(path, new_version, dry_run):
    """把行首的 version 节点替换成 new_version（不论当前值），不动同行内的依赖版本。"""
    return apply(
        path,
        lambda t: VER_NODE.subn(lambda m: '%sversion = "%s"' % (m.group(1), new_version), t),
        dry_run,
    )


def main():
    ap = argparse.ArgumentParser(description="版本号 a.b.c -> x.y.z（只改文件，不 commit）")
    ap.add_argument("new_version", help="x.y.z")
    ap.add_argument("--old", help="a.b.c；省略时从最新 tag 推导")
    ap.add_argument("--root", default=".", help="仓库根目录")
    ap.add_argument("--dry-run", action="store_true", help="只报告不落盘")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    new = args.new_version.strip()
    if not VER.match(new):
        raise SystemExit("错误：新版本号 %r 不是 x.y.z 形式。" % args.new_version)
    old = args.old.strip() if args.old else latest_tag_version(root)
    if not VER.match(old):
        raise SystemExit("错误：旧版本号 %r 不是 x.y.z 形式。" % old)
    if old == new:
        raise SystemExit("错误：新旧版本号相同（%s），无需替换。" % new)

    print("版本号 %s -> %s（仓库根: %s）" % (old, new, root))
    print("不论当前值一律同步的目录：%s" % "、".join(FORCE_DIRS))
    total = 0
    for rel in sorted(repo_files(root)):
        if os.path.basename(rel) != "cjpm.toml":
            continue
        target = os.path.join(root, rel)
        if rel.replace(os.sep, "/").startswith(FORCE_DIRS):
            total += bump_version_nodes(target, new, args.dry_run)
        else:
            total += bump(target, 'version = "%s"' % old, 'version = "%s"' % new, args.dry_run)
    total += bump(os.path.join(root, VERSION_CJ), '"%s"' % old, '"%s"' % new, args.dry_run)

    print("合计替换 %d 处%s" % (total, "（dry-run，未落盘）" if args.dry_run else ""))
    if total == 0:
        print("提示：没有任何替换。核对该仓库文件里当前的版本号是否等于 --old %s。" % old)
        return 2
    if not args.dry_run:
        print("下一步复核 git -C %s diff --stat，确认只动版本号后按技能 Step 3 提交并推送。" % root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
