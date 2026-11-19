#!/usr/bin/env bash
# fmqdemo 全流程：启动 fmq（注册主题/组）→ fboot 加载消费端订阅 → fboot 加载发布端发布
#                → 消费端消费并 ack → 校验。
#
# 用法：bash run-demo.sh [--no-build] [--keep]
#   --no-build  跳过构建
#   --keep      结束后保留运行目录 /tmp/fmqdemo（排查用）
#
# 成功输出 DEMO_OK；失败输出 DEMO_FAILED 并列出失败项（运行目录保留）。
# 发布端/消费端都是动态库，由 `boot.sh runPub` / `boot.sh runSub`（即 fboot run）加载运行。
#
# 事件文件：两端都往 ${RUN_DIR}/<端>.events 逐行 append+flush 写进度（stdout 重定向到文件时
# 是带缓冲的，进程退出才刷），脚本的等待与断言一律读事件文件。
# 注意：不要开 `set -u`（与 cangjie.sh 冲突，见 start-fmq.sh）。
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "${HERE}/.." && pwd)
# shellcheck disable=SC1091
source "${HERE}/env.sh" || exit 1

PORT=${FMQDEMO_PORT:-23700}
NODES="127.0.0.1:${PORT}"
RUN_DIR=${FMQDEMO_RUN_DIR:-/tmp/fmqdemo}
TOPIC=${FMQDEMO_TOPIC:-/fmqdemo}
GROUP=${FMQDEMO_GROUP:-demoGroup}
COUNT=${FMQDEMO_COUNT:-10}
PUB_EVENTS="${RUN_DIR}/publisher.events"
SUB_EVENTS="${RUN_DIR}/consumer.events"

BUILD_ARG=""
KEEP=0
for arg in "$@"; do
  case "${arg}" in
    --no-build) BUILD_ARG="--no-build" ;;
    --keep) KEEP=1 ;;
    *) echo "未知参数：${arg}（可用 --no-build / --keep）"; exit 2 ;;
  esac
done

FAILS=()
fail() { FAILS+=("$1"); }
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "  [PASS] ${name}"
  else
    echo "  [FAIL] ${name}"
    fail "${name}"
  fi
}

# 递归杀掉进程树（fboot 可能 fork 出子进程）
kill_tree() {
  local pid="$1" sig="${2:-TERM}" child
  [ -z "${pid}" ] && return 0
  for child in $(ps -o pid= --ppid "${pid}" 2>/dev/null); do
    kill_tree "${child}" "${sig}"
  done
  kill "-${sig}" "${pid}" 2>/dev/null || true
}
stop_end() {
  local pid="$1"
  [ -z "${pid}" ] && return 0
  kill_tree "${pid}" TERM
  for _ in $(seq 1 50); do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 0.1
  done
  kill_tree "${pid}" KILL
}
SUB_PID=""
PUB_PID=""
cleanup_procs() {
  stop_end "${PUB_PID}"
  stop_end "${SUB_PID}"
}
trap cleanup_procs EXIT

# 等待事件文件里出现某个标记（最多 limit 秒）
wait_for() {
  local file="$1" pattern="$2" limit="$3" label="$4" i=0
  while [ "${i}" -lt "$((limit * 10))" ]; do
    if grep -qE "${pattern}" "${file}" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "  [FAIL] ${label}：${limit}s 内事件文件未出现 '${pattern}'（${file}）"
  return 1
}

echo "==> 步骤 1/2：启动 fmq 并注册主题 ${TOPIC}"
bash "${HERE}/start-fmq.sh" --fresh ${BUILD_ARG} || { echo "DEMO_FAILED（fmq 启动失败）"; exit 1; }

: >"${SUB_EVENTS}"
: >"${PUB_EVENTS}"
export mqClient_hosts="${NODES}"
export FMQDEMO_TOPIC="${TOPIC}"
export FMQDEMO_GROUP="${GROUP}"
export FMQDEMO_COUNT="${COUNT}"

