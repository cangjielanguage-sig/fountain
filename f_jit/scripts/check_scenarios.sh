#!/usr/bin/env bash
# scenario → test 矩阵校验（M1 全 9 个 capability）。
#
# 四列格式：capability <TAB> scenario <TAB> test_case（逗号分隔） <TAB> 强度
#   - test_case = N/A    ：流程/文档项，无代码用例（强度必须为 N/A）
#   - test_case = GAP    ：**已知缺口**，无任何用例断言该 scenario（强度必须为 none）
#   - 其余               ：测试函数名，必须能在 f_jit/src 或 f_util/src 的 *_test.cj 中解析到
# 强度：full（断言直接覆盖 THEN）/ partial（仅覆盖代表性子集）/ none / N/A
#
# 三道检查：
#   1. 映射里的 scenario 必须真的出现在该 capability 的 spec 中；
#   2. 声明的测试函数必须存在（否则视为笔误/挂名）；
#   3. spec 里的每条 scenario 都必须出现在映射中（完整性，禁止漏登记）。
#
# 用法：
#   check_scenarios.sh [m1|m2|m2.1|m2.2] [--strict]
#     m1（默认）/ m2 / m2.1 / m2.2 = 里程碑，决定 spec 目录与 tsv 路径
#     m2.1 是**增量矩阵**：doc/spec/f-jit-m2.1 只收录该变更改动的 requirement，
#     未改动的 capability 由 m2 的矩阵覆盖，两者互补。
#     --strict       = 缺口或部分覆盖也判失败（供里程碑把矩阵收紧到「全 full」）
# 默认：缺口与部分覆盖只报告不失败（各里程碑的遗留项在 verify.md 登记）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MILESTONE="m1"
STRICT=0
for arg in "$@"; do
  case "$arg" in
    m1|m2|m2.1|m2.2) MILESTONE="$arg" ;;
    --strict) STRICT=1 ;;
    *) echo "check_scenarios: 未知参数 $arg" >&2; exit 2 ;;
  esac
done
SPECS="$ROOT/doc/spec/f-jit-$MILESTONE/specs"
MAP="$ROOT/doc/spec/f-jit-$MILESTONE/scenario-map.tsv"
[[ -f "$MAP" ]] || { echo "check_scenarios: 缺少 $MAP" >&2; exit 2; }

# 测试函数可来自 f_jit 自身，也可来自 f_util（f-util-fnv 的用例在那边）。
SEARCH_DIRS=("$ROOT/src")
[[ -d "$ROOT/../f_util/src" ]] && SEARCH_DIRS+=("$ROOT/../f_util/src")

has_test() {
  local name="$1" d
  for d in "${SEARCH_DIRS[@]}"; do
    grep -rqE "func[[:space:]]+$name[[:space:]]*\(" "$d" --include='*_test.cj' && return 0
  done
  return 1
}

total=0; missing=0; gaps=0; partial=0; full=0; na=0
declare -a gap_list=() partial_list=()

while IFS=$'\t' read -r cap scenario tests strength; do
  [[ -z "${cap:-}" || "$cap" == \#* ]] && continue
  total=$((total+1))
  spec="$SPECS/$cap/spec.md"
  if [[ ! -f "$spec" ]] || ! grep -qF "#### Scenario: $scenario" "$spec"; then
    echo "MISSING scenario: $cap / $scenario"
    missing=$((missing+1))
  fi
  case "$strength" in
    full) full=$((full+1)) ;;
    partial) partial=$((partial+1)); partial_list+=("$cap / $scenario") ;;
    none) gaps=$((gaps+1)); gap_list+=("$cap / $scenario") ;;
    N/A) na=$((na+1)) ;;
    *) echo "BAD strength: $cap / $scenario -> '$strength'"; missing=$((missing+1)) ;;
  esac
  [[ "$tests" == "GAP" || "$tests" == "N/A" ]] && continue
  IFS=',' read -ra list <<< "$tests"
  for t in "${list[@]}"; do
    if ! has_test "$t"; then
      echo "MISSING test: $cap / $scenario -> $t"
      missing=$((missing+1))
    fi
  done
done < "$MAP"

# 完整性：spec 里每条 scenario 都要在映射中出现（反向检查，防止漏登记）。
unmapped=0
for spec in "$SPECS"/*/spec.md; do
  cap="$(basename "$(dirname "$spec")")"
  while IFS= read -r scenario; do
    [[ -z "$scenario" ]] && continue
    if ! awk -F'\t' -v c="$cap" -v s="$scenario" '$1==c && $2==s{f=1} END{exit !f}' "$MAP"; then
      echo "UNMAPPED scenario: $cap / $scenario"
      unmapped=$((unmapped+1))
    fi
  done < <(grep '^#### Scenario:' "$spec" | sed 's/^#### Scenario: //')
done

echo "check_scenarios: ${total} 条映射（full ${full} / partial ${partial} / 缺口 ${gaps} / N/A ${na}），未映射 ${unmapped}，缺失 ${missing}"
if [[ "$gaps" -gt 0 ]]; then
  echo "已知缺口（无用例断言，已在 verify.md 登记）："
  printf '  - %s\n' "${gap_list[@]}"
fi
if [[ "$partial" -gt 0 ]]; then
  echo "部分覆盖（仅代表性子集）："
  printf '  - %s\n' "${partial_list[@]}"
fi

[[ "$missing" -eq 0 && "$unmapped" -eq 0 ]] || exit 1
if [[ "$STRICT" -eq 1 && ( "$gaps" -gt 0 || "$partial" -gt 0 ) ]]; then
  echo "check_scenarios --strict: 仍有缺口或部分覆盖" >&2
  exit 3
fi
