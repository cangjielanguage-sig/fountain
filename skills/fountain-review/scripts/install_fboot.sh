#!/usr/bin/env bash
# fountain :: fboot 环境检查与安装（Linux / WSL / git-bash）
#
# 用法：
#   bash install_fboot.sh version [--root DIR] [--source FOUNTAIN_ROOT]
#   bash install_fboot.sh check
#   bash install_fboot.sh install [--root DIR] [--source FOUNTAIN_ROOT] [--cangjie-sh PATH] [--from-registry X.Y.Z]
#
# version :: 查看 fboot 版本，一次列出三处（fboot 不在 PATH 时也能查）：
#              PATH 中的 fboot / 安装目录（--root、$CJPM_INSTALL、~/.cjpm）中的 fboot / 源码 f_version 的版本
#
# check   :: 探测环境（cjc / cjpm / fboot / stdx / fountain 源码）；
#            若 cjpm 不在 PATH，会先尝试 source 仓颉环境脚本（与用户交互 shell 的行为一致），
#            脚本本身不写任何项目文件
# install :: 从 fountain 源码安装 fboot：
#              cd <fountain>/fboot && cjpm install --root DIR
#            DIR 默认取 $CJPM_INSTALL，否则 ~/.cjpm；
#            --from-registry X.Y.Z 改为从中心仓安装：
#              cjpm install fountain::fboot-X.Y.Z --root DIR
#
# 注意：不要给本脚本套 `set -u`（仓颉环境脚本会引用未定义变量）。

MODE="${1:-}"
if [ -n "$MODE" ]; then shift; fi

ROOT_DIR=""
SOURCE_DIR=""
CANGJIE_SH=""
FROM_REGISTRY=""

usage() {
  echo "用法: bash install_fboot.sh version [--root DIR] [--source FOUNTAIN_ROOT]"
  echo "      bash install_fboot.sh check"
  echo "      bash install_fboot.sh install [--root DIR] [--source FOUNTAIN_ROOT] [--cangjie-sh PATH] [--from-registry X.Y.Z]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT_DIR="$2"; shift 2 ;;
    --source) SOURCE_DIR="$2"; shift 2 ;;
    --cangjie-sh) CANGJIE_SH="$2"; shift 2 ;;
    --from-registry) FROM_REGISTRY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 2 ;;
  esac
done

case "$MODE" in
  version|check|install) ;;
  *) usage; exit 2 ;;
esac

