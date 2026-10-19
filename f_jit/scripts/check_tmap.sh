#!/usr/bin/env bash
# T 编号映射强校验（S7.6 / S0.3）：
#   ① 每条 TMapping 的 caseName SHALL 能在 `src/**/*_test.cj` 中解析到 `func <caseName>(`；
#   ② 该用例体 SHALL 含 `T<id>/` 断言标签（防止「挂名映射」）；
#   ③ 范围内映射为空步骤/空用例名同样判悬空。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP="$ROOT/src/test/diff/TCoverage.cj"

if [[ ! -f "$MAP" ]]; then
  echo "check_tmap: 找不到映射表 $MAP" >&2
  exit 2
fi

python3 - "$ROOT" "$MAP" <<'PY'
import glob, os, re, sys

root, map_path = sys.argv[1], sys.argv[2]
text = open(map_path, encoding='utf-8').read()
entries = re.findall(
    r"TMapping\('(T\d+)',\s*\[([^\]]*)\],\s*'([^']+)',\s*'M1',\s*true\)", text)

bodies = {}
for path in glob.glob(os.path.join(root, 'src', '**', '*_test.cj'), recursive=True):
    src = open(path, encoding='utf-8').read()
    for m in re.finditer(r'func\s+(\w+)\s*\([^)]*\)\s*:\s*Unit\s*\{', src):
        name, i, depth = m.group(1), m.end(), 1
        while i < len(src) and depth > 0:
            if src[i] == '{':
                depth += 1
            elif src[i] == '}':
                depth -= 1
            i += 1
        bodies[name] = (path, src[m.start():i])

missing = 0
for tid, steps, case in entries:
    if not steps.strip():
        print(f'MISSING {tid}: steps 为空')
        missing += 1
        continue
    if not case:
        print(f'MISSING {tid}: caseName 为空')
        missing += 1
        continue
    if case not in bodies:
        print(f'MISSING {tid}: 用例 {case} 在 src/**/*_test.cj 中不存在')
        missing += 1
        continue
    path, body = bodies[case]
    if f'{tid}/' not in body:
        print(f'MISSING {tid}: 用例 {case}（{os.path.relpath(path, root)}）未含 `{tid}/` 断言标签')
        missing += 1

print(f'check_tmap: {len(entries)} 条范围内映射，悬空/未断言 {missing} 条')
sys.exit(1 if missing else 0)
PY
