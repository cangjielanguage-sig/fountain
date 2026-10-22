#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""opsx_progress.py — 采集 OpenSpec 流程与 cjpm/cjc 执行快照（每 5 分钟报告一次用）。

背景：工作流 F / G / H / I / J / L 中，从进入 OpenSpec 六步或执行任何 cjpm/cjc 命令开始，
就要按 references/opsx-waiting.md 的协议周期报告——不再判断「是否在等任务」或
「测试是否耗时太久」。本脚本负责把「进度」采集为确定性的数据——tasks 勾选、四件套、
工作区改动、后台输出、cjpm/cjc 进程与输出、停滞判定——避免每轮采集口径漂移。

用法：
    python3 opsx_progress.py --repo <仓库根> [--change <变更名>] [--stage apply] [--log <后台输出文件>]
    python3 opsx_progress.py --repo <仓库根> --json
    python3 opsx_progress.py --repo <仓库根> --reset      # 新任务开始时清掉上一轮快照

输出（默认人类可读）：在途变更 / 指定变更的 tasks 进度与当前任务、四件套、归档状态、
工作区改动、近 10 分钟改动文件、后台输出大小与尾部、cjpm/cjc 执行状况（默认经 ssh
采集）、与上轮的差异、停滞判定。
快照状态存 ~/.workbuddy/state/opsx-progress.json（按「仓库 + 变更」隔离，换任务自动重置）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

STATE = Path.home() / ".workbuddy" / "state" / "opsx-progress.json"
RECENT_MINUTES = 10
RECENT_LIMIT = 12
SKIP_DIRS = {".git", ".worktrees", "node_modules", "target", "build", "__pycache__", ".codebuddy", ".workbuddy"}