# 定位 fountain 仓库根：--source > FOUNTAIN_ROOT > 脚本位置（skills/fountain-developer/scripts/ 上溯）
# > 当前目录向上。判据：存在 fboot/cjpm.toml 与 f_version/src/FountainVersion.cj。
find_fountain_root() {
  local d
  if [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/fboot/cjpm.toml" ]; then
    (cd "$SOURCE_DIR" && pwd); return 0
  fi
  if [ -n "$FOUNTAIN_ROOT" ] && [ -f "$FOUNTAIN_ROOT/fboot/cjpm.toml" ]; then
    (cd "$FOUNTAIN_ROOT" && pwd); return 0
  fi
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local i
  for i in 1 2 3; do
    d="$(dirname "$d")"
    if [ -f "$d/fboot/cjpm.toml" ] && [ -f "$d/f_version/src/FountainVersion.cj" ]; then
      echo "$d"; return 0
    fi
  done
  d="$(pwd)"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/fboot/cjpm.toml" ] && [ -f "$d/f_version/src/FountainVersion.cj" ]; then
      echo "$d"; return 0
    fi
    local parent
    parent="$(dirname "$d")"
    [ "$parent" = "$d" ] && break
    d="$parent"
  done
  return 1
}

# 确保 cjpm 可用：优先 PATH；否则尝试 source 仓颉环境脚本。
# 候选顺序：--cangjie-sh > $CANGJIE_ENV_SH > shell rc 里已配置的 source 行 > $HOME/.cangjie_env.sh
# > /mnt/d/docs/work/cangjie/cangjie.sh（本机已知位置）。
ensure_cangjie() {
  if command -v cjpm >/dev/null 2>&1; then return 0; fi
  echo "cjpm 不在 PATH，尝试配置仓颉环境 ..."
  local cands=""
  [ -n "$CANGJIE_SH" ] && cands="$CANGJIE_SH"
  [ -n "$CANGJIE_ENV_SH" ] && cands="$cands $CANGJIE_ENV_SH"
  local rc rc_line
  for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    rc_line="$(grep -oE '(source|\.)[[:space:]]+[^[:space:]]*cangjie[^[:space:]]*\.sh' "$rc" 2>/dev/null | tail -n 1 | awk '{print $2}')"
    [ -n "$rc_line" ] && cands="$cands $rc_line"
  done
  cands="$cands $HOME/.cangjie_env.sh /mnt/d/docs/work/cangjie/cangjie.sh"
  local c
  for c in $cands; do
    if [ -f "$c" ]; then
      echo "source $c"
      # shellcheck disable=SC1090
      source "$c" >/dev/null 2>&1
      if command -v cjpm >/dev/null 2>&1; then return 0; fi
    fi
  done
  return 1
}

do_check() {
  echo "== fountain :: fboot 环境探测 =="
  echo
  if ! command -v cjpm >/dev/null 2>&1; then
    ensure_cangjie || true
    echo
  fi
  echo "-- fountain 源码 --"
  local fr
  if fr="$(find_fountain_root)"; then
    echo "根目录: $fr"
    echo "版本  : $(grep -oE 'Version = \"[^\"]+\"' "$fr/f_version/src/FountainVersion.cj" 2>/dev/null | head -n 1)"
  else
    echo "未找到（可用 --source / FOUNTAIN_ROOT 指定，或只从中心仓安装 fboot）"
  fi
  echo
  echo "-- 工具链 --"
  if command -v cjc >/dev/null 2>&1; then
    cjc -v 2>&1 | head -n 2
  else
    echo "cjc: 未找到（需先 source 仓颉环境）"
    echo "提示: WSL 里 bash -lc 不读 ~/.bashrc，脚本里要显式 source；详见 references/environment.md"
  fi
  if command -v cjpm >/dev/null 2>&1; then
    cjpm --version 2>&1 | head -n 1
  else
    echo "cjpm: 未找到"
  fi
  echo
  echo "-- 关键环境变量 --"
  local v val
  for v in CANGJIE_HOME CANGJIE_STDX_DYNAMIC_PATH CANGJIE_STDX_PATH CJPM_INSTALL CJPM_CONFIG FOUNTAIN_HOME; do
    val="$(printenv "$v" 2>/dev/null)"
    echo "$v=${val:-（未设置）}"
  done
  echo
  echo "-- fboot --"
  if command -v fboot >/dev/null 2>&1; then
    echo "PATH 中 fboot: $(command -v fboot)"
    fboot version 2>&1 | head -n 2
  else
    echo "fboot 不在 PATH"
  fi
  local d
  for d in "$CJPM_INSTALL" "$HOME/.cjpm"; do
    [ -n "$d" ] || continue
    if [ -x "$d/bin/fboot" ]; then
      echo "发现 fboot 产物: $d/bin/fboot（libs: $d/libs/fboot）"
    fi
  done
  echo
  echo "用本脚本安装: bash install_fboot.sh install [--root DIR] [--source FOUNTAIN_ROOT]"
}

do_install() {
  local root="${ROOT_DIR:-${CJPM_INSTALL:-$HOME/.cjpm}}"
  local code=0

  if ! ensure_cangjie; then
    echo "错误: cjpm 不可用，且未能自动 source 仓颉环境。" >&2
    echo "      请用 --cangjie-sh PATH 指定环境脚本，或先在交互 shell 里配置好仓颉环境。" >&2
    exit 1
  fi

  echo "安装目标 root: $root"
  if [ -n "$FROM_REGISTRY" ]; then
    echo "来源: 中心仓 fountain::fboot-$FROM_REGISTRY"
    echo "+ cjpm install fountain::fboot-$FROM_REGISTRY --root $root"
    cjpm install "fountain::fboot-$FROM_REGISTRY" --root "$root"
    code=$?
  else
    local fr
    if ! fr="$(find_fountain_root)"; then
      echo "错误: 未找到 fountain 源码（需含 fboot/cjpm.toml 与 f_version/src/FountainVersion.cj）。" >&2
      echo "      用 --source 指定源码目录，或用 --from-registry X.Y.Z 从中心仓安装。" >&2
      exit 1
    fi
    echo "来源: 本地源码 $fr/fboot"
    echo "+ cd $fr/fboot && cjpm install --root $root"
    (cd "$fr/fboot" && cjpm install --root "$root")
    code=$?
  fi

  if [ "$code" -ne 0 ]; then
    echo "安装失败，exit=$code" >&2
    exit "$code"
  fi

  echo
  echo "-- 产物核对 --"
  if [ -x "$root/bin/fboot" ]; then
    echo "ok: $root/bin/fboot"
  else
    echo "警告: 未找到 $root/bin/fboot" >&2
  fi
  if [ -d "$root/libs/fboot" ]; then
    echo "ok: $root/libs/fboot（$(ls "$root/libs/fboot" | wc -l) 个文件）"
  else
    echo "警告: 未找到 $root/libs/fboot" >&2
  fi

  echo
  echo "-- 配置环境变量（每个新 shell 都要） --"
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      echo "export PATH=\$PATH:$root/bin"
      echo "export PATH=\$PATH:$root/libs/fboot   # git-bash: dll 目录也要进 PATH"
      ;;
    *)
      echo "export PATH=\$PATH:$root/bin"
      echo "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$root/libs/fboot"
      ;;
  esac
  echo "export CANGJIE_STDX_DYNAMIC_PATH=<stdx 动态库所在目录>"
  echo
  echo "-- 验证 --"
  local vline
  vline="$(fboot_version_line "$root/bin/fboot" "$root/libs/fboot")"
  case "$vline" in
    fountain\(*\)) echo "ok: fboot version -> $vline" ;;
    *) echo "警告: fboot version 输出异常 -> $vline（确认 $root/libs/fboot 已加入动态库搜索路径）" >&2 ;;
  esac
}

