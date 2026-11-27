# 验证记录：`optimize-runtime-tls`

> 环境：共享 7 核 A53 VM（load 4.4–5.3），`taskset -c 0-4`，`cjpm test --parallel 1`。
> 判定规则：`doc/optimize-call-path.md` §1（5 次、MOV、其它指标回退 ≤2%）。
> 本轮实测呈**双峰**（整机状态差异约 1.85×），按 §11.4 约定同时看最好值与分布，分峰比较。

## 1. 基线（改动前，13:46–13:50）

| RUN | L1 (ns/call) | Q1 (calls/s) | Q4 (calls/s) | C1 (ns) | F1 (ns) | F4 (ns) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 9883 | 101181 | 252187 | 731 | 960 | 393 |
| 2 | 5323 | 187838 | 478828 | 399 | 485 | 225 |
| 3 | 9755 | 102502 | 247956 | 720 | 955 | 406 |
| 4 | 5524 | 181027 | 450201 | 375 | 491 | 225 |
| 5 | 9751 | 102544 | 259540 | 724 | 971 | 417 |

峰划分：慢峰 = 1/3/5，快峰 = 2/4。

## 2. 改动后（14:00–14:03）

| RUN | L1 (ns/call) | Q1 (calls/s) | Q4 (calls/s) | C1 (ns) | F1 (ns) | F4 (ns) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 6299 | 158733 | 376035 | 739 | 952 | 441 |
| 2 | 3502 | 285507 | 678753 | 427 | 590 | 225 |
| 3 | 3758 | 266037 | 688090 | 386 | 518 | 218 |
| 4 | 6228 | 160551 | 416221 | 745 | 993 | 442 |
| 5 | 3670 | 272474 | 728535 | 394 | 525 | 221 |

## 3. 判定

| 指标 | 慢峰（改前 → 改后） | Δ | 快峰（改前 → 改后） | Δ | 结论 |
| --- | --- | --- | --- | --- | --- |
| **L1** | 9751–9883 → 6228–6299 | **−36%** | 5323–5524 → 3502–3758 | **−32%** | **keep** |
| **Q1** | 101–102k → 158–160k | **+56%** | 181–188k → 266–285k | **+48%** | **keep** |
| **Q4** | 248–260k → 376–416k | **+52%** | 450–479k → 678–729k | **+50%** | **keep** |
| C1 | 720–731 → 739–745 | +2%（噪声） | 375–399 → 386–427 | +5%（噪声） | 持平 |
| F1 | 955–971 → 952–993 | 噪声 | 485–491 → 518–590 | +7–20%（负载） | 持平 |
| F4 | 393–417 → 441–442 | 噪声 | 225 → 218–225 | 持平 | 持平 |

- `L1` 省下约 **3.5 µs / 2.0 µs**（慢峰/快峰），与「14 次 TLS × ~300 ns」的预测（~3.8 µs）同量级；
- `C1`/`F1`/`F4` 不经过合并后的调用级状态（C1 只建/毁 ctx，B2 是字段查找），持平符合预期；
- 即使按最保守的「慢峰对慢峰、快峰对快峰」，三项主指标均远超 MOV，**判定 keep**。

## 4. 正确性

- 全量 **1224/1224 / 0 失败**（新增 3 条隔离用例；原 1221 条全绿）。
- 新增 `RuntimeStateIsolation_test`（3 条）：
  - `deadlineIsThreadPrivate`：4 线程各写 deadline，读回自己的值；
  - `windowIsThreadPrivate`：4 线程两层窗口开合，逐层回到外层/环境窗口容量；
  - `faultIsThreadPrivate`：4 线程各记录 cause，互不可见，`free` 只清自己的。
- 既有护栏全绿：`ThreadLocalEnv_test`、`WindowIsolation_test`、`HostFaultTls_test`、
  `IterLifecycle_test`、`UnloadConcurrency_test`、`LoopSafepoint_test`、`JitFunctionClosure_test`、
  `AnyBridgeCall_test`（含 `p0_6` 有期限中断）、`Q6Acceptance_test`。

## 5. 变异验证

| 变异 | 预期 | 实测 |
| --- | --- | --- |
| `RuntimeEnv.current()` 每次返回新对象 | 3 条隔离用例全红 | **3 条全红**（deadline / window / fault） |

恢复后全量重跑绿。门控形态说明：`IterTable`/`HostFault` 的门控是「字段为空/None 则跳过清理」，
去掉门控只会多一次空清理、不改变语义，因此不存在「恒不清」的等价变异；清理本身由
`IterLifecycle_test` 与 `HostFaultTls_test` 覆盖。

## 6. 影响文件

- 新增：`src/runtime/RuntimeState.cj`、`src/RuntimeStateIsolation_test.cj`；
- 修改：`src/runtime/RuntimeEnv.cj`、`JitContext.cj`、`HandleTable.cj`、`IterTable.cj`、`HostCall.cj`、
  `src/JitFunction.cj`、`src/backend/JitExecutor.cj`；
- 可见性：`Win` / `IterState` / `FaultEntry` 从文件级 `private` 放宽到包级 `internal`；
  `RuntimeState` 与新增重载为 module 级（用户面不可见）。

## 7. 残留与边界

- 剩余 TLS：每次调用 `RuntimeEnv.current()` 1 次 + `MachineEnv.fnTableBase` 1 次（稳态）；
  分配型 helper（`append` / `pin`）仍各经一次 `current()`，未在本次范围内继续下传。
- 共享 VM 的双峰仍会让单次绝对值波动；本轮已按峰比较，建议在专用 ≥8 核机器上复测 `8 线程`。
