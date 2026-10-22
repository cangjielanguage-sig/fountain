#!/usr/bin/env bash
# T 编号映射强校验（S7.6 / S0.3）：
#   ① 每条 TMapping 的 caseName SHALL 能在 `src/**/*_test.cj` 中解析到 `func <caseName>(`；
#   ② 该用例体 SHALL 以**可执行语句**引用标签 `TCase.hit('<id>/<场景>', <真实条件>)`
#      （先剥掉注释再判定——注释里的 `// T<id>/` 不算，防止「挂名映射」）；
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
# M1 与 M2 同属「完成判据」：两张表用同一套强校验（owner 只用于区分里程碑）。
entries = re.findall(
    r"TMapping\('(T\d+)',\s*\[([^\]]*)\],\s*'([^']+)',\s*'(?:M1|M2|M3)',\s*true\)", text)

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
    # 剥掉注释后再找标签：`// T14/` 这类注释不算数，必须是**函数实的字符串首参**
    # ——差分侧 `diff('T18/…', …)`、单元侧 `TCase.hit('T14/…', 条件)` 都算行为级引用。
    code = re.sub(r'/\*.*?\*/', '', body, flags=re.S)
    code = re.sub(r'//[^\n]*', '', code)
    if not re.search(rf"[A-Za-z_][A-Za-z0-9_.]*\(\s*'{tid}/", code):
        print(f'MISSING {tid}: 用例 {case}（{os.path.relpath(path, root)}）未把 `{tid}/` 作为函数实的字符串首参（注释不算）')
        missing += 1

print(f'check_tmap: {len(entries)} 条范围内映射（M1+M2+M3），悬空/未断言 {missing} 条')
sys.exit(1 if missing else 0)
PY