# 读一个 fboot 可执行文件的版本行；缺动态库时用同级 libs/fboot（或传入的 libs）重试。
fboot_version_line() {
  local exe="$1" libs="$2" out guess
  [ -x "$exe" ] || { echo "（不可执行）"; return 0; }
  out="$("$exe" version 2>&1 | head -n 1)"
  case "$out" in
    fountain\(*\)) echo "$out"; return 0 ;;
  esac
  if [ -z "$libs" ]; then
    guess="$(cd "$(dirname "$exe")/.." 2>/dev/null && pwd)/libs/fboot"
    [ -d "$guess" ] && libs="$guess"
  fi
  if [ -n "$libs" ] && [ -d "$libs" ]; then
    out="$(LD_LIBRARY_PATH="$libs:$LD_LIBRARY_PATH" "$exe" version 2>&1 | head -n 1)"
  fi
  echo "$out"
}

do_version() {
  echo "== fboot 版本 =="
  echo
  ensure_cangjie || true
  # CJPM_INSTALL 未设置时，从 PATH 中的 fboot 位置推断安装目录
  local p
  if [ -z "$CJPM_INSTALL" ]; then
    p="$(command -v fboot 2>/dev/null)"
    if [ -n "$p" ]; then
      CJPM_INSTALL="$(cd "$(dirname "$p")/.." 2>/dev/null && pwd)"
    fi
  fi

  echo "-- PATH 中的 fboot --"
  if command -v fboot >/dev/null 2>&1; then
    echo "路径: $(command -v fboot)"
    echo "fboot 版本: $(fboot_version_line "$(command -v fboot)" "")"
  else
    echo "未找到（仓颉环境未配置，或 fboot 未安装）"
  fi
  echo

  echo "-- 安装目录中的 fboot（--root / \$CJPM_INSTALL / ~/.cjpm） --"
  local d seen=":" found=0
  for d in "$ROOT_DIR" "$CJPM_INSTALL" "$HOME/.cjpm"; do
    [ -n "$d" ] || continue
    case "$seen" in *":$d:"*) continue ;; esac
    seen="$seen$d:"
    [ -x "$d/bin/fboot" ] || continue
    found=1
    echo "$d -> $(fboot_version_line "$d/bin/fboot" "$d/libs/fboot")"
  done
  [ "$found" -eq 1 ] || echo "未找到（用 install 子命令安装，或确认 --root 是否指对）"
  echo

  echo "-- 源码版本（f_version/src/FountainVersion.cj） --"
  local fr
  if fr="$(find_fountain_root)"; then
    echo "$fr -> $(grep -oE 'Version = "[^"]+"' "$fr/f_version/src/FountainVersion.cj" 2>/dev/null | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
  else
    echo "未找到源码（--source / FOUNTAIN_ROOT 可指定）"
  fi
  echo
  echo "说明: \`fboot version\` 返回的就是 fboot 的版本（形如 fountain(x.y.z)），"
  echo "      该版本号也是 fboot workspace 写入 [dependencies] 的依赖版本号。"
}

case "$MODE" in
  check) do_check ;;
  install) do_install ;;
  version) do_version ;;
esac
