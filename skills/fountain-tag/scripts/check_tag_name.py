#!/usr/bin/env python3
"""fountain-tag 技能：校验一个候选 tag 名（只读：不建 tag、不 fetch、不改任何文件）。

三条规则，全过才算通过：
    1. 名字匹配 ^release-(\\d+\\.\\d+\\.\\d+)(\\.(alpha|beta))?$ —— 数字版本必须正好是 a.b.c 三段
       （大小写敏感；后缀只认小写 .alpha / .beta）。全仓库只有 release-a.b.c 与 release-a.b.c.alpha|.beta 两种形态：
       单段 release-1、两段 release-1.4、四段起 release-1.3.16.1 / release-1.3.16.1.alpha、大写 .Alpha、v1.3.16 都不合规）；
    2. 数字版本 a.b.c 在**所有 tag** 中唯一 —— 任何 tag 名里出现同一个 a.b.c 就算被占用
       （如已有 release-1.3.15.alpha，则 release-1.3.15 与 release-1.3.15.beta 都不能再用）；
    3. 数字版本 a.b.c 必须**大于当前最新 tag** 的数字版本（逐段数值比较，不是字典序：1.3.10 > 1.3.9）。
       「最新 tag」= git tag --sort=-creatordate 首行（与技能 Step 0 同一口径）。

用法：
    python check_tag_name.py <候选 tag 名> [--root <仓库根>]
    python check_tag_name.py release-1.3.16.alpha

退出码：
    0 = 三条全过；
    1 = 违反规则（打印违反的是哪条、撞了哪些 tag、最新 tag 是什么）；
    2 = 环境错误（不是 git 仓库、取不到本地 tag 列表）。
远端（origin）tag 列表取不到时只打印警告，判定退回本地 tag —— 不 fetch、不报错退出。
"""
import argparse
import re
import subprocess
import sys

TAG_FULL = re.compile(r"^release-(\d+)\.(\d+)\.(\d+)(\.(alpha|beta))?$")
# 不合规的 tag 名（四段、大写后缀等）也要能取出它占用的 a.b.c，否则会漏判唯一性
TAG_PREFIX = re.compile(r"^release-(\d+)\.(\d+)\.(\d+)")


def run_git(root, *args, check=True):
    return subprocess.run(("git", "-C", root) + args, capture_output=True, check=check)


def die(msg):
    """环境错误：打印到 stderr 并以退出码 2 结束（1 留给「违反规则」）。"""
    print("错误：%s" % msg, file=sys.stderr)
    sys.exit(2)


def numbered(name):
    """取出 tag 名占用的 a.b.c；取不出返回 None。"""
    m = TAG_FULL.match(name)
    if m:
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    m = TAG_PREFIX.match(name)
    if m:
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return None


def fmt(v):
    return "None" if v is None else "%d.%d.%d" % v


def local_tags(root):
    p = run_git(root, "tag", check=False)
    if p.returncode != 0:
        die("取不到本地 tag 列表（当前目录不是 git 仓库？用 --root 指定仓库根）")
    return [ln.strip() for ln in p.stdout.decode("utf-8", "replace").splitlines() if ln.strip()]


def latest_tag(root):
    """最新 tag = git tag --sort=-creatordate 首行（与技能 Step 0 同一口径）。"""
    p = run_git(root, "tag", "--sort=-creatordate", check=False)
    if p.returncode != 0:
        die("取不到 tag 列表（当前目录不是 git 仓库？用 --root 指定仓库根）")
    lines = [ln.strip() for ln in p.stdout.decode("utf-8", "replace").splitlines() if ln.strip()]
    return lines[0] if lines else None


def remote_tags(root):
    """origin 上的 tag 名；取不到返回 None（只警告，不阻断）。"""
    p = run_git(root, "ls-remote", "--tags", "origin", check=False)
    if p.returncode != 0:
        return None
    names = []
    for ln in p.stdout.decode("utf-8", "replace").splitlines():
        parts = ln.split("refs/tags/")
        if len(parts) == 2:
            name = parts[1].strip()
            names.append(name[:-3] if name.endswith("^{}") else name)
    return names


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="校验候选 tag 名：a.b.c 三段 / 全 tag 唯一 / 大于最新 tag（只读）"
    )
    ap.add_argument("name", help="候选 tag 名，如 release-1.3.16.alpha")
    ap.add_argument("--root", default=".", help="仓库根（默认当前目录）")
    args = ap.parse_args(argv)

    name = args.name.strip()
    tags = local_tags(args.root)
    if not tags:
        raise SystemExit("错误：仓库里一个 tag 都没有，无法判定唯一性与递增。")
    latest = latest_tag(args.root)
    latest_ver = numbered(latest)

    local_ver = {}
    for t in tags:
        v = numbered(t)
        if v is not None:
            local_ver.setdefault(v, []).append(t)
    remote = remote_tags(args.root)
    remote_ver = {}
    if remote is not None:
        for t in remote:
            v = numbered(t)
            if v is not None:
                remote_ver.setdefault(v, []).append(t)

    print("候选名 : %s" % name)
    print("最新 tag: %s（a.b.c = %s，按 --sort=-creatordate）" % (latest, fmt(latest_ver)))
    print("tag 总量: 本地 %d 个%s" % (len(tags), "" if remote is None else " / origin %d 个" % len(remote)))
    if remote is None:
        print("警告  : 取不到 origin 的 tag 列表（网络或权限），唯一性只在本地 tag 上判定。")

    bad = []

    # 规则 1：三段数字版本
    m = TAG_FULL.match(name)
    ver = numbered(name)
    if m is None:
        bad.append(
            "规则 1（a.b.c 三段）不通过：名字不匹配 ^release-\\d+(\\.\\d+){2}(\\.(alpha|beta))?$"
            "（数字版本必须正好三段：单段 release-1、两段 release-1.4、四段起 release-1.3.16.1 或"
            " release-1.3.16.1.alpha 都不合规；大小写敏感，后缀只认小写 .alpha / .beta）"
        )
    else:
        print("规则 1 : 通过（数字版本 %s，后缀 %s）" % (fmt(ver), m.group(4)[1:] if m.group(4) else "无"))

    # 规则 2：a.b.c 在所有 tag 中唯一（含远端）
    if ver is not None:
        hit_local = local_ver.get(ver, [])
        hit_remote = [
            t for t in (remote_ver.get(ver, []) if remote is not None else []) if t not in hit_local
        ]
        if hit_local or hit_remote:
            shown = ", ".join(sorted(set(hit_local + hit_remote))[:6])
            bad.append("规则 2（a.b.c 唯一）不通过：%s 已被 %s 占用" % (fmt(ver), shown))
        else:
            print("规则 2 : 通过（%s 未被任何 tag 占用）" % fmt(ver))

        # 规则 3：大于最新 tag
        if latest_ver is None:
            bad.append(
                "规则 3（大于最新 tag）无法判定：最新 tag %s 解析不出 a.b.c —— 需人工确认该名确实大于它" % latest
            )
        elif ver <= latest_ver:
            bad.append(
                "规则 3（大于最新 tag）不通过：%s 不大于最新 tag %s（%s）" % (fmt(ver), latest, fmt(latest_ver))
            )
        else:
            print("规则 3 : 通过（%s > %s）" % (fmt(ver), fmt(latest_ver)))

    if bad:
        print("")
        for b in bad:
            print("不通过: %s" % b)
        print("结论  : 换名后重跑（不要改用较低版本，也不要 -f 覆盖已有 tag）")
        return 1
    print("结论  : 三条全过，可用作本次 tag 名")
    return 0


if __name__ == "__main__":
    sys.exit(main())
