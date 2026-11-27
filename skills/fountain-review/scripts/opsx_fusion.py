#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""opsx_fusion.py — 为 openspec 的 /opsx:* 工作流生成「经 ssh 在融合开发引擎上执行」的命令块。

2026-10-16 新增，配套 12 个 opsx-* 技能（opsx-propose / opsx-explore / ... / opsx-onboard）。
2026-10-16 二次改造：访问融合开发引擎的方式从「粘贴到融合终端面板」改为 ssh；
连接信息固化在配置文件的 fusion.ssh 段——首次访问询问用户，IP 失效重新询问
（见 ssh-check / ssh-set / ssh-push-key 三个子命令）。

它解决的问题（都是「无技能基线」里实测踩到的坑）：
  1) 路径要换算：鸿蒙侧 ~/Documents/... 在融合环境里是 /mnt/linux_share/... ；
  2) worktree 必须先用 `git worktree list` 发现，不许现编分支名与父目录；
  3) 「子目录」= worktree 内承载 openspec 根（openspec/config.yaml）的那一层；
  4) 产物形状固定：一个 bash 代码块，ssh + heredoc，①定位 ②预检 ③执行，三段固定顺序；
  5) ssh 连接先探测再执行；失败按原因分流：配置缺失问用户、IP 失效重问、认证失败配免密；
  6) codebuddy 未装要给出安装命令，而不是假设它在 PATH；
  7) 权限模式要显式（默认 acceptEdits，可选 skip-permissions）。

