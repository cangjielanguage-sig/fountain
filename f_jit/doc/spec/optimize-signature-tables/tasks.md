# 任务：签名两表快照化（`optimize-signature-tables`）

> 纯实现优化（`skip_specs: true`）。编号 S = Signature tables。
> 环境：`ssh running@172.16.105.2`，`cd .../.worktrees/f_jit/f_jit`，`unset CJPM_CONFIG`。

## S1 基线

- [x] S1.1 复跑 `HostCallback(fn, sig)` 构造基准（临时探针，用后删除）：
      1 线程 ns/次、4 线程每 op、扩展比。已知参考值 **615 ns / 1174 ns / 0.52×**。
- [x] S1.2 分解测量（同一探针）：`SignatureRegistry.adapterOf`、`SignatureTable.getOrBuild`、
      `FunctionTypeInfo.of(fn)`（`probeType` 反射）三者各占多少 —— 用于确认改表能覆盖多少。

## S2 护栏（实现前后都必须绿）

- [x] S2.1 `SignatureRegistryVerification` 六条：
      - 同结构重复 `register` 返回同一 id（幂等）；
      - id 按登记顺序从 0 递增（稳定）；
      - `(User)->R` 与 `(Order)->R` 拿到**不同** id（**类名维度不能丢**）；
      - `find` 未登记 → `None`；`get(越界)` → `None`；
      - `adapterOf` 与 `find`+`get` 结果一致；
      - 并发：4 线程同时 `register` 不同签名 + 4 线程持续 `find`，无崩溃、id 无重复、`count` 等于唯一签名数。
- [x] S2.2 `SignatureTable` 四条：同签名只建一次（`buildCount` 不增）、`enabled=false` → `None`、
      `MAX_ENTRIES` 超限后仍返回计划且不再增长条目数、`resetForTest` 清空。
- [x] S2.3 现有用例先跑一遍留底：`JitHost_test` / `Signature*` / `Q6Acceptance_test`。

## S3 `SignatureRegistry` 快照化（base 包）

- [x] S3.1 新增 `SigSnapshot(entries: Array<HostSignature>)` —— **不用键索引**（D1 实测否决：
      349 → 790 ns），保留线性扫 `sameShape`，只去锁。
- [x] S3.2 `register`：写锁内 load → 查键 → 命中返回既有 id；未命中则复制数组追加 + 复制 map 加项 → store。
      **先填满再 store**。
- [x] S3.3 `find` / `adapterOf` / `get` / `count`：`load()` 后直接查，删锁。
- [x] S3.4 `resetForTest`：`store(empty())`。
- [x] S3.5 S2.1 六条 + `JitHost_test` 全绿。

## S4 `SignatureTable` 快照化（runtime 包）

- [x] S4.1 新增 `PlanSnapshot(plans: Array<SignaturePlan>, builds: Int64)`；同样只去锁、保留线性扫。
- [x] S4.2 `getOrBuild`：无锁读快照命中即返回；未命中在写锁内**双检**后新建并发布（超 `MAX_ENTRIES` 只加 `builds`、不追加）。
- [x] S4.3 `buildCount` / `entryCount` 读快照；`resetForTest` store 空快照并把 `builds` 归零。
- [x] S4.4 S2.2 四条全绿。

## S5 复测与判定

- [x] S5.1 A/B 同轮对比（旧/新各两轮）：单线程 524/280 → 456/252（−11%）；
      4 线程 1008/752 → 484/360（**−52%**）；扩展比 0.52×/0.37× → 0.94×/0.70×。
      目标 ≤200 ns 与 ≥1.5× **未达**，剩余争用是 `TypeInfo.of`（0.31–0.35×）。
- [x] S5.2 端到端：`Q6Acceptance_test` / `AnyBridgeCall_test` / `JitFunctionClosure_test` 全绿。
- [x] S5.3 判定：达标 **keep**；未达 MOV（8.4%）则 **revert** 并记录数据。

## S6 收口

- [x] S6.1 全量 `cjpm test --parallel 1` 零失败。
- [x] S6.2 `verify.md`；镜像 `f_jit/doc/spec/optimize-signature-tables/`；
      `openspec validate optimize-signature-tables --strict`；归档 `2026-11-27-optimize-signature-tables`。
- [x] S6.3 `doc/optimize-call-path.md` 增一节记录本次的数据与结论（该文档是调用路径优化的总账）。
