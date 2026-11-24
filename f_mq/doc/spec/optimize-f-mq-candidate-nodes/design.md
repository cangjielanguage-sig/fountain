# 设计：预分配候选节点数组

## Context

见 `proposal.md` 的三方对照。补充两点限制：

1. 本地 `ArrayList<Int64>` 上 `contains` 无匹配重载（`no matching function declaration`）；
2. `toArray()` 返回 `Array<Int64> @ local!`，与函数返回类型 `Array<Int64>` 不匹配，必须逐元素拷回堆数组——这一步把 local 的收益从 4.5× 拉回到与预分配数组相近但更慢（928 vs 672 B）。

## Goals / Non-Goals

**Goals：**
- 消除每次调用 3.5 KB（n=8）的列表增长与 `toArray` 拷贝。
- 保持「owner 优先、去重、其余兜底」的顺序语义。

**Non-Goals：**
- 不启用 local mode，不改 `cjpm.toml`。
- 不改 `pool.aliveNodes()` / `ownership.ownersOf()`。
- 不引入 `HashSet`（节点数小，哈希结构反而更重）。

## Decisions

### D1 预分配数组 + 前缀去重

```cangjie
func candidateNodesOf(preferred: Array<Int64>, all: Array<Int64>): Array<Int64> {
    let capacity = preferred.size + all.size
    let buf = Array<Int64>(capacity, repeat: 0)
    var len = 0
    for (node in preferred) {
        if (!containsPrefix(buf, len, node)) {
            buf[len] = node
            len++
        }
    }
    for (node in all) {
        if (!containsPrefix(buf, len, node)) {
            buf[len] = node
            len++
        }
    }
    buf[0..len]
}

private func containsPrefix(buf: Array<Int64>, len: Int64, node: Int64): Bool {
    for (i in 0..len) {
        if (buf[i] == node) {
            return true
        }
    }
    false
}
```

- 一次分配上界 `preferred.size + all.size`；最坏情况（无重复）正好用满。
- 返回切片视图，无二次拷贝；调用方只读迭代。
- 去重是 O(n²)，但节点数是集群规模（个位数到几十），原实现同样是 `ArrayList.contains` 的 O(n²)。

**替代方案**：
- *`@ local!` + 拷回*：4.5×，且需要 local mode 编译选项与 `@ local?` helper；收益低于 D1。
- *`HashSet<Int64>`*：每次调用要建哈希表，n=8 时分配高于数组。

### D2 行为测试

`f_mq/src/client/MQCandidateNodes_test.cj`（与 `MQClient` 同包，可直接调用包内函数）：

1. owner 在前、其余节点在后；
2. preferred 内部重复只保留一个；
3. all 中与 preferred 重复的节点不重复出现；
4. all 内部重复只保留一个；
5. 空 preferred / 空 all / 双空。

### D3 分配基准

`F_MQ_BENCH=1` 时对 n=8 重复 5000 次，比较 `candidateNodesOf` 与测试内复刻的旧写法（`ArrayList` + `contains` + `toArray`）；断言新写法总量低于旧写法 1/2。探针三次重跑数值完全一致（4,168 vs 672），阈值有 3 倍余量。

## Risks / Trade-offs

| 风险 | 处理 |
| --- | --- |
| 切片保留超配的底层数组 | 容量上界 = preferred+all，节点数为个位数，可忽略 |
| 去重顺序变化 | 5 条顺序/去重用例；原语义是「先 owner、再其余」 |
| 基准噪声 | 纯数组构建、无 I/O，探针三次一致；仍留 3 倍余量 |
| 公开 API 变化 | 无：`candidateNodes` 仍私有，新函数包内可见 |

## Migration Plan

- 单文件局部重构，无迁移。回退：`git revert`。

## Open Questions

无。
