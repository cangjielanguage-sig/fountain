#!/usr/bin/env python3
r"""fountain-tag 技能：把目标文本文件的换行符统一为 LF（只动换行，不动内容）。

候选文件（取并集；不带选项时 = 待提交文件）：
    默认         工作区里待提交的文件：已跟踪的改动 + 未跟踪的新文件（--exclude-standard，跳过 ignored）
    --base BASE  追加 BASE..TARGET 区间内改动过的文件（TARGET 默认 origin/master、回退 master）
                 —— 技能 Step 1.5 的「上一个 tag 到 master 最新提交」口径
    --all        追加全部受版本控制的文件
    --paths ...  追加显式路径（相对仓库根）

只碰 git 判定为文本的文件：二进制（-text）与空文件跳过、已删除的路径跳过；只把 CRLF（\r\n）换成 LF（\n）。
修正后索引侧仍是 CRLF（i/crlf）的文件会单独列出 —— 那些要 git add 才会以 LF 入库（随本次提交）。

用法：
    python normalize_newlines.py                        # 只处理待提交文件
    python normalize_newlines.py --base release-1.3.16.alpha
    python normalize_newlines.py --base BASE --check    # 只报告，不写文件
    python normalize_newlines.py --all --check          # 全仓体检

退出码：
    0 = 无需修正（或已修正完成）；
    1 = --check 模式下存在需要修正的文件；
    2 = 环境错误（不是 git 仓库、区间取不到等）。
"""
import argparse
import os
import subprocess
import sys

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")


def die(msg):
    """环境错误：打印到 stderr 并以退出码 2 结束（1 留给「需要修正」）。"""
    print("错误：%s" % msg, file=sys.stderr)
    sys.exit(2)


def run_git(root, *args, check=True):
    p = subprocess.run(("git", "-C", root) + args, capture_output=True)
    if check and p.returncode != 0:
        die("git %s 失败：%s" % (" ".join(args), p.stderr.decode("utf-8", "replace").strip()))
    return p


def split_z(out):
    """NUL 分隔的输出 -> 路径列表。"""
    return [x.decode("utf-8", "replace") for x in out.split(b"\0") if x]


def repo_root():
    p = subprocess.run(("git", "rev-parse", "--show-toplevel"), capture_output=True)
    if p.returncode != 0:
        die("当前目录不是 git 仓库（用 --root 指定仓库根）")
    return p.stdout.decode("utf-8", "replace").strip()


def parse_eol(out):
    """git ls-files --eol -> {path: (index_state, worktree_state)}，如 ('i/lf', 'w/crlf')。"""
    m = {}
    for line in out.decode("utf-8", "replace").splitlines():
        if "\t" not in line:
            continue
        head, path = line.split("\t", 1)
        parts = head.split()
        if len(parts) >= 2:
            m[path] = (parts[0], parts[1])
    return m


def workspace_candidates(root):
    """待提交文件：已跟踪的改动（含暂存的新增/修改）+ 未跟踪的新文件。"""
    names = set(split_z(run_git(
        root, "-c", "core.quotepath=false", "ls-files", "-m", "-o", "--exclude-standard", "-z").stdout))
    names |= set(split_z(run_git(
        root, "-c", "core.quotepath=false", "diff", "--cached", "--name-only",
        "--diff-filter=ACMR", "-z").stdout))
    return names


def resolve_target(root, explicit):
    for cand in ([explicit] if explicit else ["origin/master", "master"]):
        if run_git(root, "rev-parse", "--verify", "--quiet", cand, check=False).returncode == 0:
            return cand
    die("取不到目标提交：origin/master 与 master 都不存在（先 git fetch origin）")


def base_candidates(root, base, target):
    if run_git(root, "rev-parse", "--verify", "--quiet", base, check=False).returncode != 0:
        die("起始提交 %s 不存在（tag 名写错？先 git fetch origin --tags）" % base)
    out = run_git(root, "-c", "core.quotepath=false", "diff", "--name-only",
                  "--diff-filter=d", "-z", "%s..%s" % (base, target)).stdout
    return set(split_z(out))