def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    try:
        p = subprocess.run([str(c) for c in cmd], cwd=str(cwd), capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, f"{type(exc).__name__}: {exc}"
    return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()


def find_openspec(repo: Path) -> Path | None:
    """从 repo 向上找 openspec 根（含 config.yaml 或 changes/）。"""
    p = repo
    for _ in range(6):
        cand = p / "openspec"
        if (cand / "config.yaml").is_file() or (cand / "changes").is_dir():
            return cand
        if p.parent == p:
            break
        p = p.parent
    return None


def parse_tasks(md: Path) -> dict | None:
    """解析 tasks.md：完成数 / 总数 / 第一个未完成任务。"""
    if not md.is_file():
        return None
    try:
        text = md.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    done = total = 0
    current = None
    for line in text.splitlines():
        m = re.match(r"^\s*[-*]\s+\[([ xX])\]\s+(.*)$", line)
        if not m:
            continue
        total += 1
        if m.group(1).lower() == "x":
            done += 1
        elif current is None:
            current = m.group(2).strip()
    return {"done": done, "total": total, "current": current}


def artifacts(change_dir: Path) -> dict:
    specs = list((change_dir / "specs").rglob("spec.md")) if (change_dir / "specs").is_dir() else []
    return {
        "proposal": (change_dir / "proposal.md").is_file(),
        "specs": bool(specs),
        "design": (change_dir / "design.md").is_file(),
        "tasks": (change_dir / "tasks.md").is_file(),
        "openspecYaml": (change_dir / ".openspec.yaml").is_file(),
    }


def git_summary(repo: Path) -> dict:
    code, out = run(["git", "-C", str(repo), "-c", "core.quotepath=false", "status", "--porcelain"], repo)
    if code != 0:
        return {"ok": False, "changed": None, "files": [], "detail": out[:200]}
    lines = [l for l in out.splitlines() if l.strip()]
    files = [l[3:].strip() for l in lines[:RECENT_LIMIT]]
    return {"ok": True, "changed": len(lines), "files": files}


def recent_files(repo: Path, minutes: int = RECENT_MINUTES) -> list[str]:
    """近 N 分钟修改过的文件（排除构建产物与无关目录），按 mtime 倒序。"""
    cutoff = time.time() - minutes * 60
    found: list[tuple[float, str]] = []
    for root, dirs, names in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in names:
            p = Path(root) / name
            try:
                st = p.stat()
            except OSError:
                continue
            if st.st_mtime >= cutoff:
                try:
                    rel = str(p.relative_to(repo))
                except ValueError:
                    rel = str(p)
                found.append((st.st_mtime, rel))
    found.sort(reverse=True)
    return [rel for _, rel in found[:RECENT_LIMIT]]


def log_info(path: Path | None) -> dict | None:
    if path is None or not path.is_file():
        return None
    try:
        size = path.stat().st_size
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    tail = [l.rstrip() for l in text.splitlines() if l.strip()][-5:]
    return {"size": size, "tail": tail}


def cjpm_status(repo: Path) -> dict:
    """经 ssh 采集融合侧 cjpm build/test 状况：进程 + 最近一次 cjpm 命令 + 输出尾部。

    数据来源：`ps` 的 cjpm/cjc 进程 + CodeBuddy 日志里最近一条 cjpm build/test 命令
    （含重定向输出文件，如 /tmp/xxx.log）。连不上 ssh / 没配 fusion.ssh 时优雅降级。
    """
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import opsx_fusion as fx  # noqa: E402
    except Exception as exc:  # noqa: BLE001
        return {"checked": False, "detail": f"无法加载 opsx_fusion：{exc}"}
    ssh = fx.ssh_config(fx.load_config(repo))
    if not ssh["host"] or not ssh["user"]:
        return {"checked": False, "detail": "fusion.ssh 未配置（先跑 opsx_fusion.py ssh-check）"}

    script = r'''
set -u
REPO=__REPO__
echo "=PROCS="
ps -eo pid,etime,pcpu,stat,args 2>/dev/null | grep -E "cjpm|cjc" | grep -v grep || true
echo "=CMD="
LOG=""
for f in $(ls -t "$HOME/.codebuddy/logs/$(date +%F)"/*.log 2>/dev/null); do
  if tail -n 3000 "$f" 2>/dev/null | grep -qF "$REPO"; then LOG="$f"; break; fi
done
[ -z "${LOG:-}" ] && LOG=$(ls -t "$HOME/.codebuddy/logs/$(date +%F)"/*.log 2>/dev/null | head -1)
if [ -n "${LOG:-}" ]; then
  LINE=$(tail -n 3000 "$LOG" 2>/dev/null | grep -E "cjpm (build|test)" | tail -1)
  printf "%s\n" "${LINE:-}"
  OUT=$(printf "%s" "${LINE:-}" | grep -oE "(> *|tee *)[^ ]+\.log" | head -1 | sed -E "s/^(> *|tee *)//")
  if [ -n "${OUT:-}" ] && [ -f "$OUT" ]; then
    echo "=OUT="
    echo "FILE=$OUT"
    stat -c "%s %y" "$OUT" 2>/dev/null || true
    echo "=TAIL="
    tail -n 12 "$OUT" 2>/dev/null || true
  fi
fi
'''.replace("__REPO__", shlex.quote(str(repo)))
    code, out = fx.run(["ssh", *fx.ssh_opts(ssh), fx.ssh_target(ssh), "bash -s"],
                       cwd=Path.home(), input_text=script, timeout=30)
    if code != 0:
        return {"checked": False, "detail": (out or "")[-300:]}

    sections: dict[str, list[str]] = {}
    cur: str | None = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("=") and s.endswith("=") and len(s) > 2:
            cur = s.strip("=")
            sections[cur] = []
        elif cur is not None:
            sections[cur].append(line)

    procs: list[dict] = []
    for line in sections.get("PROCS", []):
        parts = line.split(None, 4)
        if len(parts) >= 5:
            procs.append({"pid": parts[0], "etime": parts[1], "cpu": parts[2],
                          "stat": parts[3], "args": parts[4][:200]})

    cmd_lines = [l.strip() for l in sections.get("CMD", []) if l.strip()]
    command = cmd_lines[0] if cmd_lines else ""
    m = re.search(r'cmd="([^"]+)"', command)
    if m:
        command = m.group(1)
    out_file, out_size, out_mtime = "", None, ""
    for line in sections.get("OUT", []):
        if line.startswith("FILE="):
            out_file = line[len("FILE="):].strip()
        elif re.match(r"^\d+\s", line):
            bits = line.split(None, 1)
            out_size = int(bits[0]) if bits[0].isdigit() else None
            out_mtime = bits[1].strip() if len(bits) > 1 else ""

    return {"checked": True,
            "procs": procs,
            "command": command,
            "outputFile": out_file,
            "outputSize": out_size,
            "outputMtime": out_mtime,
            "outputTail": [l.rstrip() for l in sections.get("TAIL", []) if l.strip()][-8:]}


def load_state() -> dict:
    """返回 {"entries": {key: {...}}}；兼容旧的单条格式（文件里只有 key 字段）。"""
    if STATE.is_file():
        try:
            data = json.loads(STATE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {"entries": {}}
        if isinstance(data, dict):
            if isinstance(data.get("entries"), dict):
                return data
            if data.get("key"):
                return {"entries": {data["key"]: data}}
    return {"entries": {}}


def save_state(state: dict) -> None:
    """按任务隔离存快照（不同仓库/变更互不覆盖），只保留最近 10 条。"""
    entries = state.get("entries") or {}
    items = sorted(entries.items(), key=lambda kv: (kv[1] or {}).get("ts") or "", reverse=True)[:10]
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps({"entries": dict(items)}, ensure_ascii=False, indent=2) + "\n",
                     encoding="utf-8")


def collect(repo: Path, change: str | None, stage: str | None, log: Path | None,
            stall_rounds: int) -> dict:
    root = find_openspec(repo)
    result: dict = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "repo": str(repo),
        "openspecRoot": str(root) if root else None,
        "stage": stage,
        "change": change,
        "changes": [],
        "error": None,
    }
    if root is None:
        result["error"] = f"{repo} 及其上层找不到 openspec/（先按 openspec-workflow 第 1–2 节初始化）"
        return result

    changes_dir = root / "changes"
    archive_dir = changes_dir / "archive"
    live = sorted(p.name for p in changes_dir.iterdir() if p.is_dir() and p.name != "archive") \
        if changes_dir.is_dir() else []
    archived = sorted(p.name for p in archive_dir.iterdir() if p.is_dir()) \
        if archive_dir.is_dir() else []

    names = [change] if change else live
    for name in names:
        cdir = changes_dir / name
        item = {
            "name": name,
            "exists": cdir.is_dir(),
            "archived": name in archived,
            "tasks": parse_tasks(cdir / "tasks.md"),
            "artifacts": artifacts(cdir),
        }
        result["changes"].append(item)

    focus = result["changes"][0] if result["changes"] else None
    result["tasks"] = focus["tasks"] if focus else None
    result["artifacts"] = focus["artifacts"] if focus else None
    result["archived"] = focus["archived"] if focus else False
    result["liveChanges"] = live
    result["archivedChanges"] = archived
    result["git"] = git_summary(repo)
    result["recent"] = recent_files(repo)
    result["log"] = log_info(log)
    result["cjpm"] = cjpm_status(repo)

    # 停滞判定：与上轮快照（同一仓库 + 同一变更）做签名比较
    state = load_state()
    key = f"{repo}|{change or '*'}"
    prev = (state.get("entries") or {}).get(key) or {}
    signature = {
        "tasksDone": result["tasks"]["done"] if result["tasks"] else None,
        "tasksTotal": result["tasks"]["total"] if result["tasks"] else None,
        "gitChanged": result["git"]["changed"],
        "recent": sorted(result["recent"]),
        "logSize": result["log"]["size"] if result["log"] else None,
        "cjpmProcs": len((result["cjpm"] or {}).get("procs") or []) if result["cjpm"] else None,
        "cjpmOutSize": (result["cjpm"] or {}).get("outputSize") if result["cjpm"] else None,
    }
    prev_sig = prev.get("signature") or {}
    changed = [k for k, v in signature.items() if prev_sig.get(k) != v]
    if prev and not changed:
        stall_count = int(prev.get("stallRounds") or 0) + 1
    else:
        stall_count = 0
    result["round"] = int(prev.get("round") or 0) + 1 if prev else 1
    result["signature"] = signature
    result["changedFields"] = changed
    result["stallRounds"] = stall_count
    result["stalled"] = stall_count >= stall_rounds
    result["stallRoundsThreshold"] = stall_rounds
    result["previousTs"] = prev.get("ts")

    state.setdefault("entries", {})[key] = {
        "ts": result["ts"], "round": result["round"],
        "signature": signature, "stallRounds": stall_count,
    }
    save_state(state)
    return result


