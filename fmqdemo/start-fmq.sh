#!/usr/bin/env bash
# fmqdemo 步骤 1+2：启动 fmq server，并注册演示用主题与订阅组。
#
# 用法：
#   bash start-fmq.sh [--fresh] [--no-build]
#     --fresh     先清空运行目录（默认 /tmp/fmqdemo）再启动，保证从零开始
#     --no-build  跳过 f_mq / fmq / fmqdemo(workspace) 的构建
#
# 可用环境变量覆盖：FMQDEMO_PORT(23700)、FMQDEMO_RUN_DIR(/tmp/fmqdemo)、
#                  FMQDEMO_TOPIC(/fmqdemo)、FMQDEMO_QUEUES(2)、FMQDEMO_GROUP(demoGroup)
# 注意：不要开 `set -u` —— 这里要 source 的 cangjie.sh 会引用未定义的位置参数，-u 会让它直接失败。
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "${HERE}/.." && pwd)
# shellcheck disable=SC1091
source "${HERE}/env.sh" || exit 1

PORT=${FMQDEMO_PORT:-23700}
NODES="127.0.0.1:${PORT}"
RUN_DIR=${FMQDEMO_RUN_DIR:-/tmp/fmqdemo}
TOPIC=${FMQDEMO_TOPIC:-/fmqdemo}
QUEUES=${FMQDEMO_QUEUES:-2}
GROUP=${FMQDEMO_GROUP:-demoGroup}
# 【必填】本机在集群内的唯一主机号：MessageID 拒绝 hostId=0
PROTOCOL_HOST_ID=${protocol_hostId:-1}

FRESH=0
BUILD=1
for arg in "$@"; do
  case "${arg}" in
    --fresh) FRESH=1 ;;
    --no-build) BUILD=0 ;;
    *) echo "未知参数：${arg}（可用 --fresh / --no-build）"; exit 2 ;;
  esac
done

FMQ_DIR="${ROOT}/fmq/target/release"
FMQ_BIN_ORIG="${FMQ_DIR}/bin/main"

lib_path() {
  # 各模块的动态库都放在 target/release/<name>@<org>/ 下
  find "$1" -maxdepth 3 -type d -name '*@*' 2>/dev/null | tr '\n' ':'
}
export LD_LIBRARY_PATH="$(lib_path "${FMQ_DIR}")$(lib_path "${ROOT}/f_mq/target/release")$(lib_path "${HERE}/target/release")${LD_LIBRARY_PATH:-}"

manager() {
  env mqClient_hosts="${NODES}" mqServer_port="${PORT}" protocol_hostId="${PROTOCOL_HOST_ID}" "${FMQ_BIN_ORIG}" manager \
    --server="127.0.0.1:${PORT}" "$@"
}

if [ "${BUILD}" -eq 1 ]; then
  echo "==> 构建 f_mq / fmq（首次较慢）"
  (cd "${ROOT}/f_mq" && cjpm build) || { echo "f_mq 构建失败"; exit 1; }
  (cd "${ROOT}/fmq" && cjpm build) || { echo "fmq 构建失败"; exit 1; }
  echo "==> 构建 fmqdemo workspace（fboot 加载的两个动态库：fmqpub / fmqsub）"
  (cd "${HERE}" && fboot build ./target) || { echo "fmqdemo 构建失败"; exit 1; }
fi
[ -x "${FMQ_BIN_ORIG}" ] || { echo "找不到 fmq 可执行文件：${FMQ_BIN_ORIG}"; exit 1; }

if [ "${FRESH}" -eq 1 ]; then
  echo "==> 清空运行目录 ${RUN_DIR}"
  if [ -f "${RUN_DIR}/pid" ] && kill -0 "$(cat "${RUN_DIR}/pid")" 2>/dev/null; then
    kill "$(cat "${RUN_DIR}/pid")" 2>/dev/null || true
    sleep 1
  fi
  rm -rf "${RUN_DIR}"
fi
mkdir -p "${RUN_DIR}"

if [ -f "${RUN_DIR}/pid" ] && kill -0 "$(cat "${RUN_DIR}/pid")" 2>/dev/null; then
  echo "==> fmq 已在运行（pid=$(cat "${RUN_DIR}/pid")，端口 ${PORT}），跳过启动"
else
  # metas 目录由「可执行文件所在目录」推导 ⇒ 复制到运行目录，保证每套演示的数据独立
  cp "${FMQ_BIN_ORIG}" "${RUN_DIR}/fmq"
  echo "==> 启动 fmq server（端口 ${PORT}，数据目录 ${RUN_DIR}）"
  env \
    mqClient_hosts="${NODES}" \
    mqServer_port="${PORT}" \
    protocol_hostId="${PROTOCOL_HOST_ID}" \
    mqServer_ackTimeout=2s \
    mqServer_deadMsgThreshold=2 \
    mqServer_deadMsgTTL=1h \
    mqServer_segmentedLogDir="${RUN_DIR}/logs" \
    mqServer_deadMsgDir="${RUN_DIR}/dead" \
    mqServer_segmentedLogMaxSize=8M \
    mqServer_segmentedLogTTL=1h \
    mqServer_backup=0 \
    "${RUN_DIR}/fmq" server >"${RUN_DIR}/server.log" 2>&1 &
  echo $! >"${RUN_DIR}/pid"

  ready=0
  for _ in $(seq 1 300); do
    if manager listTopics >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.1
  done
  if [ "${ready}" -ne 1 ]; then
    echo "fmq 启动失败（30s 内未就绪）；server.log 末尾："
    tail -20 "${RUN_DIR}/server.log"
    exit 1
  fi
fi

echo "==> 注册主题 ${TOPIC}（队列数 ${QUEUES}）"
if manager registerTopic "${TOPIC}" "${QUEUES}" >"${RUN_DIR}/register_topic.log" 2>&1; then
  echo "  [OK] 主题已注册"
elif manager listTopics 2>/dev/null | grep -qF "${TOPIC}"; then
  echo "  [SKIP] 主题已存在"
else
  echo "  [FAIL] 注册主题失败："
  cat "${RUN_DIR}/register_topic.log"
  exit 1
fi

echo "==> 注册订阅组 ${GROUP}"
if manager registerSubscriber "${TOPIC}" "${GROUP}" >"${RUN_DIR}/register_group.log" 2>&1; then
  echo "  [OK] 订阅组已注册"
elif manager listSubscribeGroups "${TOPIC}" 2>/dev/null | grep -qF "${GROUP}"; then
  echo "  [SKIP] 订阅组已存在"
else
  echo "  [FAIL] 注册订阅组失败："
  cat "${RUN_DIR}/register_group.log"
  exit 1
fi

echo
echo "fmq 已就绪："
echo "  节点        ${NODES}"
echo "  主题/组     ${TOPIC} / ${GROUP}"
echo "  运行目录    ${RUN_DIR}（metas、段日志、server.log）"
echo "  发布端      mqClient_hosts=${NODES} bash ${HERE}/boot.sh runPub"
echo "  消费端      mqClient_hosts=${NODES} bash ${HERE}/boot.sh runSub"
echo "  停止        bash ${HERE}/stop-fmq.sh"
