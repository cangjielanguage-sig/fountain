#!/usr/bin/env bash
# 停止 start-fmq.sh 启动的 fmq server（SIGTERM 触发优雅关闭）。
#
# 用法：bash stop-fmq.sh [--clean]
#   --clean  停止后删除运行目录（默认 /tmp/fmqdemo）
# 注意：不要开 `set -u`（与 cangjie.sh 冲突，见 start-fmq.sh）。
set -o pipefail

RUN_DIR=${FMQDEMO_RUN_DIR:-/tmp/fmqdemo}
CLEAN=0
for arg in "$@"; do
  case "${arg}" in
    --clean) CLEAN=1 ;;
    *) echo "未知参数：${arg}（可用 --clean）"; exit 2 ;;
  esac
done

if [ -f "${RUN_DIR}/pid" ]; then
  PID=$(cat "${RUN_DIR}/pid")
  if kill -0 "${PID}" 2>/dev/null; then
    echo "==> 停止 fmq server（pid=${PID}）"
    kill -TERM "${PID}" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "${PID}" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "${PID}" 2>/dev/null; then
      echo "  优雅关闭超时，强制结束"
      kill -KILL "${PID}" 2>/dev/null || true
    fi
    wait "${PID}" 2>/dev/null || true
    echo "  已停止"
  else
    echo "==> fmq 未在运行（pid 文件残留）"
  fi
  rm -f "${RUN_DIR}/pid"
else
  echo "==> 未找到 ${RUN_DIR}/pid，fmq 可能未启动"
fi

if [ "${CLEAN}" -eq 1 ]; then
  echo "==> 删除运行目录 ${RUN_DIR}"
  rm -rf "${RUN_DIR}"
fi
