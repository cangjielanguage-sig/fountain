#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fountain-publish 的发布驱动（技能随包脚本，只用 Python 3 标准库）。

固定流水线：
    1. 判定执行环境
       - Windows            -> WSL Ubuntu-24.04
       - 鸿蒙 PC 本机        -> 融合开发引擎（ssh，--remote）
       - 融合开发引擎里      -> 本机
       - 其他物理机          -> 本机
    2. 以 fboot 模块目录为工作目录安装 fboot
       - WSL                -> cjpm install --root /mnt/d/docs/work/cangjie/installed
       - 鸿蒙 / 融合引擎     -> cjpm install
    3. 在 fountain 仓库根执行 fboot pub <a.b.c> --skip-test --skip-lint，
       逐行读输出；出现限流信息立即终止整个进程树，记录恢复时刻（+24h）并结束。

子命令：
    detect    只读：打印环境判定与将要执行的两条命令（不安装、不发布）
    run       执行完整流水线
    selftest  限流判定自检（无副作用）

退出码：
    0   发布完成
    2   环境 / 参数错误
    3   限流已停止（限流后未满 24 小时重跑也返回 3，且不执行任何命令）
    4   cjpm install 或 fboot pub 失败（非限流）
    130 用户中断
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from datetime import datetime, timedelta
from pathlib import Path
from queue import Empty, Queue

EXIT_OK = 0
EXIT_ENV = 2
EXIT_RATE_LIMIT = 3
EXIT_FAILED = 4
EXIT_INTERRUPTED = 130

SCRIPT = Path(__file__).resolve()
REPO_LAYOUT = ("cjpm.toml", ".modules", "f_version")

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")

DEFAULT_WSL_DISTRO = "Ubuntu-24.04"
DEFAULT_WSL_CANGJIE_SH = "/mnt/d/docs/work/cangjie/cangjie.sh"
DEFAULT_WSL_INSTALL_ROOT = "/mnt/d/docs/work/cangjie/installed"
DEFAULT_FUSION_REPO = (
    "/mnt/linux_share/storage/Users/currentUser/Documents/cangjie/projects/fountain"
)
RATE_LIMIT_BACKOFF = timedelta(hours=24)

# 限流判定。发布日志里出现任意一条即视为限流，立即停止。
# 新增文案只改这里；临时补充用 --rate-limit-pattern 传正则。
RATE_LIMIT_PATTERNS = (
    r"限流",
    r"频率(?:过高|超限|限制)",
    r"频繁",
    r"rate[\s_-]*limit",
    r"too[\s_-]*many[\s_-]*requests",
    r"\b429\b",
    r"(?:请)?稍后(?:再)?(?:试|重试)",
    r"try\s+again\s+later",
)


def die(message, code=EXIT_ENV):
    print("错误：%s" % message, file=sys.stderr)
    sys.exit(code)


def now_local():
    return datetime.now().astimezone()


def parse_dt(text):
    if not text:
        return None
    try:
        value = datetime.fromisoformat(text)
    except (TypeError, ValueError):
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=now_local().tzinfo)
    return value


def fmt_delta(delta):
    total = int(max(0, delta.total_seconds()))
    hours, rest = divmod(total, 3600)
    minutes, seconds = divmod(rest, 60)
    return "%dh%02dm%02ds" % (hours, minutes, seconds)


# ---------------------------------------------------------------------------
# 仓库、状态目录、执行环境
# ---------------------------------------------------------------------------


def looks_like_repo(path):
    return all((path / name).exists() for name in REPO_LAYOUT)


def resolve_repo(argument):
    candidates = []
    if argument:
        candidates.append(Path(argument).expanduser())
    env_repo = os.environ.get("FU_PUBLISH_REPO")
    if env_repo:
        candidates.append(Path(env_repo).expanduser())
    # skills/fountain-publish/scripts/publish.py -> 仓库根
    candidates.append(SCRIPT.parents[3])
    try:
        candidates.append(Path.cwd())
    except OSError:
        pass
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if looks_like_repo(resolved):
            return resolved
    die(
        "定位不到 fountain 仓库根（需要同时有 cjpm.toml、.modules、f_version/）。"
        "请在仓库根执行，或用 --repo / FU_PUBLISH_REPO 指定。"
    )