echo "==> 步骤 3：fboot 加载消费端动态库 fmqsub（启动即订阅）"
FMQDEMO_LOG="${SUB_EVENTS}" bash "${HERE}/boot.sh" runSub >"${RUN_DIR}/consumer.log" 2>&1 &
SUB_PID=$!
READY=0
if wait_for "${SUB_EVENTS}" '^SUBSCRIBED' 60 "消费端订阅"; then
  READY=1
else
  tail -20 "${RUN_DIR}/consumer.log"
fi

if [ "${READY}" -eq 1 ]; then
  echo "==> 步骤 4：fboot 加载发布端动态库 fmqpub（启动即发布 ${COUNT} 条）"
  FMQDEMO_LOG="${PUB_EVENTS}" bash "${HERE}/boot.sh" runPub >"${RUN_DIR}/publisher.log" 2>&1 &
  PUB_PID=$!
  wait_for "${PUB_EVENTS}" '^PUBLISH_DONE' 120 "发布端发布" || tail -20 "${RUN_DIR}/publisher.log"
  echo "==> 步骤 5：等待消费端收满 ${COUNT} 条"
  wait_for "${SUB_EVENTS}" '^CONSUME_DONE' 120 "消费端消费" || tail -20 "${RUN_DIR}/consumer.log"
fi

echo "==> 步骤 6：校验全流程"
PUB_COUNT=$(grep -c '^PUBLISHED' "${PUB_EVENTS}" 2>/dev/null || true)
CON_COUNT=$(grep -c '^CONSUMED' "${SUB_EVENTS}" 2>/dev/null || true)
PUB_UNIQ=$(grep '^PUBLISHED' "${PUB_EVENTS}" 2>/dev/null | awk '{print $3}' | sort -u | wc -l | tr -d ' ')
CON_UNIQ=$(grep '^CONSUMED' "${SUB_EVENTS}" 2>/dev/null | awk '{print $3}' | sort -u | wc -l | tr -d ' ')
DIFF=$(diff <(grep '^PUBLISHED' "${PUB_EVENTS}" 2>/dev/null | awk '{print $3}' | sort) \
            <(grep '^CONSUMED' "${SUB_EVENTS}" 2>/dev/null | awk '{print $3}' | sort) | wc -l | tr -d ' ')

check "消费端订阅成功（fboot 加载 fmqsub）" [ "${READY}" -eq 1 ]
check "发布条数 = ${COUNT}" [ "${PUB_COUNT}" -eq "${COUNT}" ]
check "发布内容不重复" [ "${PUB_UNIQ}" -eq "${COUNT}" ]
check "消费条数 = ${COUNT}" [ "${CON_COUNT}" -eq "${COUNT}" ]
check "消费内容不重复" [ "${CON_UNIQ}" -eq "${COUNT}" ]
check "发布与消费内容完全一致" [ "${DIFF}" -eq 0 ]

echo
echo "--- 发布端事件（末 3 行）---"; tail -3 "${PUB_EVENTS}" 2>/dev/null
echo "--- 消费端事件（末 3 行）---"; tail -3 "${SUB_EVENTS}" 2>/dev/null
echo "--- fmq 服务端日志（末 3 行）---"; tail -3 "${RUN_DIR}/server.log" 2>/dev/null

cleanup_procs

if [ "${#FAILS[@]}" -gt 0 ]; then
  echo
  echo "DEMO_FAILED"
  for item in "${FAILS[@]}"; do echo "  - ${item}"; done
  echo "运行目录保留在 ${RUN_DIR}（server.log / publisher.log / consumer.log / *.events）"
  bash "${HERE}/stop-fmq.sh" >/dev/null 2>&1 || true
  exit 1
fi

echo
echo "DEMO_OK"
if [ "${KEEP}" -eq 1 ]; then
  bash "${HERE}/stop-fmq.sh" >/dev/null 2>&1 || true
  echo "运行目录保留在 ${RUN_DIR}"
else
  bash "${HERE}/stop-fmq.sh" --clean >/dev/null 2>&1 || true
fi
exit 0