子命令
------
  worktrees [--repo P] [--json]
      列出现有 worktree（等价 `git worktree list`，带鸿蒙/融合双侧路径）。

  preflight [--repo P] [--worktree W] [--subdir S] [--workflow N] [--json]
      鸿蒙侧只读体检。同一份文件两侧都可见，所以能在交接命令块之前就把
      「worktree 不存在 / 子目录下没有 openspec 根 / 该工作流未安装」查出来。
      退出码：0 全通过；2 有硬错误（应停止，不要交接命令块）。

  target [--repo P] [--worktree W] [--subdir S] [--json]
      解析目标三元组，打印鸿蒙侧路径与融合侧路径。

  ssh-check [--repo P] [--json]
      探测融合开发引擎的 ssh 可达性（免密/key 认证，只读）。
      退出码：0 可达；2 配置缺失（问用户 IP/用户名/密码，再用 ssh-set 固化）；
              3 连接失败（reason=unreachable 视为 IP 失效、要重问；auth-failed 用 ssh-push-key
                自动配免密；host-key-changed 指引用户清 known_hosts）。

  ssh-set --host H --user U [--port N] [--password-stdin | --no-password]
      固化/更新连接信息到用户级配置 ~/.workbuddy/openspec-fusion.json 的 fusion.ssh 段。
      密码经 stdin 传入（不落 argv）；已配置免密的机器用 --no-password。

  ssh-push-key [--repo P] [--json]
      用配置里的密码把本机公钥推到融合引擎（幂等：已存在不重复加），一次性配好免密。
      本机没有密钥时自动 ssh-keygen 生成 ed25519。

  plan --workflow N [--repo P] [--worktree W] [--subdir S] [--request TEXT | --change NAME]
       [--yolo] [--json]
      生成命令块正文（不带围栏，调用方放进 ```bash 块里）。preflight 有硬错误时
      拒绝生成并退出 2。

配置（可选，两个位置都读，项目内覆盖用户级；fusion 段做子键级合并）
------------------------------------------------------------
  项目内：<repo>/.workbuddy/openspec-fusion.json
  用户级：~/.workbuddy/openspec-fusion.json

```json
{
  "repo": "/storage/Users/currentUser/Documents/cangjie/projects/fountain",
  "defaultWorktree": "fountain",
  "defaultSubdir": ".",
  "subdirs": { "f_store": "f_store", "f_io": "f_io" },
  "fusion": {
    "sharePrefix": "/mnt/linux_share",
    "ssh": { "host": "172.16.105.2", "user": "running", "port": 22 },
    "permissionMode": "acceptEdits"
  }
}
```

  repo            fountain 仓库（主 worktree）路径。
  defaultWorktree worktree 名或绝对路径；缺省用主仓库。
  defaultSubdir   子目录（相对 worktree）；缺省 "."（worktree 根）。
  subdirs         子目录别名 → 实际相对路径，方便只写 `--subdir f_store`。
  fusion.ssh      融合引擎连接信息：host / user / port（缺省 22）/ password（仅配免密时用一次）。
  fusion.permissionMode "acceptEdits" | "skip"。

不做的事
--------
  * 不执行 `loh`（鸿蒙系统二进制，WorkBuddy 沙箱里 Permission denied）；
    命令块由调用方（WorkBuddy 技能）经 ssh 代跑，或用户手动整段执行——本脚本本身只读。
  * 不建 worktree、不跑 openspec init、不改任何文件；唯一例外是 ssh-set 写自己的配置文件。
  * 密码不落 argv：经 stdin 与 SSH_ASKPASS 临时脚本（700，用完即删）传递。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HOME = Path(os.environ.get("HOME") or "/storage/Users/currentUser")

# 融合开发引擎把鸿蒙用户目录挂在这里；融合侧的 $HOME 就是 FUSION_HOME。
SHARE_PREFIX_DEFAULT = "/mnt/linux_share"
FUSION_HOME_DEFAULT = Path(SHARE_PREFIX_DEFAULT) / str(HOME).lstrip("/")

DEFAULT_REPO = HOME / "Documents" / "cangjie" / "projects" / "fountain"
CONFIG_REL = Path(".workbuddy") / "openspec-fusion.json"
CONFIG_USER = HOME / ".workbuddy" / "openspec-fusion.json"

# ssh 访问融合开发引擎：密钥落点与脚本自身路径（错误信息里要给出可复制的命令）
SSH_KEY_REL = Path(".ssh") / "id_ed25519"
SELF = str(Path(__file__).resolve())

# 12 个工作流：id -> (标题, 是否核心, 斜杠命令尾参提示, 产物说明)
WORKFLOWS: dict[str, tuple[str, bool, str, str]] = {
    "propose": ("创建变更 + 一次性产出全部规划文档", True,
                "变更名或一句话需求", "openspec/changes/<变更名>/{proposal.md, specs/**, design.md, tasks.md}"),
    "explore": ("探索模式：想清楚再动手，只思考不实现", True,
                "话题（可选）", "可选：把讨论沉淀成变更产物"),
    "apply": ("按 tasks.md 实施变更（写代码）", True,
              "变更名（可选）", "代码改动 + tasks.md 勾选"),
    "update": ("修订既有变更的规划文档并保持自洽", True,
               "变更名（可选）", "更新后的 proposal / specs / design / tasks"),
    "sync": ("把变更的增量规范合并进主规范", True,
             "变更名（可选）", "openspec/specs/ 下的主规范"),
    "archive": ("归档已完成的变更并沉淀主规范", True,
                "变更名（可选）", "openspec/changes/archive/ + 主规范更新"),
    "new": ("只建变更脚手架，不生成文档", False,
            "变更名", "openspec/changes/<变更名>/ 空骨架"),
    "continue": ("逐个补齐缺失的下一份文档", False,
                 "变更名（可选）", "proposal → specs → design → tasks 之中下一份"),
    "ff": ("快速生成全部规划文档", False,
           "变更名（可选）", "proposal / specs / design / tasks 四件套"),
    "verify": ("校验实现与变更产物是否一致", False,
               "变更名（可选）", "校验报告（不自动改产物）"),
    "bulk-archive": ("批量归档多个已完成变更", False,
                     "（无）", "多个变更进入 archive/"),
    "onboard": ("扫描代码库反向生成初始规范", False,
                "（无）", "初始 openspec/specs/"),
}

CORE = {k for k, v in WORKFLOWS.items() if v[1]}

# 这两个工作流没有主题就没有意义：空尾参会静默产出一个错变更，属于必须拦下的形状错误。
REQUIRES_TAIL = {"new", "propose"}

# 这些工作流作用在**已存在**的变更上：给了变更名就去查它到底在不在，
# 免得把「变更名打错 / 已归档 / 根本还没建」拖到融合侧才暴露。
EXISTING_CHANGE_WORKFLOWS = {"apply", "update", "sync", "archive", "verify", "continue", "ff"}

# 归错变更 / 校验错变更的代价最高（主规范是不可逆的「真相之源」），所以这两个强制给名字。
REQUIRES_CHANGE = {"archive", "verify"}


def to_fusion(path: Path | str, share_prefix: str = SHARE_PREFIX_DEFAULT) -> str:
    """鸿蒙侧绝对路径 → 融合环境可见路径。不在用户家目录下的原样返回。"""
    p = Path(path)
    try:
        rel = p.relative_to(HOME)
    except ValueError:
        return str(p)
    return str(Path(share_prefix) / str(HOME).lstrip("/") / rel)


def _abs_tool(name: str, *fallbacks: str) -> str:
    """解析外部命令为绝对路径。

    鸿蒙侧的两个坑：① 调用方 cwd 被子进程继承时可能是坏的，spawn 会 ENOENT；
    ② Python 的 PATH 未必与交互 shell 一致。所以先就地各候选目录探测，再退到 which。
    """
    for d in (os.environ.get("PATH") or "").split(os.pathsep):
        cand = Path(d) / name if d else None
        if cand and cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    for fb in fallbacks:
        if Path(fb).is_file() and os.access(fb, os.X_OK):
            return fb
    return name


GIT = _abs_tool("git", "/data/service/hnp/bin/git", "/usr/bin/git")
SSH = _abs_tool("ssh", "/usr/bin/ssh")
SSH_KEYGEN = _abs_tool("ssh-keygen", "/usr/bin/ssh-keygen")


def run(cmd: list[str], cwd: Path | None = None, input_text: str | None = None,
        env_extra: dict | None = None, timeout: int = 20) -> tuple[int, str]:
    argv = [str(c) for c in cmd]
    if argv and argv[0] in ("git", "ssh", "ssh-keygen"):
        argv[0] = {"git": GIT, "ssh": SSH, "ssh-keygen": SSH_KEYGEN}[argv[0]]
    # cwd 一律给绝对路径：继承一个坏 cwd 会让 spawn 直接 ENOENT。
    work = str(cwd) if cwd else str(HOME)
    if not Path(work).is_dir():
        work = str(HOME)
    env = {**os.environ, **env_extra} if env_extra else None
    try:
        proc = subprocess.run(argv, cwd=work, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=timeout,
                              input=input_text, env=env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, f"{type(exc).__name__}: {exc}"
    return proc.returncode, ((proc.stdout or "") + (proc.stderr or "")).strip()


def _deep_merge(dst: dict, src: dict) -> None:
    """子键级合并：嵌套 dict 递归，其余整体覆盖。

    浅合并的坑：项目级只写 fusion.permissionMode，会把用户级的 fusion.ssh 整个抹掉，
    ssh 配置「凭空消失」，技能又去问一遍用户。所以 fusion 这类嵌套段必须子键合并。
    """
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _deep_merge(dst[k], v)
        else:
            dst[k] = v


def load_config(repo: Path) -> dict:
    cfg: dict = {}
    sources: list[str] = []
    for path in (CONFIG_USER, repo / CONFIG_REL):
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                print(f"[warn] 配置解析失败，忽略 {path}: {exc}", file=sys.stderr)
                continue
            if isinstance(data, dict):
                _deep_merge(cfg, data)
                sources.append(str(path))
    if sources:
        cfg["_sources"] = sources
    return cfg


def share_prefix(cfg: dict) -> str:
    return str((cfg.get("fusion") or {}).get("sharePrefix") or SHARE_PREFIX_DEFAULT)


def ssh_config(cfg: dict) -> dict:
    ssh = (cfg.get("fusion") or {}).get("ssh") or {}
    try:
        port = int(ssh.get("port") or 22)
    except (TypeError, ValueError):
        port = 22
    return {"host": str(ssh.get("host") or "").strip(),
            "user": str(ssh.get("user") or "").strip(),
            "port": port,
            "password": str(ssh.get("password") or "")}


def ssh_target(ssh: dict) -> str:
    return f"{ssh['user']}@{ssh['host']}"


def ssh_opts(ssh: dict, batch: bool = True, keepalive: bool = False) -> list[str]:
    """探测用 batch=True（不弹密码提示，快速失败）；执行命令块时用普通模式。"""
    opts = ["-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new"]
    if batch:
        opts += ["-o", "BatchMode=yes"]
    if keepalive:
        opts += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=20"]
    if ssh.get("port") and ssh["port"] != 22:
        opts += ["-p", str(ssh["port"])]
    return opts


def classify_ssh_error(out: str) -> str:
    """把 ssh 原始输出归成技能要分流的四类原因（unreachable ≈ IP 失效）。"""
    low = out.lower()
    if "remote host identification has changed" in low or "host key verification failed" in low:
        return "host-key-changed"
    if "permission denied" in low or "no supported authentication" in low:
        return "auth-failed"
    for k in ("connection refused", "timed out", "no route to host",
              "network is unreachable", "connection reset", "connection closed"):
        if k in low:
            return "unreachable"
    return "error"


def list_worktrees(repo: Path) -> tuple[list[dict], str]:
    code, out = run(["git", "-C", str(repo), "worktree", "list", "--porcelain"])
    if code != 0:
        return [], out
    items: list[dict] = []
    cur: dict = {}
    for line in out.splitlines():
        if line.startswith("worktree "):
            if cur:
                items.append(cur)
            cur = {"path": line.split(" ", 1)[1].strip()}
        elif line.startswith("branch "):
            cur["branch"] = line.split(" ", 1)[1].strip().replace("refs/heads/", "")
        elif line.startswith("HEAD "):
            cur["head"] = line.split(" ", 1)[1].strip()[:8]
        elif line.strip() == "detached":
            cur["branch"] = "(detached)"
        elif line.strip() == "bare":
            cur["bare"] = True
    if cur:
        items.append(cur)
    return items, ""


def pick_worktree(items: list[dict], repo: Path, want: str | None) -> tuple[Path | None, str]:
    """want 可以是 worktree 名（目录名）、分支名、或绝对路径；None 取主仓库。"""
    if not items:
        return None, "没有可用 worktree"
    if not want:
        for it in items:
            if Path(it["path"]) == repo:
                return Path(it["path"]), ""
        return Path(items[0]["path"]), ""
    w = want.rstrip("/")
    if w.startswith("/"):
        cand = Path(w)
        if any(Path(it["path"]) == cand for it in items):
            return cand, ""
        return None, f"worktree 列表里没有 {cand}"
    for it in items:
        if Path(it["path"]).name == w or it.get("branch") == w:
            return Path(it["path"]), ""
    names = ", ".join(f"{Path(i['path']).name}({i.get('branch','?')})" for i in items)
    return None, f"未匹配到 worktree「{w}」。现有：{names}"


def resolve(cfg: dict, repo: Path, worktree: str | None, subdir: str | None) -> dict:
    items, err = list_worktrees(repo)
    res = {"repo": str(repo), "configSources": cfg.get("_sources") or [],
           "worktrees": items, "errors": []}
    if err:
        res["errors"].append(f"git worktree list 失败：{err}")
    wt, werr = pick_worktree(items, repo, worktree or cfg.get("defaultWorktree"))
    if werr:
        res["errors"].append(werr)
    sub = subdir or cfg.get("defaultSubdir") or "."
    sub = (cfg.get("subdirs") or {}).get(sub, sub)
    target = (wt / sub) if wt else None
    res.update({"worktreePath": str(wt) if wt else None,
                "subdir": sub,
                "targetHarmony": str(target) if target else None,
                "targetFusion": to_fusion(target, share_prefix(cfg)) if target else None,
                "openspecRoot": str(target / "openspec") if target else None})
    return res


def preflight(cfg: dict, res: dict, workflow: str | None, change: str | None = None) -> list[dict]:
    checks: list[dict] = []

    def add(ok: bool, hard: bool, name: str, detail: str) -> None:
        checks.append({"ok": ok, "hard": hard, "name": name, "detail": detail})

    repo = Path(res["repo"])
    add(repo.is_dir(), True, "仓库存在", str(repo))
    add((repo / ".git").exists() or (repo / "openspec").is_dir(), False,
        "是 git 仓库", "找到 .git 或 openspec/")

    for e in res["errors"]:
        add(False, True, "worktree 解析", e)

    wt = Path(res["worktreePath"]) if res.get("worktreePath") else None
    tgt = Path(res["targetHarmony"]) if res.get("targetHarmony") else None
    add(bool(wt and wt.is_dir()), True, "worktree 目录存在", str(wt) if wt else "(未解析出)")
    add(bool(tgt and tgt.is_dir()), True, "子目录存在", str(tgt) if tgt else "(未解析出)")

    if tgt:
        root = tgt / "openspec"
        has_root = (root / "config.yaml").is_file() or (root / "config.yml").is_file()
        add(has_root, True, "openspec 根存在",
            f"{root}/config.yaml" if has_root
            else f"{root} 下没有 openspec/config.yaml —— 不要在命令块里靠 openspec 自动建根；"
                 f"先确认子目录是否选错，或让用户显式决定是否在该子目录 openspec init")
        cmds = tgt / ".codebuddy" / "commands" / "opsx"
        if workflow:
            if not cmds.is_dir():
                add(False, True, "CodeBuddy 工具文件已装",
                    f"{tgt / '.codebuddy' / 'commands' / 'opsx'} 不存在 —— 这个目录还没用 codebuddy 工具初始化过："
                    f"先 `openspec init --tools codebuddy`（在仓库根跑），再 `openspec update`")
            else:
                wf_md = cmds / f"{workflow}.md"
                installed = sorted(p.stem for p in cmds.glob("*.md"))
                core_hint = sorted(CORE)
                add(wf_md.is_file(), True, f"工作流 {workflow} 已装",
                    str(wf_md) if wf_md.is_file()
                    else f"{wf_md} 不存在 —— `/opsx:{workflow}` 在融合侧不会被识别。已装：{installed}。"
                         f"启用办法：`openspec config profile`（把 {workflow} 纳入档位）→ `openspec update`；"
                         f"core 档只含 {core_hint}")

    ssh = ssh_config(cfg)
    ssh_ok = bool(ssh["host"] and ssh["user"])
    add(ssh_ok, True, "融合引擎 ssh 已配置",
        f"{ssh_target(ssh)}（配置来源：{', '.join(cfg.get('_sources') or []) or '无配置文件'}）"
        if ssh_ok else
        f"fusion.ssh 缺失 —— 首次访问：问用户【融合引擎 IP、登录用户名、密码】，"
        f"再跑 `python3 {SELF} ssh-set --host <IP> --user <用户名> --password-stdin` 固化"
        f"（已配置免密的机器加 --no-password）")
    add(True, False, "融合侧 CodeBuddy 入口",
        "命令块经 ssh 执行：远程 `command -v codebuddy` 检测，缺了给安装命令")

    # 变更是否真的存在——查一次，省得在融合侧才炸。
    if workflow in EXISTING_CHANGE_WORKFLOWS and change and tgt:
        cname = change.strip().strip('"').strip("'")
        live = tgt / "openspec" / "changes" / cname
        archived = tgt / "openspec" / "changes" / "archive" / cname
        if live.is_dir():
            n_tasks = [p for p in live.rglob("*.md")]
            add(True, False, f"变更 {cname} 存在",
                f"{live}（{len(n_tasks)} 个 md）")
        elif archived.is_dir():
            add(False, True, f"变更 {cname} 存在",
                f"活的变更目录没有，但 {archived} 已存在——它**已经归档过了**，"
                f"不要重复归档；要重做就新开一个变更")
        else:
            others = sorted(p.name for p in (tgt / "openspec" / "changes").iterdir()
                            ) if (tgt / "openspec" / "changes").is_dir() else []
            others = [o for o in others if o != "archive"]
            add(False, True, f"变更 {cname} 存在",
                f"{live} 不存在。现有在途变更：{others or '（一个都没有）'}。"
                f"名字打错就改名字；确实还没建就走 opsx-propose / opsx-new，"
                f"**不要**手造一个变更目录（那等于凭空生成内容再固化进主规范）")
    return checks


def build_block(cfg: dict, res: dict, workflow: str, tail: str, yolo: bool) -> str:
    title, core, hint, artifacts = WORKFLOWS[workflow]
    mode_cfg = str((cfg.get("fusion") or {}).get("permissionMode") or "acceptEdits")
    if yolo or mode_cfg == "skip":
        perm_arg = "--dangerously-skip-permissions"
        perm_note = "无人值守，工作区内不再询问"
    else:
        perm_arg = "--permission-mode acceptEdits"
        perm_note = "自动接受文件编辑，危险操作仍会拦下"
    ssh = ssh_config(cfg)

    slash = f"/opsx:{workflow}" + (f" {tail}" if tail else "")
    wt_name = Path(res["worktreePath"]).name if res.get("worktreePath") else "?"
    sub = res["subdir"]
    port_arg = f"-p {ssh['port']} " if ssh["port"] != 22 else ""

    lines: list[str] = []
    lines.append(f"# ═══ opsx:{workflow} — {title} ═══")
    lines.append(f"# 目标：worktree={wt_name}  子目录={sub}  权限：{perm_note}  融合引擎：{ssh_target(ssh)}")
    lines.append("# 经 ssh 在融合开发引擎上整段执行；技能用 Bash 工具代跑原文，不改写/不拆段/不补步骤")
    lines.append("")
    lines.append(f"ssh {port_arg}-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=20 {ssh_target(ssh)} bash -s <<'OPSX_EOF'")
    lines.append("set -euo pipefail")
    lines.append("")
    lines.append("# ① 定位目标（融合侧共享挂载路径）")
    lines.append(f"cd {res['targetFusion']}")
    lines.append("")
    lines.append("# ② 预检：确认这里就是 openspec 根，且 codebuddy 可用")
    lines.append('test -f openspec/config.yaml || { echo "✗ 此处不是 openspec 根（缺 openspec/config.yaml）: $(pwd)"; exit 1; }')
    lines.append('command -v codebuddy >/dev/null 2>&1 || { echo "✗ 融合侧没装 CodeBuddy CLI（或不在 PATH），先跑："; echo "  bash \\"$HOME/.local/opt/codebuddy-linux/install.sh\\""; exit 1; }')
    lines.append("")
    lines.append("# ③ 执行")
    lines.append(f'codebuddy -p "{slash}" {perm_arg}')
    lines.append("")
    lines.append("# 预期产物：" + artifacts)
    lines.append("OPSX_EOF")
    return "\n".join(lines)


def cmd_worktrees(args: argparse.Namespace) -> int:
    repo = Path(args.repo).expanduser()
    cfg = load_config(repo)
    items, err = list_worktrees(repo)
    if err:
        print(f"✗ {err}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"repo": str(repo), "worktrees": items}, ensure_ascii=False, indent=2))
        return 0
    print(f"仓库：{repo}")
    for it in items:
        p = Path(it["path"])
        print(f"  · {p.name:28} 分支={it.get('branch','?'):20} {p}")
        print(f"    {'':28} 融合侧={to_fusion(p, share_prefix(cfg))}")
    return 0


def cmd_target(args: argparse.Namespace) -> int:
    repo = Path(args.repo).expanduser()
    res = resolve(load_config(repo), repo, args.worktree, args.subdir)
    if args.json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
    else:
        print(f"worktree      : {res.get('worktreePath')}")
        print(f"子目录        : {res['subdir']}")
        print(f"鸿蒙侧目标    : {res.get('targetHarmony')}")
        print(f"融合侧目标    : {res.get('targetFusion')}")
        print(f"openspec 根   : {res.get('openspecRoot')}")
        for e in res["errors"]:
            print(f"  ✗ {e}", file=sys.stderr)
    return 2 if res["errors"] else 0


def cmd_preflight(args: argparse.Namespace) -> int:
    repo = Path(args.repo).expanduser()
    cfg = load_config(repo)
    res = resolve(cfg, repo, args.worktree, args.subdir)
    checks = preflight(cfg, res, args.workflow, args.change)
    hard = [c for c in checks if not c["ok"] and c["hard"]]
    soft = [c for c in checks if not c["ok"] and not c["hard"]]
    if args.json:
        print(json.dumps({"target": res, "checks": checks}, ensure_ascii=False, indent=2))
    else:
        for c in checks:
            mark = "✓" if c["ok"] else ("✗" if c["hard"] else "!")
            print(f"  {mark} {c['name']}: {c['detail']}")
        if hard:
            print(f"\n✗ {len(hard)} 项硬错误，先解决再用技能（不要靠命令块现场兜底）")
        elif soft:
            print(f"\n! {len(soft)} 项提醒（不阻塞）")
        else:
            print("\n✓ 体检通过，可以交接命令块")
    return 2 if hard else 0


def cmd_plan(args: argparse.Namespace) -> int:
    if args.workflow not in WORKFLOWS:
        print(f"✗ 未知工作流 {args.workflow}；可选：{', '.join(WORKFLOWS)}", file=sys.stderr)
        return 2
    repo = Path(args.repo).expanduser()
    cfg = load_config(repo)
    res = resolve(cfg, repo, args.worktree, args.subdir)
    checks = preflight(cfg, res, args.workflow, args.change)
    hard = [c for c in checks if not c["ok"] and c["hard"]]
    tail = args.request or args.change or ""
    tail = " ".join(str(tail).split())
    missing_change = args.workflow in REQUIRES_CHANGE and not args.change
    if (missing_change or (args.workflow in REQUIRES_TAIL and not tail and not args.allow_empty)):
        if missing_change:
            msg = (f"opsx:{args.workflow} 必须给出变更名：加 `--change \"<变更名>\"`。"
                   f"这个工作流作用在某个具体变更上，归错/校错会污染主规范，"
                   f"所以不接受「让 CodeBuddy 自己挑」。")
        else:
            ctx = "变更名" if args.workflow == "new" else "一句话需求或变更名"
            msg = (f"opsx:{args.workflow} 必须给出{ctx}：加 `--request \"…\"`（或 `--change 名`）。"
                   f"确实想自己定尾参的，加 `--allow-empty` 跳过此检查。")
        if args.json:
            print(json.dumps({"ok": False, "target": res, "checks": checks,
                              "error": msg}, ensure_ascii=False, indent=2))
        else:
            print(f"  ✗ {'变更名缺失' if missing_change else '尾参缺失'}: {msg}", file=sys.stderr)
        return 2
    if hard:
        if args.json:
            print(json.dumps({"ok": False, "checks": checks}, ensure_ascii=False, indent=2))
        else:
            for c in checks:
                if not c["ok"]:
                    print(f"  {'✗' if c['hard'] else '!'} {c['name']}: {c['detail']}", file=sys.stderr)
        return 2
    notes: list[str] = []
    if args.workflow in EXISTING_CHANGE_WORKFLOWS and not args.change:
        notes.append('没给 --change：无法预检目标变更是否存在，CodeBuddy 会自己找或问你。'
                     '补 `--change "<变更名>"` 可以提前拦下名字打错、或「其实已经归档过了」。')
    block = build_block(cfg, res, args.workflow, tail, args.yolo)
    if args.json:
        print(json.dumps({"ok": True, "target": res, "checks": checks, "notes": notes,
                          "block": block, "workflow": args.workflow,
                          "core": args.workflow in CORE}, ensure_ascii=False, indent=2))
    else:
        for n in notes:
            print(f"  ! {n}", file=sys.stderr)
        print(block)
    return 0