def git_dir(repo):
    try:
        done = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--absolute-git-dir"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if done.returncode == 0 and done.stdout.strip():
            candidate = Path(done.stdout.strip())
            if candidate.is_dir():
                return candidate
    except (OSError, subprocess.SubprocessError):
        pass
    dot_git = repo / ".git"
    if dot_git.is_dir():
        return dot_git
    if dot_git.is_file():
        try:
            text = dot_git.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            return None
        if text.startswith("gitdir:"):
            candidate = Path(text[len("gitdir:") :].strip())
            if not candidate.is_absolute():
                candidate = (repo / candidate).resolve()
            if candidate.is_dir():
                return candidate
    return None


def state_dir(repo, create=True):
    base = git_dir(repo)
    if base is None:
        # 没有可用 .git（worktree 的 gitdir 在另一侧等）：用家目录而不是临时目录，
        # 避免 /tmp / %TEMP% 被清理后冷却状态消失；按仓库路径分桶避免串味。
        digest = hashlib.sha1(str(repo).encode("utf-8")).hexdigest()[:12]
        directory = Path.home() / ".fountain-publish" / digest
    else:
        directory = base / "fountain-publish"
    if create:
        directory.mkdir(parents=True, exist_ok=True)
    return directory


def is_harmony_host():
    if Path("/system/bin/param").exists():
        return True
    try:
        release = Path("/etc/os-release").read_text(encoding="utf-8", errors="replace").lower()
        if "openharmony" in release or "harmony" in release:
            return True
    except OSError:
        pass
    uname = platform.uname()
    return "ohos" in (uname.release + " " + uname.version).lower()


def is_wsl():
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        version = Path("/proc/version").read_text(encoding="utf-8", errors="replace").lower()
        return "microsoft" in version or "wsl" in version
    except OSError:
        return False


def detect_mode(forced):
    if forced and forced != "auto":
        return forced
    if os.name == "nt" or sys.platform.startswith("win"):
        return "windows"
    if is_wsl():
        return "wsl"
    # 鸿蒙本机优先于 fusion：本机即使挂了 /mnt/linux_share，也不能在本机跑发布。
    if is_harmony_host():
        return "harmony"
    if Path("/mnt/linux_share").exists():
        return "fusion"
    return "native"


def win_to_wsl(path):
    text = str(path).replace("\\", "/")
    match = re.match(r"^([A-Za-z]):/(.*)$", text)
    if match:
        return "/mnt/" + match.group(1).lower() + "/" + match.group(2)
    return text


def resolve_wsl_distro(args):
    return args.wsl_distro or os.environ.get("FU_PUBLISH_WSL_DISTRO") or DEFAULT_WSL_DISTRO


def resolve_install_root(args, mode):
    if args.install_root:
        return args.install_root
    if mode in ("windows", "wsl"):
        return DEFAULT_WSL_INSTALL_ROOT
    return None


def resolve_remote(args):
    return args.remote or os.environ.get("FU_PUBLISH_REMOTE")


def resolve_cangjie_sh(args, mode, repo):
    if args.cangjie_sh:
        return args.cangjie_sh
    if mode == "wsl":
        return DEFAULT_WSL_CANGJIE_SH
    if mode == "fusion":
        local = repo / "cangjie.sh"
        if local.is_file():
            return str(local)
    return None


# ---------------------------------------------------------------------------
# 状态（限流后的 24 小时冷却）
# ---------------------------------------------------------------------------


def load_state(directory):
    path = directory / "state.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        # 读不出冷却时刻就不能默认放行——那等于静默跳过 24 小时限制。
        die(
            "限流状态文件损坏或不可读：%s（%s）。"
            "请确认上次限流时刻（距现在是否满 24 小时）后删除该文件再重试。" % (path, error),
            EXIT_ENV,
        )


