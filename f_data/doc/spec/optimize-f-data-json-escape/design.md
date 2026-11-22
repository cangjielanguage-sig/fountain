# 设计：JSON 转义的无转义快路径

## Context

`docs/LocalMode.md` 2.5 把 `DataObject.toJsonString` 的每字段 `valStr` 列为优化点。探针（临时用例，已删除）测量了三件事：

| 测量（`-O0`，5 次采样取最小） | 结果 |
| --- | --- |
| 10000 次 `escapeJsonString(23 字符普通串)` | 8,402,336 B → **840 B/次** |
| 同上，快路径原型（rune 扫描后原样返回） | 640,000 B → **64 B/次**（13.1×） |
| 20000 汉字转义 | 1.42 MB |
| `'"' + s + '"'` / 插值 / `StringBuilder` 三连 append | 122 KB / 61 KB / 61 KB |

结论：
1. `valStr` 必须逃逸到返回的 `String`，`@ local!` 不可行；
2. 叶子的 `escapeJsonString` 是主导项，而普通字符串根本不需要构造缓冲；
3. 容器的 `valStr` 只是把叶子结果再拷贝一次（约 1×），写入式 sink 的收益远小于快路径。

## Goals / Non-Goals

**Goals：**
- 无需转义的字符串零缓冲、零新字符串返回。
- 需要转义的输出逐字节不变。
- 公开 API 不变。

**Non-Goals：**
- 不改 `ToJsonString` 接口，不引入写入式 sink。
- 不改 `DataObject` / `DataCollection` / `DataMap` 的每字段 `valStr`。
- 不做基于字节的下标扫描（`-O0` 下逐字节下标反而引入 16 B/字节的额外开销，实测 60000 B 输入耗 960 KB）。

## Decisions

### D1 rune 扫描快路径

```cangjie
private func jsonNeedsEscape(s: String): Bool {
    for (r in s.runes()) {
        if (r == r'"' || r == r'\\' || r.position() < 0x20) {
            return true
        }
    }
    false
}

internal func escapeJsonString(s: String): String {
    if (!jsonNeedsEscape(s)) {
        return s          // String 不可变，原样返回安全
    }
    // 既有逐 rune 转义逻辑，不变
}
```

**理由**：rune 迭代在 `-O0` 下几乎不分配（20000 rune 扫描共 64 B），而未命中时直接返回原字符串，跳过 `StringGenerator` 的创建、增长与 `toString()`。

**替代方案**：
- *字节下标扫描*：`-O0` 下每个 `bytes[i]` 产生 16 B 分配，60000 B 输入实测 960 KB，负收益。
- *先记录首个转义位置再整段追加*：能减少慢路径的逐 rune 追加，但需要处理 rune 与字节位置映射，复杂度明显上升；当前慢路径已只占少数输入。

### D2 慢路径保持不变

命中转义时仍按既有分支输出：`\"`、`\\`、`\n`、`\r`、`\t`、`\u00XX`。先扫描再转义会多一次 rune 遍历（最坏 O(n)），但该路径本来就 O(n) 且分配主导，可接受。

### D3 容器 `valStr` 保持

`DataObject` / `DataCollection` / `DataMap` 仍调用叶子的 `toJsonString()` 再 `append`。实测叶子转义是 840 B/次，容器拷贝约等于叶子结果长度；先修叶子即可拿到主要收益，sink 化留待有真实压力时再做。

### D4 测试与基准

- 新增 `f_data/src/json/JsonEscapeFastPath_test.cj`：
  - 普通 ASCII / 中文 emoji / 空串：内容不变；
  - `"`、`\`、`\n`、`\r`、`\t`、`U+0001`：逐字节符合规则；
  - 混合串：中文与 emoji 原样，特殊字符转义；
  - `DataString.toJsonString()` 集成：带引号包裹的结果不变。
- env-gated 分配基准（`F_DATA_JSON_BENCH=1`）：
  - 同一普通字符串重复 10000 次；
  - 对照实现为测试内复刻的旧式 `StringGenerator` 逐 rune 逻辑；
  - 断言快路径 `<= 128 B/次`，且旧路径总量 `> 快路径 × 8`。

## Risks / Trade-offs

| 风险 | 处理 |
| --- | --- |
| 返回输入字符串产生别名 | String 不可变，调用方无法就地修改；与原实现返回新串内容一致 |
| 慢路径多一次扫描 | 仅命中转义时发生，O(n) 且不分配；实测混合串旧 440 KB / 新 352 KB 仍更优 |
| 转义规则漂移 | 慢路径代码不改；新增逐字符用例 + 既有 `DataJsonEscapeTest` |
| `toJsonString` 生产使用面小 | 收益确定、改动局部；不引入新依赖与新 API |

## Migration Plan

- 只改 `f_data/src/json/DataJson.cj` 的 `escapeJsonString`，无数据/配置迁移。
- 回退：`git revert` 单个提交即可，输出不受影响。

## Open Questions

无。