def cmd_ssh_check(args: argparse.Namespace) -> int:
    repo = Path(args.repo).expanduser()
    cfg = load_config(repo)
    ssh = ssh_config(cfg)
    sources = cfg.get("_sources") or []
    if not ssh["host"] or not ssh["user"]:
        detail = ("配置里没有 fusion.ssh.host/user —— 首次访问：问用户【融合引擎 IP、登录用户名、密码】，"
                  f"再跑 `python3 {SELF} ssh-set --host <IP> --user <用户名> --password-stdin` 固化")
        if args.json:
            print(json.dumps({"status": "no-config", "configSources": sources, "detail": detail},
                             ensure_ascii=False, indent=2))
        else:
            print(f"✗ 配置缺失：{detail}", file=sys.stderr)
        return 2

    code, out = run(["ssh", *ssh_opts(ssh), ssh_target(ssh), "echo opsx-ssh-ok"],
                    cwd=HOME, timeout=25)
    if code == 0 and "opsx-ssh-ok" in out:
        detail = f"免密（key 认证）可用；配置来源：{', '.join(sources) or '无配置文件'}"
        if args.json:
            print(json.dumps({"status": "ok", "target": ssh_target(ssh), "port": ssh["port"],
                              "configSources": sources, "detail": detail},
                             ensure_ascii=False, indent=2))
        else:
            print(f"✓ ssh 可达：{ssh_target(ssh)}:{ssh['port']}（{detail}）")
        return 0

    reason = classify_ssh_error(out)
    hints = {
        "unreachable": "IP 可能已失效（换了/关机/网段变了）——重新询问用户 IP、用户名、密码，"
                       f"再用 `python3 {SELF} ssh-set ...` 更新配置",
        "auth-failed": f"免密没配好——若配置里存了密码，先跑 `python3 {SELF} ssh-push-key` 自动推公钥；"
                       "否则重新询问用户凭据",
        "host-key-changed": "主机指纹变了（融合引擎重装/换机）——确认无误后清理旧指纹："
                            "`ssh-keygen -R <host>`，再重跑本命令",
        "error": "看下面的原始输出定位",
    }
    if args.json:
        print(json.dumps({"status": "failed", "reason": reason, "target": ssh_target(ssh),
                          "configSources": sources, "detail": out[-2000:],
                          "hint": hints.get(reason, hints["error"])}, ensure_ascii=False, indent=2))
    else:
        print(f"✗ ssh 不可达 [{reason}]：{ssh_target(ssh)}\n  {hints.get(reason, hints['error'])}\n"
              f"--- ssh 输出 ---\n{out}", file=sys.stderr)
    return 3


