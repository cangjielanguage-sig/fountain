# 任务：候选节点预分配数组

> TDD：先建顺序/去重回归与基准（Red：旧写法 4,168 B/次）→ 抽出纯函数并改预分配数组（Green）→ 全量回归。
> 只改 `MQClient.cj` 的私有实现；公开 API 0 变化，不改编译选项。

## 1. 现状与测量

- [x] 1.1 探针：n=8 时堆 `ArrayList` 4,168 B/次、`@ local!` + 拷回 928 B/次、预分配数组 672 B/次（验证：探针三次重跑完全一致）
- [x] 1.2 确认 local `ArrayList<Int64>` 的 `contains` 无匹配重载；`toArray()` 返回 `Array<Int64> @ local!`，不能直接作为堆数组返回
- [x] 1.3 确认 `candidateNodes` 语义：owner 优先、各自去重、其余节点兜底（验证：`MQClient.cj:500-519`）

## 2. 回归网与基准（Red）

- [x] 2.1 新增 `f_mq/src/client/MQCandidateNodes_test.cj`：owner 在前、其余在后（验证：旧实现上通过）
- [x] 2.2 用例：preferred 内部重复、all 内部重复、all 与 preferred 交叉重复均只保留一个（验证：旧实现上通过）
- [x] 2.3 用例：空 preferred / 空 all / 双空（验证：旧实现上通过）
- [x] 2.4 分配基准：`F_MQ_BENCH=1` 时 n=8 重复 5000 次，断言新写法总量低于旧写法 1/2（验证：旧实现上为 Red：两者同分配）
- [x] 2.5 `cd f_mq && cjpm test --filter "*MQCandidateNodes*"` 行为用例全绿（验证：FAILED 0）

## 3. 实现（Green）

- [x] 3.1 抽出包内 `candidateNodesOf(preferred, all)`：预分配 `preferred.size + all.size`，前缀去重，返回切片（验证：2.1–2.3 保持通过）
- [x] 3.2 `candidateNodes` 改为取 `pool.aliveNodes()` / `ownership.ownersOf(topic)` 后转发（验证：行为不变）
- [x] 3.3 开启 `F_MQ_BENCH=1` 重跑基准（验证：新写法低于旧写法 1/2）

## 4. 回归与契约

- [x] 4.1 `cd f_mq && cjpm test` 连续两次全绿（验证：两次 Summary FAILED 0）
- [x] 4.2 `candidateNodes` 仍为私有、`MQClient` 公开方法无变化（验证：`git diff -- f_mq/src | rg "^[+-].*public"` 只命中新增测试类）
- [x] 4.3 既有 `MQClient` / `MQOwnershipCache` / `MQNodePool` 用例全通过（验证：按套件过滤运行）

## 5. 产物与提交

- [x] 5.1 `docs/LocalMode.md` 的 f_mq 行回写实测结论（验证：行内含 `预分配数组` 与 `672`）
- [x] 5.2 镜像 `openspec/changes/optimize-f-mq-candidate-nodes/` 到 `f_mq/doc/spec/optimize-f-mq-candidate-nodes/`，两份逐文件一致（验证：`diff -r` 仅差 `.openspec.yaml`）
- [x] 5.3 `openspec validate optimize-f-mq-candidate-nodes --strict` 通过（验证：输出 `is valid`）
- [x] 5.4 提交到 `feature/local-mode-f-mq-candidate-nodes`（验证：`git log -1 --stat` 只含预期文件）

## Workflow follow-up

- 推送 `feature/local-mode-f-mq-candidate-nodes`，合并回 `sts/1.3.x-LocalMode`，合并后再跑 `f_mq` 全量。
- 执行 `opsx:verify`，通过后 `opsx:archive` 并同步主规格。