def save_state(directory, version, hit, log_path):
    moment = now_local()
    state = {
        "version": version,
        "rate_limited_at": moment.isoformat(timespec="seconds"),
        "resume_after": (moment + RATE_LIMIT_BACKOFF).isoformat(timespec="seconds"),
        "trigger": hit["pattern"],
        "line": hit["line"].strip(),
        "log": str(log_path),
    }
    path = directory / "state.json"
    temporary = directory / "state.json.tmp"
    temporary.write_text(
        json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)
    return state


def clear_state(directory):
    try:
        (directory / "state.json").unlink()
    except OSError:
        pass


def print_rate_limit_state(state):
    print("[RATE-LIMIT] 版本     : %s" % state.get("version", "?"))
    print("[RATE-LIMIT] 触发规则 : %s" % state.get("trigger", "?"))
    print("[RATE-LIMIT] 命中行   : %s" % state.get("line", "?"))
    print("[RATE-LIMIT] 限流时刻 : %s" % state.get("rate_limited_at", "?"))
    print("[RATE-LIMIT] 恢复时刻 : %s（限流后 24 小时）" % state.get("resume_after", "?"))
    print("[RATE-LIMIT] 当次日志 : %s" % state.get("log", "?"))


def gate_check(directory, force):
    state = load_state(directory)
    if state is None:
        return None
    resume = parse_dt(state.get("resume_after"))
    if resume is None or now_local() >= resume:
        clear_state(directory)
        return None
    if force:
        print("[RATE-LIMIT] --force：跳过 24 小时冷却（仅用户明确要求时使用）。")
        return None
    return state


def wait_until(resume):
    while True:
        remaining = resume - now_local()
        if remaining.total_seconds() <= 0:
            return
        print(
            "[WAIT] 距限流恢复还有 %s（恢复时刻 %s），本轮继续等待。"
            % (fmt_delta(remaining), resume.isoformat(timespec="seconds"))
        )
        time.sleep(min(300, max(1, remaining.total_seconds())))


# ---------------------------------------------------------------------------
# 限流判定
# ---------------------------------------------------------------------------


def compile_patterns(extra):
    patterns = list(RATE_LIMIT_PATTERNS) + list(extra or [])
    compiled = []
    for pattern in patterns:
        try:
            compiled.append(re.compile(pattern, re.IGNORECASE))
        except re.error as error:
            die("--rate-limit-pattern 不是合法正则 %r：%s" % (pattern, error))
    return compiled


def match_rate_limit(line, patterns):
    for pattern in patterns:
        if pattern.search(line):
            return pattern.pattern
    return None


# ---------------------------------------------------------------------------
# 子进程执行
# ---------------------------------------------------------------------------


def terminate_tree(process):
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(process.pid)],
            capture_output=True,
        )
        if process.poll() is None:
            try:
                process.kill()
            except OSError:
                pass
        return
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGTERM)
    except OSError:
        try:
            process.kill()
        except OSError:
            pass
        return
    deadline = time.time() + 10
    while process.poll() is None and time.time() < deadline:
        time.sleep(0.2)
    if process.poll() is None:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        except OSError:
            pass
        if process.poll() is None:
            try:
                process.kill()
            except OSError:
                pass


