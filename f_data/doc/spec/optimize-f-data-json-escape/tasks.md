# 任务：JSON 转义无转义快路径

> TDD：先建转义行为回归网与分配基准（Red：840 B/次）→ 加 rune 扫描快路径（Green）→ 全量回归。
> 只改 `f_data` 包内函数；公开 API 0 变化。

## 1. 现状与测量

- [x] 1.1 探针：`escapeJsonString` 10000 次普通串 = 8,402,336 B（840 B/次）；快路径原型 640,000 B（64 B/次，13.1×）（验证：探针打印 `loopOld=8402336`、`loopFast=640000`，运行后删除）
- [x] 1.2 探针：字节下标扫描在 `-O0` 下为 16 B/字节（60000 B 输入 960 KB），负收益（验证：`cjkNew=960000`）
- [x] 1.3 探针：`DataString(cjk).toJsonString()` 1.42 MB 中叶子转义占主导；`valStr` 仅一次拷贝（验证：`dataString=1485888`、`interp=61536`）

## 2. 回归网与基准（Red）

- [x] 2.1 新增 `f_data/src/json/JsonEscapeFastPath_test.cj`：普通 ASCII、中文 emoji、空串内容不变（验证：旧实现上通过）
- [x] 2.2 用例：`"`、`\`、`\n`、`\r`、`\t`、`U+0001` 逐字节符合规则；混合串中文/emoji 原样（验证：旧实现上通过）
- [x] 2.3 用例：`DataString.toJsonString()` 带引号包裹的结果不变（验证：旧实现上通过）
- [x] 2.4 分配基准：`F_DATA_JSON_BENCH=1` 时对同一普通串重复 10000 次，对照测试内复刻的旧式 `StringGenerator` 逻辑；断言快路径 `<= 128 B/次` 且旧路径总量高于快路径 8 倍（验证：旧实现上为 Red：840 B/次）
- [x] 2.5 `cd f_data && cjpm test` 全绿（新增行为用例 + 既有套件）（验证：Summary FAILED 0）

## 3. 实现（Green）

- [x] 3.1 `DataJson.cj` 增加 `jsonNeedsEscape(s)`：rune 扫描 `"`、`\`、码点 `< 0x20`，首个命中即返回（验证：行为用例通过）
- [x] 3.2 `escapeJsonString` 入口加快路径：无需转义时原样返回输入；慢路径分支不动（验证：转义逐字符用例通过）
- [x] 3.3 开启 `F_DATA_JSON_BENCH=1` 重跑基准（验证：`<= 128 B/次`，旧路径 > 8×）

## 4. 回归与契约

- [x] 4.1 `cd f_data && cjpm test` 连续两次全绿（验证：两次 Summary FAILED 0）
- [x] 4.2 `escapeJsonString` / `ToJsonString` / 所有 `toJsonString()` 无 `public` 签名变化（验证：`git diff -- f_data/src | rg "^[+-].*public"` 只命中新增测试类）
- [x] 4.3 既有 `DataJsonEscapeTest` 全通过（验证：按套件过滤运行）

## 5. 产物与提交

- [x] 5.1 镜像 `openspec/changes/optimize-f-data-json-escape/` 到 `f_data/doc/spec/optimize-f-data-json-escape/`，两份逐文件一致（验证：`diff -r` 仅差 `.openspec.yaml`）
- [x] 5.2 `openspec validate optimize-f-data-json-escape --strict` 通过（验证：输出 `is valid`）
- [x] 5.3 提交到 `feature/local-mode-f-data-json`（验证：`git log -1 --stat` 只含预期文件）

## Workflow follow-up

- 推送 `feature/local-mode-f-data-json`，合并回 `sts/1.3.x-LocalMode`，合并后再跑 `f_data` 全量。
- 执行 `opsx:verify`，通过后 `opsx:archive` 并同步主规格。
