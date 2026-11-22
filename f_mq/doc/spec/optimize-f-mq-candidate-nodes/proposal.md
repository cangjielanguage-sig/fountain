# 候选节点列表改用预分配数组

## Why

`docs/LocalMode.md` 2.5 列出 `MQClient.candidateNodes` 的 `ArrayList<Int64>`，建议 `@ local!`。探针比较了三种写法（n=8，5000 次，结果三次重跑完全一致）：

| 写法 | 分配/次 | 相对堆 |
| --- | --- | --- |
| `ArrayList<Int64>()` + `contains` + `toArray` | 4,168 B | 1× |
| `@ local!` + 手工去重 + 拷回堆数组 | 928 B | 4.5× |
| 预分配 `Array<Int64>` + 手工去重 + 切片 | **672 B** | **6.2×** |

local 版本有两个限制：`contains` 在本地 `ArrayList` 上不可用；`toArray()` 返回 `Array<Int64> @ local!`，不能作为堆数组返回，必须再逐元素拷回。预分配数组更简单、更快，且**不需要启用 local mode**。

## What Changes

- **抽出 `candidateNodesOf(preferred, all)`**：包内可见的纯函数，按「owner 优先、去重、其余节点兜底」构建候选数组。
- **改用预分配数组**：一次分配 `preferred.size + all.size`，手工前缀去重，返回 `buf[0..len]` 切片（零拷贝视图）。
- **`candidateNodes` 只负责取数据并转发**。
- **测试**：新增 `f_mq/src/client/MQCandidateNodes_test.cj`——顺序、去重、空输入；env-gated 基准（n=8，断言新写法低于旧写法 1/2）。

**公开 API 不变**：`candidateNodes` 仍为私有；`candidateNodesOf` 为包内可见。

## Capabilities

无（纯性能重构，节点顺序与去重语义不变；`.openspec.yaml` 设置 `skip_specs: true`）。

## Impact

- 代码：`f_mq/src/client/MQClient.cj`（`candidateNodes` + 新增纯函数）。
- 测试：新增 `f_mq/src/client/MQCandidateNodes_test.cj`；既有 `f_mq` 全量回归。
- 行为：候选节点顺序与去重结果不变；每次调用少 3.5 KB 堆分配（n=8）。
- 构建：不改 `cjpm.toml`。