def stream_command(command, cwd, env, log_path, phase, patterns, heartbeat_sec, watch=True):
    """运行命令并逐行落日志 / 打屏；命中限流时终止整个进程树。"""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = open(log_path, "a", encoding="utf-8", errors="replace", buffering=1)
    started = time.time()

    def emit(text):
        log.write(text)
        log.flush()
        sys.stdout.write(text)
        sys.stdout.flush()

    emit(
        "\n===== %s | %s =====\n"
        % (phase, datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    )
    emit("[CMD] %s\n" % " ".join(command))

    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        kwargs["start_new_session"] = True

    process = subprocess.Popen(
        command,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
        **kwargs,
    )

    queue = Queue()

    def reader():
        try:
            for line in process.stdout:
                queue.put(line)
        finally:
            queue.put(None)

    threading.Thread(target=reader, daemon=True).start()

    stats = {"current": "", "modules": set(), "success": 0, "failures": 0}
    tail = deque(maxlen=20)
    hit = None
    last_beat = time.time()
    try:
        while True:
            try:
                line = queue.get(timeout=1.0)
            except Empty:
                line = ""
            if line is None:
                break
            if line:
                text = line.rstrip("\r\n")
                emit(line if line.endswith("\n") else line + "\n")
                tail.append(text)

                found = re.search(r"publishing\s+(\S+)::(\S+)\s+\.\.\.", text)
                if found:
                    stats["current"] = found.group(2)
                found = re.search(r"checking published\s+(\S+)::(\S+)", text)
                if found:
                    stats["current"] = found.group(2)
                    stats["modules"].add(found.group(2))
                if "cjpm publish success" in text:
                    stats["success"] += 1
                if "to publish" in text and "failed" in text:
                    stats["failures"] += 1
                if "Exception" in text:
                    stats["failures"] += 1

                if watch and patterns:
                    pattern = match_rate_limit(text, patterns)
                    if pattern:
                        hit = {
                            "pattern": pattern,
                            "line": text,
                            "context": list(tail),
                        }
                        break

            if heartbeat_sec > 0 and time.time() - last_beat >= heartbeat_sec:
                last_beat = time.time()
                emit(
                    "[STATUS] phase=%s current=%s modules=%d failures=%d elapsed=%s\n"
                    % (
                        phase,
                        stats["current"] or "-",
                        len(stats["modules"]),
                        stats["failures"],
                        fmt_delta(timedelta(seconds=time.time() - started)),
                    )
                )
    except KeyboardInterrupt:
        terminate_tree(process)
        log.close()
        raise

    if hit is not None:
        terminate_tree(process)
        emit("[RATE-LIMIT] 命中规则 %r\n" % hit["pattern"])
        emit("[RATE-LIMIT] 命中行：%s\n" % hit["line"])
        emit("[RATE-LIMIT] 最近上下文：\n")
        for item in hit["context"]:
            emit("    %s\n" % item)

    try:
        code = process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        terminate_tree(process)
        try:
            code = process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except OSError:
                pass
            try:
                code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                emit("[WARN] 子进程未能回收（可能残留），继续退出。\n")
                code = -1

    elapsed = timedelta(seconds=time.time() - started)
    emit("===== %s 结束：exit=%s elapsed=%s =====\n" % (phase, code, fmt_delta(elapsed)))
    log.close()
    return {
        "code": code,
        "hit": hit,
        "stats": stats,
        "elapsed": elapsed,
    }


def command_env(install_root):
    env = os.environ.copy()
    if install_root:
        root = str(install_root)
        env["PATH"] = root + "/bin" + (os.pathsep + env["PATH"] if env.get("PATH") else "")
        library = root + "/libs/fboot"
        env["LD_LIBRARY_PATH"] = library + (
            os.pathsep + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else ""
        )
        env["CANGJIE_FOUNTAIN_LIBS"] = library
    return env


def find_fboot(install_root, env):
    if install_root:
        candidate = Path(install_root) / "bin" / "fboot"
        if candidate.is_file():
            return str(candidate)
    located = shutil.which("fboot", path=env.get("PATH"))
    if located:
        return located
    candidate = Path.home() / ".cjpm" / "bin" / "fboot"
    if candidate.is_file():
        return str(candidate)
    return None


# ---------------------------------------------------------------------------
# 转发：Windows -> WSL
# ---------------------------------------------------------------------------


def forward_windows(args, repo, version, log_path):
    wsl = shutil.which("wsl.exe") or shutil.which("wsl")
    if not wsl:
        die(
            "当前是 Windows，但没有找到 wsl.exe。先安装并初始化 Ubuntu-24.04"
            "（wsl --install -d Ubuntu-24.04），或用 --env 指定实际执行环境。"
        )

    install_root = resolve_install_root(args, "windows")
    if re.match(r"^[A-Za-z]:[\\/]", str(install_root)):
        install_root = win_to_wsl(install_root)
    cangjie_sh = args.cangjie_sh or DEFAULT_WSL_CANGJIE_SH
    if re.match(r"^[A-Za-z]:[\\/]", str(cangjie_sh)):
        cangjie_sh = win_to_wsl(cangjie_sh)

    inner = [
        "python3",
        win_to_wsl(SCRIPT),
        "run",
        "--version",
        version,
        "--env",
        "native",
        "--repo",
        win_to_wsl(repo),
        "--install-root",
        install_root,
        "--heartbeat",
        str(args.heartbeat),
    ]
    if args.skip_install:
        inner.append("--skip-install")
    if args.force:
        inner.append("--force")
    if args.wait:
        inner.append("--wait")
    for pattern in args.rate_limit_pattern:
        inner.extend(["--rate-limit-pattern", pattern])

    bash_script = "source %s >/dev/null 2>&1; exec %s" % (
        shlex.quote(cangjie_sh),
        " ".join(shlex.quote(item) for item in inner),
    )
    command = [wsl, "-d", resolve_wsl_distro(args), "--", "bash", "-lc", bash_script]

    print("[ENV] mode=windows executor=WSL %s" % resolve_wsl_distro(args))
    print("[ENV] 内层命令：source %s && cd %s && fboot pub %s --skip-test --skip-lint"
          % (cangjie_sh, win_to_wsl(repo), version))

    result = stream_command(
        command,
        None,
        os.environ.copy(),
        log_path,
        "windows->wsl",
        [],
        args.heartbeat,
        watch=False,
    )
    if result["code"] == EXIT_RATE_LIMIT:
        print("[RATE-LIMIT] WSL 内层返回 3：可能命中限流，也可能仍在 24 小时冷却期；看内层输出与 state.json。")
    elif result["code"] not in (EXIT_OK, EXIT_FAILED):
        print(
            "[FAIL] WSL 转发失败（exit=%s）：检查发行版名、仓颉环境脚本、内层 python3 与技能文件；"
            "发布通常还没开始。" % result["code"]
        )
    return result["code"]


# ---------------------------------------------------------------------------
# 转发：鸿蒙 PC -> 融合开发引擎（ssh）
# ---------------------------------------------------------------------------


def forward_harmony(args, repo, version, log_path):
    remote = resolve_remote(args)
    if not remote:
        die(
            "当前是鸿蒙 PC 本机，发布应在融合开发引擎执行。"
            "给 --remote user@host（融合引擎 ssh，需已配置免密）或设置 FU_PUBLISH_REMOTE 后重跑；"
            "也可以直接在融合开发引擎里运行本技能（会自动走 fusion 分支）。"
        )
    remote_repo = args.remote_repo or DEFAULT_FUSION_REPO
    remote_script = remote_repo + "/skills/fountain-publish/scripts/publish.py"

    inner = [
        "python3",
        remote_script,
        "run",
        "--version",
        version,
        "--env",
        "native",
        "--repo",
        remote_repo,
        "--heartbeat",
        str(args.heartbeat),
    ]
    if args.skip_install:
        inner.append("--skip-install")
    if args.force:
        inner.append("--force")
    if args.wait:
        inner.append("--wait")
    for pattern in args.rate_limit_pattern:
        inner.extend(["--rate-limit-pattern", pattern])

    bash_script = "cd %s && source ./cangjie.sh >/dev/null 2>&1; exec %s" % (
        shlex.quote(remote_repo),
        " ".join(shlex.quote(item) for item in inner),
    )
    command = ["ssh", "-o", "BatchMode=yes", remote, "bash -lc " + shlex.quote(bash_script)]

    print("[ENV] mode=harmony executor=融合开发引擎 ssh=%s" % remote)
    print("[ENV] 远端仓库：%s" % remote_repo)

    result = stream_command(
        command,
        None,
        os.environ.copy(),
        log_path,
        "harmony->fusion-ssh",
        [],
        args.heartbeat,
        watch=False,
    )
    if result["code"] == EXIT_RATE_LIMIT:
        print("[RATE-LIMIT] 融合引擎侧返回 3：可能命中限流，也可能仍在 24 小时冷却期；看远端 state.json。")
    elif result["code"] not in (EXIT_OK, EXIT_FAILED):
        print(
            "[FAIL] 融合引擎转发失败（exit=%s）：检查 ssh 免密、--remote-repo、远端 python3 与技能文件；"
            "发布通常还没开始。" % result["code"]
        )
    return result["code"]


# ---------------------------------------------------------------------------
# 本机执行（native / fusion）
# ---------------------------------------------------------------------------


def reexec_with_source(cangjie_sh):
    argv = [sys.executable, str(SCRIPT)] + sys.argv[1:]
    script = "source %s >/dev/null 2>&1; export FU_PUBLISH_SOURCED=1; exec %s" % (
        shlex.quote(cangjie_sh),
        " ".join(shlex.quote(item) for item in argv),
    )
    try:
        os.execvp("bash", ["bash", "-lc", script])
    except OSError as error:
        die("用 bash 加载仓颉环境失败：%s" % error)
    return EXIT_ENV


def run_local(args, repo, mode, version, log_path):
    if os.name == "nt" and mode in ("wsl", "fusion"):
        die(
            "Windows 上不能用 --env %s 本机执行（该分支使用 Linux 路径与 cjpm）。"
            "用 --env windows 转发到 WSL，或 --env native 显式使用 Windows 本机工具链。" % mode
        )
    directory = state_dir(repo)
    patterns = compile_patterns(args.rate_limit_pattern)

    state = gate_check(directory, args.force)
    if state is not None:
        print_rate_limit_state(state)
        resume = parse_dt(state.get("resume_after"))
        remaining = resume - now_local() if resume else timedelta(0)
        print(
            "[RATE-LIMIT] 距恢复还有 %s；未满 24 小时不重跑。"
            "（--force 仅在用户明确要求时使用）" % fmt_delta(remaining)
        )
        return EXIT_RATE_LIMIT

    cangjie_sh = resolve_cangjie_sh(args, mode, repo)
    if (
        cangjie_sh
        and os.name != "nt"
        and os.environ.get("FU_PUBLISH_SOURCED") != "1"
    ):
        return reexec_with_source(cangjie_sh)

    if not args.skip_install and shutil.which("cjpm") is None:
        die(
            "找不到 cjpm。先在当前 shell source 仓颉环境脚本"
            "（WSL: %s；融合引擎: 仓库根 cangjie.sh），或用 --cangjie-sh 指定。"
            % DEFAULT_WSL_CANGJIE_SH
        )

    install_root = resolve_install_root(args, mode)
    env = command_env(install_root)
    fboot_dir = repo / "fboot"
    if not (fboot_dir / "cjpm.toml").is_file():
        die("找不到 fboot 模块：%s/cjpm.toml" % fboot_dir)

    install_command = ["cjpm", "install"]
    if install_root:
        install_command.extend(["--root", install_root])

    while True:
        if not args.skip_install:
            # 限流监控只覆盖 fboot pub：install 阶段的「请稍后重试」可能只是依赖下载的
            # 瞬时提示，按非零退出码处理即可，避免误冻结 24 小时。
            result = stream_command(
                install_command,
                fboot_dir,
                env,
                log_path,
                "install",
                [],
                args.heartbeat,
            )
            if result["code"] != 0:
                print("[FAIL] cjpm install 退出码 %s（日志：%s）" % (result["code"], log_path))
                return EXIT_FAILED

        fboot = find_fboot(install_root, env)
        if not fboot:
            die(
                "安装后仍找不到 fboot。检查 --install-root（当前 %s）下的 bin/fboot，"
                "或确认 PATH 里有 fboot。" % install_root
            )

        publish_command = [fboot, "pub", version, "--skip-test", "--skip-lint"]
        result = stream_command(
            publish_command,
            repo,
            env,
            log_path,
            "publish",
            patterns,
            args.heartbeat,
        )
        if result["hit"]:
            state = save_state(directory, version, result["hit"], log_path)
            print_rate_limit_state(state)
            if args.wait:
                wait_until(parse_dt(state["resume_after"]))
                clear_state(directory)
                continue
            print("[RATE-LIMIT] 本次执行已结束；%s 之后再重跑同一命令。" % state["resume_after"])
            return EXIT_RATE_LIMIT

        clear_state(directory)
        stats = result["stats"]
        print(
            "[SUMMARY] exit=%s elapsed=%s modules=%d publish_success_lines=%d failures=%d log=%s"
            % (
                result["code"],
                fmt_delta(result["elapsed"]),
                len(stats["modules"]),
                stats["success"],
                stats["failures"],
                log_path,
            )
        )
        if result["code"] != 0:
            print("[FAIL] fboot pub 退出码 %s" % result["code"])
            return EXIT_FAILED
        return EXIT_OK


def run_pipeline(args):
    repo = resolve_repo(args.repo)
    version = args.version
    if not VERSION_RE.match(version or ""):
        die("版本号必须是 a.b.c 三段数字，收到：%r" % version)

    mode = detect_mode(args.env)
    directory = state_dir(repo)
    log_path = directory / (
        "publish-%s-%s.log" % (version, datetime.now().strftime("%Y%m%d-%H%M%S"))
    )

    print("[ENV] mode=%s repo=%s" % (mode, repo))
    print("[LOG] %s" % log_path)

    try:
        if mode == "windows":
            return forward_windows(args, repo, version, log_path)
        if mode == "harmony":
            return forward_harmony(args, repo, version, log_path)
        return run_local(args, repo, mode, version, log_path)
    except KeyboardInterrupt:
        print("\n[INTERRUPTED] 已中断（日志：%s）" % log_path)
        return EXIT_INTERRUPTED


# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------


def plan_for(mode, repo, args):
    install_root = resolve_install_root(args, mode)
    remote = resolve_remote(args)

    if mode in ("windows", "wsl"):
        if mode == "windows":
            executor = "WSL %s（经 wsl.exe 转发）" % resolve_wsl_distro(args)
            wsl_repo = win_to_wsl(repo)
        else:
            executor = "WSL（当前 shell）"
            wsl_repo = win_to_wsl(repo) if os.name == "nt" else str(repo)
        install = "cd %s/fboot && cjpm install --root %s" % (wsl_repo, install_root)
        publish = "cd %s && fboot pub <a.b.c> --skip-test --skip-lint" % wsl_repo
    elif mode == "harmony":
        remote_repo = args.remote_repo or DEFAULT_FUSION_REPO
        executor = "融合开发引擎（ssh %s）" % remote if remote else "融合开发引擎（缺少 --remote）"
        install = "cd %s/fboot && cjpm install" % remote_repo
        publish = "cd %s && fboot pub <a.b.c> --skip-test --skip-lint" % remote_repo
    elif mode == "fusion":
        executor = "融合开发引擎（本机）"
        install = "cd %s/fboot && cjpm install" % repo
        publish = "cd %s && fboot pub <a.b.c> --skip-test --skip-lint" % repo
    else:
        executor = "物理机（本机）"
        install = "cd %s/fboot && cjpm install" % repo
        if install_root:
            install += " --root %s" % install_root
        publish = "cd %s && fboot pub <a.b.c> --skip-test --skip-lint" % repo

    return {
        "mode": mode,
        "executor": executor,
        "repo": str(repo),
        "install_root": install_root or "",
        "install": install,
        "publish": publish,
        "state": str(state_dir(repo, create=False) / "state.json"),
    }


def cmd_detect(args):
    repo = resolve_repo(args.repo)
    mode = detect_mode(args.env)
    info = plan_for(mode, repo, args)
    if args.json:
        print(json.dumps(info, ensure_ascii=False, indent=2))
        return EXIT_OK
    print("fountain-publish 环境判定")
    print("  mode     : %s" % info["mode"])
    print("  executor : %s" % info["executor"])
    print("  repo     : %s" % info["repo"])
    print("  install  : %s" % info["install"])
    print("  publish  : %s" % info["publish"])
    print("  state    : %s" % info["state"])
    return EXIT_OK


# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------


def selftest():
    patterns = compile_patterns([])
    cases = (
        ("publish failed: rate limit exceeded, try again later", True),
        ("HTTP 429 Too Many Requests", True),
        ("发布过于频繁，请稍后再试", True),
        ("系统检测到限流，请 24 小时后重试", True),
        ("TooManyRequests: request was throttled", True),
        ("cjpm publish success", False),
        ("Error: output-type ... must be 'executable' for cjpm install", False),
        ("error: cannot open shared object file: libf_pool.so", False),
        ("quota: 10 packages per day", False),
    )
    failures = 0
    for line, expected in cases:
        actual = match_rate_limit(line, patterns) is not None
        status = "OK" if actual == expected else "FAIL"
        if actual != expected:
            failures += 1
        print("[%s] expected=%s actual=%s | %s" % (status, expected, actual, line))

    state = {
        "rate_limited_at": "2026-01-01T00:00:00+08:00",
        "resume_after": "2026-01-02T00:00:00+08:00",
    }
    resume = parse_dt(state["resume_after"])
    if resume is None or fmt_delta(timedelta(seconds=90)) != "0h01m30s":
        failures += 1
        print("[FAIL] 时间解析 / 格式化")
    else:
        print("[OK] 时间解析 / 格式化")

    print("[SUMMARY] selftest failures=%d" % failures)
    return EXIT_OK if failures == 0 else 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", help="fountain 仓库根（默认从技能位置 / 当前目录推断）")
    common.add_argument(
        "--env",
        choices=("auto", "windows", "wsl", "harmony", "fusion", "native"),
        default="auto",
        help="覆盖执行环境判定（默认 auto）",
    )
    common.add_argument("--install-root", help="cjpm install 的 --root；WSL 默认 %s" % DEFAULT_WSL_INSTALL_ROOT)
    common.add_argument("--cangjie-sh", help="仓颉环境脚本；WSL 默认 %s" % DEFAULT_WSL_CANGJIE_SH)
    common.add_argument("--wsl-distro", help="WSL 发行版（默认 %s）" % DEFAULT_WSL_DISTRO)
    common.add_argument("--remote", help="鸿蒙 PC -> 融合开发引擎的 ssh 目标（user@host）")
    common.add_argument("--remote-repo", help="融合引擎里的 fountain 仓库路径")

    parser = argparse.ArgumentParser(
        prog="publish.py",
        description="安装 fboot 并执行 fboot pub；出现限流立即停止，记录 24 小时冷却。",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    detect = sub.add_parser("detect", parents=[common], help="只读：打印环境判定与执行计划")
    detect.add_argument("--json", action="store_true", help="JSON 输出")

    run = sub.add_parser("run", parents=[common], help="执行完整流水线")
    run.add_argument("--version", required=True, help="发布版本，形如 1.3.20")
    run.add_argument("--skip-install", action="store_true", help="跳过 cjpm install（fboot 已装好时）")
    run.add_argument("--wait", action="store_true", help="限流后原地等待 24 小时再继续（仅常驻会话）")
    run.add_argument("--force", action="store_true", help="忽略未满 24 小时的冷却（仅用户明确要求）")
    run.add_argument(
        "--rate-limit-pattern",
        action="append",
        default=[],
        help="追加限流正则（可多次给出）",
    )
    run.add_argument("--heartbeat", type=int, default=60, help="心跳间隔秒数，0 关闭（默认 60）")

    sub.add_parser("selftest", help="限流判定自检（无副作用）")
    return parser


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    args = build_parser().parse_args(argv)
    if args.command == "detect":
        return cmd_detect(args)
    if args.command == "selftest":
        return selftest()
    return run_pipeline(args)


if __name__ == "__main__":
    sys.exit(main())