def cmd_ssh_set(args: argparse.Namespace) -> int:
    host = (args.host or "").strip()
    user = (args.user or "").strip()
    if not host or not user:
        print("✗ --host 与 --user 都必填", file=sys.stderr)
        return 2
    port = int(args.port or 22)
    password = None  # None = 不动现有值
    if args.password_stdin:
        password = sys.stdin.readline().rstrip("\r\n")
    if args.no_password:
        password = ""

    path = CONFIG_USER
    data: dict = {}
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"✗ {path} 已存在但解析失败（不覆盖）：{exc}", file=sys.stderr)
            return 1
        if not isinstance(data, dict):
            print(f"✗ {path} 不是 JSON 对象（不覆盖）", file=sys.stderr)
            return 1
    fusion = data.get("fusion")
    if not isinstance(fusion, dict):
        fusion = {}
        data["fusion"] = fusion
    ssh = fusion.get("ssh")
    if not isinstance(ssh, dict):
        ssh = {}
        fusion["ssh"] = ssh
    ssh["host"] = host
    ssh["user"] = user
    ssh["port"] = port
    if password is not None:
        if password:
            ssh["password"] = password
        else:
            ssh.pop("password", None)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
    has_pw = "有（仅用于配免密）" if ssh.get("password") else "无（免密/未存）"
    print(f"✓ 已固化到 {path}")
    print(f"  host={host}  user={user}  port={port}  password={has_pw}")
    print(f"  下一步：python3 {SELF} ssh-check 验证连接")
    return 0


