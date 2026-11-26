# JSON 字符串转义增加无转义快路径

## Why

`docs/LocalMode.md` 2.5 把 `DataJson.toJsonString` 的「每字段中间 `valStr`」列为优化点，建议 `@ local!` 或写入式 sink。实测表明：

1. `valStr` 必须逃逸到返回的 `String`，`@ local!` 不可行；
2. 真正的分配大头是**字符串转义**：`escapeJsonString` 对每个 rune 走 `StringGenerator.append`，即使整串无需转义也照样构造缓冲。实测 10000 次转义一个 23 字符的普通字符串：**840 B/次**（8.4 MB 总量）。

JSON 中绝大多数字符串不含 `"`、`\` 或控制字符，这个缓冲完全可以跳过。

## What Changes

- **新增无转义快路径**：`escapeJsonString` 先用 rune 扫描判断是否需要转义；不需要时**原样返回输入字符串**（String 不可变，安全），不构造任何缓冲。
- **慢路径不变**：需要转义时仍走既有逐 rune 规则（`"`、`\`、`\n`、`\r`、`\t`、其余 `< 0x20` 转 `\u00XX`），输出逐字节一致。
- **容器路径不动**：`DataObject` / `DataCollection` / `DataMap` 的每字段 `valStr` 保留。实测叶子转义占主导；去掉一次 `valStr` 拷贝的写入式 sink 需要改动 `ToJsonString` 的内部接口与全部 extend，生产调用面很小（仅 fprobe 两处），本变更不做。
- **测试**：新增 `f_data/src/json/JsonEscapeFastPath_test.cj`——快路径内容不变、空串、全特殊字符、混合中文/emoji、控制字符；env-gated 分配基准（≤ 128 B/次，且比旧路径低 8 倍以上）。

**公开 API 不变**：`escapeJsonString` 为包内函数，`ToJsonString` 接口与所有 `toJsonString()` 签名不变。

## Capabilities

### New Capabilities

- `data-json-serialization`：`Data` → JSON 文本的转义与分配约束。

### Modified Capabilities

无。

## Impact

- 代码：`f_data/src/json/DataJson.cj`（`escapeJsonString` 增加快路径与扫描函数）。
- 测试：新增 `f_data/src/json/JsonEscapeFastPath_test.cj`；既有 `DataJsonEscapeTest` 与 `f_data` 全量回归。
- 行为：输出字节完全不变；仅普通字符串不再构造转义缓冲。
- 调用面：`toJsonString` 在本仓库主要用于 `fprobe` 的快照与数值读取，生产压力有限，但快路径收益确定且风险极低。
