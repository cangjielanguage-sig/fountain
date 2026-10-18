#!/usr/bin/env bash
# T 编号映射强校验（S7.6 / S0.3）：每条 TMapping 的 caseName SHALL 能在
# `src/**/*_test.cj` 中解析到 `func <caseName>(`。改名或写错即判悬空并退出 1。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP="$ROOT/src/test/diff/TCoverage.cj"

if [[ ! -f "$MAP" ]]; then
  echo "check_tmap: 找不到映射表 $MAP" >&2
  exit 2
fi

total=0
missing=0

while IFS= read -r line; do
  case_name="$(printf '%s\n' "$line" | sed -E "s/.*TMapping\('[^']+', \[[^]]*\], '([^']+)',.*/\1/")"
  id="$(printf '%s\n' "$line" | sed -E "s/.*TMapping\('([^']+)'.*/\1/")"
  total=$((total + 1))
  if [[ -z "$case_name" ]]; then
    echo "MISSING $id: caseName 为空"
    missing=$((missing + 1))
    continue
  fi
  if ! grep -rqE "func[[:space:]]+${case_name}[[:space:]]*\(" "$ROOT/src" --include='*_test.cj'; then
    echo "MISSING $id: 用例 $case_name 在 src/**/*_test.cj 中不存在"
    missing=$((missing + 1))
  fi
done < <(grep -E "^[[:space:]]*TMapping\(" "$MAP" | grep -F ", 'M1', true)")

echo "check_tmap: ${total} 条范围内映射，悬空 ${missing} 条"
if [[ "$missing" -ne 0 ]]; then
  exit 1
fi