def norm_path(root, p):
    p = p.replace("\\", "/")
    if os.path.isabs(p):
        p = os.path.relpath(p, root).replace("\\", "/")
    return p


def looks_binary(full):
    try:
        with open(full, "rb") as f:
            return b"\0" in f.read(8000)
    except OSError:
        return True


def main():
    ap = argparse.ArgumentParser(description="把文本文件的换行符统一为 LF（只动换行，不动内容）")
    ap.add_argument("--base", help="起始 tag / 提交：BASE..TARGET 区间内改动的文件也纳入检查")
    ap.add_argument("--target", help="区间终点（默认 origin/master，回退 master）")
    ap.add_argument("--all", action="store_true", help="纳入全部受版本控制的文件")
    ap.add_argument("--check", action="store_true", help="只报告，不写文件；存在待修正文件时退出码 1")
    ap.add_argument("--paths", nargs="*", default=[], help="追加显式路径（相对仓库根）")
    ap.add_argument("--root", help="仓库根（默认自动探测）")
    args = ap.parse_args()

    root = args.root or repo_root()
    if run_git(root, "rev-parse", "--git-dir", check=False).returncode != 0:
        die("--root 指向的不是 git 仓库：%s" % root)

    eol = parse_eol(run_git(root, "-c", "core.quotepath=false", "ls-files", "--eol").stdout)

    scope = ["待提交文件"]
    targets = set(workspace_candidates(root))
    if args.all:
        targets |= set(eol)
        scope.append("全部 tracked 文件")
    if args.base:
        target = resolve_target(root, args.target)
        targets |= base_candidates(root, args.base, target)
        scope.append("%s..%s 区间改动" % (args.base, target))
    for pth in args.paths:
        targets.add(norm_path(root, pth))
    if args.paths:
        scope.append("显式路径 %d 个" % len(args.paths))

    if not targets:
        print("检查范围（%s）：0 个文件，无需处理。" % " + ".join(scope))
        return 0

    fixed, already, skipped, broken_index = [], [], [], []
    for path in sorted(targets):
        full = os.path.join(root, *path.split("/"))
        if not os.path.isfile(full):
            skipped.append((path, "不存在（已删除或路径失效）"))
            continue
        i_state, w_state = eol.get(path, (None, None))
        if w_state == "w/-text" or (w_state is None and looks_binary(full)):
            skipped.append((path, "二进制"))
            continue
        if w_state == "w/none":
            skipped.append((path, "空文件"))
            continue
        with open(full, "rb") as f:
            data = f.read()
        if b"\r\n" not in data:
            already.append(path)
            if i_state in ("i/crlf", "i/mixed"):
                broken_index.append(path)
            continue
        count = data.count(b"\r\n")
        if args.check:
            fixed.append((path, count, i_state))
        else:
            with open(full, "wb") as f:
                f.write(data.replace(b"\r\n", b"\n"))
            fixed.append((path, count, i_state))
        if i_state in ("i/crlf", "i/mixed"):
            broken_index.append(path)

    print("检查范围（%s）：候选 %d 个文件。" % (" + ".join(scope), len(targets)))
    if args.check:
        print("需要修正（工作区 CRLF -> LF，尚未写入）：%d 个" % len(fixed))
    else:
        print("已修正（工作区 CRLF -> LF）：%d 个" % len(fixed))
    for path, count, i_state in fixed:
        print("  %s（%d 处 CRLF%s）" % (path, count, "，索引侧 %s" % i_state if i_state in ("i/crlf", "i/mixed") else ""))
    print("已是最新 LF：%d 个" % len(already))
    if broken_index:
        print("注意：以下文件索引侧仍是 CRLF，git add 后才会以 LF 入库（别漏提交）：")
        for path in sorted(set(broken_index)):
            print("  %s" % path)
    if skipped:
        kinds = {}
        for _, why in skipped:
            kinds[why] = kinds.get(why, 0) + 1
        print("跳过：%d 个（%s）" % (len(skipped), "；".join("%s %d" % kv for kv in sorted(kinds.items()))))

    if args.check and fixed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