def cmd_ssh_push_key(args: argparse.Namespace) -> int:
    repo = Path(args.repo).expanduser()
    ssh = ssh_config(load_config(repo))
    if not ssh["host"] or not ssh["user"]:
        print(f"✗ 配置缺失：先 ssh-set 固化 host/user（指引见 python3 {SELF} ssh-check）",
              file=sys.stderr)
        return 2
    if not ssh["password"]:
        print("✗ 配置里没有密码，无法自动推送公钥。两条路：\n"
              f"  ① 重新询问用户密码后：python3 {SELF} ssh-set --password-stdin\n"
              "  ② 让用户手动把本机公钥追加到融合引擎的 ~/.ssh/authorized_keys，再 ssh-check 验证",
              file=sys.stderr)
        return 2

    key = HOME / SSH_KEY_REL
    pub = Path(str(key) + ".pub")
    if not pub.is_file():
        code, out = run(["ssh-keygen", "-t", "ed25519", "-N", "", "-q", "-f", str(key)],
                        cwd=HOME, timeout=20)
        if code != 0 or not pub.is_file():
            print(f"✗ ssh-keygen 生成本地密钥失败：\n{out}", file=sys.stderr)
            return 1
        print(f"（本机原本没有 ssh 密钥，已生成 {key}）")
    try:
        pub_text = pub.read_text(encoding="utf-8").strip()
    except OSError as exc:
        print(f"✗ 读取公钥失败：{exc}", file=sys.stderr)
        return 1

    # 密码经 SSH_ASKPASS 临时脚本喂给 ssh（不落 argv）；用完立即删除
    try:
        fd, ask_path = tempfile.mkstemp(prefix="opsx-askpass-", suffix=".sh")
    except OSError as exc:
        print(f"✗ 无法创建临时 askpass 脚本：{exc}", file=sys.stderr)
        return 1
    code, out = 1, "askpass 脚本准备失败"
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nprintf '%s\\n' '"
                    + ssh["password"].replace("'", "'\\''") + "'\n")
        os.chmod(ask_path, 0o700)
        remote = (
            'mkdir -p ~/.ssh && chmod 700 ~/.ssh && '
            'while IFS= read -r line; do '
            '[ -n "$line" ] || continue; '
            'grep -qxF "$line" ~/.ssh/authorized_keys 2>/dev/null '
            "|| printf '%s\\n' \"$line\" >> ~/.ssh/authorized_keys; "
            'done; chmod 600 ~/.ssh/authorized_keys'
        )
        code, out = run(["ssh", "-o", "NumberOfPasswordPrompts=1",
                         *ssh_opts(ssh, batch=False), ssh_target(ssh), remote],
                        cwd=HOME, input_text=pub_text + "\n",
                        env_extra={"SSH_ASKPASS": ask_path, "SSH_ASKPASS_REQUIRE": "force"},
                        timeout=40)
    except OSError as exc:
        out = f"{type(exc).__name__}: {exc}"
    finally:
        try:
            os.unlink(ask_path)
        except OSError:
            pass
    if code != 0:
        print(f"✗ 推送公钥失败 [{classify_ssh_error(out)}]：\n{out}", file=sys.stderr)
        return 3
    print(f"✓ 公钥已（幂等）推送到 {ssh_target(ssh)} 的 ~/.ssh/authorized_keys")
    print(f"  下一步：python3 {SELF} ssh-check 验证免密")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="为 /opsx:* 工作流生成经 ssh 在融合开发引擎上执行的命令块")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--repo", default=str(DEFAULT_REPO), help="fountain 仓库路径")
        p.add_argument("--worktree", help="worktree 名 / 分支名 / 绝对路径")

    p = sub.add_parser("worktrees", help="列出现有 worktree")
    common(p)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_worktrees)

    p = sub.add_parser("target", help="解析目标三元组")
    common(p)
    p.add_argument("--subdir", help="子目录（相对 worktree）")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_target)

    p = sub.add_parser("preflight", help="鸿蒙侧只读体检")
    common(p)
    p.add_argument("--subdir")
    p.add_argument("--workflow", choices=sorted(WORKFLOWS))
    p.add_argument("--change", help="变更名（给了就查它是否存在）")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_preflight)

    p = sub.add_parser("plan", help="生成命令块正文")
    common(p)
    p.add_argument("--subdir")
    p.add_argument("--workflow", required=True, choices=sorted(WORKFLOWS))
    p.add_argument("--request", help="斜杠命令尾参：变更名或一句话需求")
    p.add_argument("--change", help="斜杠命令尾参：变更名（与 --request 同义）")
    p.add_argument("--yolo", action="store_true", help="改用 --dangerously-skip-permissions")
    p.add_argument("--allow-empty", action="store_true",
                   help="跳过「propose/new 必须有主题」的检查（你自己定尾参时用）")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("ssh-check", help="探测融合引擎 ssh 可达性（0 可达 / 2 配置缺失 / 3 失败）")
    common(p)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_ssh_check)

    p = sub.add_parser("ssh-set", help="固化连接信息到用户级配置的 fusion.ssh 段")
    p.add_argument("--host", required=True)
    p.add_argument("--user", required=True)
    p.add_argument("--port", type=int, help="缺省 22")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--password-stdin", action="store_true", help="从 stdin 读一行作为密码")
    g.add_argument("--no-password", action="store_true", help="清空已存密码（已配置免密时）")
    p.set_defaults(func=cmd_ssh_set)

    p = sub.add_parser("ssh-push-key", help="用密码推送公钥，一次配好免密登录")
    common(p)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_ssh_push_key)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
