#!/usr/bin/env bash
# scenario → test 矩阵校验：每条 scenario 必须出现在对应 capability 的 spec，
# 且声明的测试函数能在 src/**/*_test.cj 中解析到；N/A 允许用于流程/文档项。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP="$ROOT/doc/spec/f-jit-m1/scenario-map.tsv"
[[ -f "$MAP" ]] || { echo "check_scenarios: 缺少 $MAP" >&2; exit 2; }

total=0; missing=0
while IFS=$'\t' read -r cap scenario tests; do
  [[ -z "${cap:-}" || "$cap" == \#* ]] && continue
  total=$((total+1))
  spec="$ROOT/doc/spec/f-jit-m1/specs/$cap/spec.md"
  if [[ ! -f "$spec" ]] || ! grep -qF "#### Scenario: $scenario" "$spec"; then
    echo "MISSING scenario: $cap / $scenario"
    missing=$((missing+1))
  fi
  IFS=',' read -ra list <<< "$tests"
  for t in "${list[@]}"; do
    [[ "$t" == "N/A" ]] && continue
    if ! grep -rqE "func[[:space:]]+$t[[:space:]]*\(" "$ROOT/src" --include='*_test.cj'; then
      echo "MISSING test: $cap / $scenario -> $t"
      missing=$((missing+1))
    fi
  done
done < "$MAP"

echo "check_scenarios: ${total} 条 scenario，缺失 ${missing} 条"
[[ "$missing" -eq 0 ]]
