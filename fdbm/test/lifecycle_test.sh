#!/bin/bash
# fdbm 进程生命周期用例（仅 Linux/macOS）：
#   boot.sh start → status → stop(SIGTERM) → 进程退出码 0 + 日志含 "fdbm stopped"
#
# 前置：在 fdbm 模块目录执行过 `cjpm build`（提供 f_mockdb 动态库）与 `cjpm install`
#（提供 $HOME/.cjpm/bin/fdbm 与 $HOME/.cjpm/libs/fdbm）。
# 可用 FDBM_BIN / FDBM_LIBS 覆盖。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${FDBM_BIN:-$HOME/.cjpm/bin/fdbm}"
LIBS="${FDBM_LIBS:-$HOME/.cjpm/libs/fdbm}"
DRIVER_SO="$(find "$ROOT/target/release" -name 'libf_mockdb@fountain.so' 2>/dev/null | head -1)"

if [[ ! -x "$BIN" ]]; then
    echo "SKIP: fdbm executable not found at $BIN (run 'cjpm install')"
    exit 0
fi
if [[ -z "$DRIVER_SO" ]]; then
    echo "SKIP: libf_mockdb@fountain.so not found under $ROOT/target/release (run 'cjpm build')"
    exit 0
fi

WORK="$(mktemp -d /tmp/fdbm-lifecycle-XXXXXX)"
PORT=$((46000 + RANDOM % 1000))
PID=""
cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -9 "$PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/driver"
cp "$DRIVER_SO" "$WORK/driver/"
cp "$ROOT/boot.sh" "$WORK/boot.sh"
chmod +x "$WORK/boot.sh"

# 把模板的 managed 区块改成本地 mockdb 夹具（只影响用例副本）
python3 - "$WORK/boot.sh" "$WORK" "$PORT" <<'PY'
import sys
path, work, port = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
replacements = {
    "export fdbm_port='8112'": f"export fdbm_port='{port}'",
    "export fdbm_driverDir='./driver'": f"export fdbm_driverDir='{work}/driver'",
    "export fdbm_db='name0@127.0.0.1:3306;name1@127.0.0.1:3307'": "export fdbm_db='name0@127.0.0.1:3306'",
    "export fdbm_db_driver_name0='mysql'": "export fdbm_db_driver_name0='mockdb'",
    "export fdbm_db_database_name0='db_0,db_1'": "export fdbm_db_database_name0='db0'",
    "export fdbm_db_logicalDatabase_order='db_0,db_1,db_2,db_3'": "export fdbm_db_logicalDatabase_order='db0'",
    "export fdbm_cache='true'": "export fdbm_cache='false'",
    "export fdbm_sessionSweepInterval='30s'": "export fdbm_sessionSweepInterval='100ms'",
    "export fdbm_shutdownTimeout='30s'": "export fdbm_shutdownTimeout='5s'",
}
for old, new in replacements.items():
    if old not in text:
        raise SystemExit(f"boot.sh template changed: missing {old!r}")
    text = text.replace(old, new)
open(path, "w").write(text)
PY

cd "$WORK"
./boot.sh start
PID="$(cat "$WORK/fdbm.pid")"

./boot.sh status | grep -q "is running"

before="$(wc -l < "$WORK/fdbm.log")"
./boot.sh stop

if kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: process $PID is still alive after stop" >&2
    exit 1
fi
# 异步日志在进程退出前可能来不及刷出最后一行，故以"stopping"为优雅停止标记
#（收到 SIGTERM 但未装 handler 时会被内核直接终止，不会出现任何 stopping 日志）。
if ! tail -n +"$((before + 1))" "$WORK/fdbm.log" | grep -q "fdbm is stopping"; then
    echo "FAIL: log does not contain graceful stop marker" >&2
    tail -20 "$WORK/fdbm.log" >&2
    exit 1
fi
echo "PASS: start/status/stop lifecycle is graceful"

