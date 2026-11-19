#!/usr/bin/env bash
# 载入仓颉环境（cjpm / fboot）。本文件只用于被其它脚本 source。
#
# 依次尝试：$CANGJIE_ENV > /mnt/d/docs/work/cangjie/cangjie.sh > $HOME/cangjie/cangjie.sh
# 覆盖：export CANGJIE_ENV=/path/to/cangjie.sh
if ! command -v cjpm >/dev/null 2>&1; then
  for cand in "${CANGJIE_ENV:-}" /mnt/d/docs/work/cangjie/cangjie.sh "${HOME}/cangjie/cangjie.sh"; do
    if [ -n "${cand}" ] && [ -f "${cand}" ]; then
      # shellcheck disable=SC1090
      source "${cand}"
      break
    fi
  done
fi

if ! command -v cjpm >/dev/null 2>&1; then
  echo "未找到 cjpm：请先配置仓颉环境（export CANGJIE_ENV=<cangjie.sh 路径>）" >&2
  return 1
fi

if ! command -v fboot >/dev/null 2>&1; then
  echo "未找到 fboot：见 fountain-developer 工作流 A（在 fboot/ 目录 cjpm install 安装）" >&2
  return 1
fi

# fboot 的框架动态库在安装目录的 libs/fboot：PATH 里找到 fboot 时通常已带 rpath，这里兜底一次
if ! fboot version >/dev/null 2>&1; then
  FBOOT_BIN=$(command -v fboot)
  FBOOT_HOME=$(cd "$(dirname "${FBOOT_BIN}")/.." && pwd)
  export LD_LIBRARY_PATH="${FBOOT_HOME}/libs/fboot:${LD_LIBRARY_PATH:-}"
fi

return 0