def render(result: dict) -> str:
    if result.get("error"):
        return f"✗ {result['error']}"
    lines: list[str] = []
    stage = f"  阶段：{result['stage']}" if result.get("stage") else ""
    lines.append(f"【OpenSpec 进度快照】{result['ts']} · 第 {result['round']} 轮{stage}")
    lines.append(f"仓库：{result['repo']}")
    lines.append(f"openspec 根：{result['openspecRoot']}")

    if not result["changes"]:
        lines.append("在途变更：无（changes/ 下还没有变更目录）")
    for item in result["changes"]:
        tags = []
        if not item["exists"]:
            tags.append("目录不存在")
        if item["archived"]:
            tags.append("已归档")
        suffix = f"（{'、'.join(tags)}）" if tags else ""
        lines.append(f"变更：{item['name']}{suffix}")
        arts = item["artifacts"]
        flags = " ".join(f"{k}{'✅' if v else '⬜'}" for k, v in arts.items())
        lines.append(f"  四件套：{flags}")
        t = item["tasks"]
        if t:
            pct = f"{t['done'] * 100 // t['total']}%" if t["total"] else "?"
            lines.append(f"  tasks：{t['done']}/{t['total']}（{pct}）")
            if t["current"]:
                lines.append(f"  当前任务：{t['current']}")
        else:
            lines.append("  tasks：tasks.md 不存在")

    git = result["git"]
    if git["ok"]:
        lines.append(f"工作区：{git['changed']} 个改动文件（git status）")
        for f in git["files"][:6]:
            lines.append(f"  · {f}")
        if git["changed"] and git["changed"] > 6:
            lines.append(f"  · …（其余 {git['changed'] - 6} 个）")
    else:
        lines.append(f"工作区：git 不可用（{git.get('detail', '')[:80]}）")

    if result["recent"]:
        lines.append(f"近 {RECENT_MINUTES} 分钟改动：{len(result['recent'])} 个文件")
        for f in result["recent"][:8]:
            lines.append(f"  · {f}")
    else:
        lines.append(f"近 {RECENT_MINUTES} 分钟改动：无")

    if result["log"]:
        lines.append(f"后台输出：{result['log']['size']} 字节")
        for l in result["log"]["tail"]:
            lines.append(f"  | {l}")
    elif result.get("stage"):
        lines.append("后台输出：未提供（--log）")

    cj = result.get("cjpm")
    if cj is not None:
        if not cj.get("checked"):
            lines.append(f"cjpm/cjc 状况：不可用（{(cj.get('detail') or '')[:120]}）")
        else:
            procs = cj.get("procs") or []
            if procs:
                lines.append(f"cjpm/cjc 状况：运行中（全局 {len(procs)} 个 cjpm/cjc 进程）")
                for p in procs[:3]:
                    lines.append(f"  · PID {p['pid']}  已 {p['etime']}  CPU {p['cpu']}%  STAT {p['stat']}  {p['args'][:90]}")
            else:
                lines.append("cjpm/cjc 状况：未在运行")
            if cj.get("command"):
                lines.append(f"  最近命令：{cj['command'][:200]}")
            if cj.get("outputFile"):
                size = cj.get("outputSize")
                lines.append(f"  输出：{cj['outputFile']}（{size if size is not None else '?'} 字节）")
                for l in cj.get("outputTail") or []:
                    lines.append(f"  | {l[:160]}")

    if result["stalled"]:
        lines.append(f"停滞：**是**（同一状态连续 {result['stallRounds']} 轮无变化，阈值 {result['stallRoundsThreshold']}）")
    else:
        if result["round"] == 1:
            changed = "（首轮，无基线）"
        elif result["changedFields"]:
            changed = "、".join(result["changedFields"])
        else:
            changed = "（无变化）"
        lines.append(f"停滞：否（同一状态连续 {result['stallRounds']} 轮无变化；本轮变化项：{changed}）")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="采集 OpenSpec 流程与 cjpm/cjc 执行快照（每 5 分钟报告用）")
    ap.add_argument("--repo", default=".", help="仓库根（含 openspec/ 的那一层或其下）")
    ap.add_argument("--change", help="变更名（缺省列出全部在途变更）")
    ap.add_argument("--stage", help="当前阶段标签（propose/apply/verify/archive 等，仅用于报告标注）")
    ap.add_argument("--log", help="后台任务输出文件（可选；报告大小与尾部）")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--reset", action="store_true", help="清掉上一轮快照（新任务开始时用）")
    ap.add_argument("--stall-rounds", type=int, default=3, help="连续多少轮无变化视为停滞（默认 3）")
    args = ap.parse_args()

    repo = Path(args.repo).expanduser().resolve()
    if args.reset:
        try:
            state = load_state()
            entries = state.get("entries") or {}
            keys = ([f"{repo}|{args.change}"] if args.change
                    else [k for k in entries if k.startswith(f"{repo}|")])
            removed = [k for k in keys if k in entries]
            for k in removed:
                del entries[k]
            if removed:
                save_state(state)
                print(f"✓ 已清除进度快照：{'、'.join(removed)}（下一轮从第 1 轮开始）")
            else:
                target = f"{repo}|{args.change}" if args.change else f"{repo}|*"
                print(f"（没有匹配的快照：{target}）")
        except OSError as exc:
            print(f"✗ 清除状态失败：{exc}", file=sys.stderr)
            return 1
        return 0

    if not repo.is_dir():
        print(f"✗ 仓库目录不存在：{repo}", file=sys.stderr)
        return 2

    result = collect(repo, args.change, args.stage,
                     Path(args.log).expanduser() if args.log else None, args.stall_rounds)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(render(result))
    return 0 if not result.get("error") else 2


if __name__ == "__main__":
    raise SystemExit(main())
