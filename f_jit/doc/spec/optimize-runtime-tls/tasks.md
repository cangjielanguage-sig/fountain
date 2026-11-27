# 任务：线程私有运行期状态合并（`optimize-runtime-tls`）

> 纯内部布局重构（`skip_specs: true`）。编号 T = Thread-local state。
> 环境：`ssh running@172.16.105.2`，`cd .../.worktrees/f_jit/f_jit`，`unset CJPM_CONFIG`。
> 硬规则：先基线、一次一项、5 次中位数、MOV = `max(3%, 2d)`；达不到就回滚。

## T1 基线（不改产品代码）

- [x] T1.1 复跑 `CallPathBench_test` 5 次（`taskset -c 0-4`）：`L1` 双峰 **9883/5323/9755/5524/9751 ns**；
      `Q1` **101181/187838/102502/181027/102544**；`Q4` **252187/478828/247956/450201/259540**；
      `C1` **731/399/720/375/724**。慢峰/快峰相差约 1.85×（整机状态，不是随机噪声）。
- [x] T1.2 临时探针（用后删除）：`ThreadLocal` get 319 / set 304 ns；`realTlsBundle` 6 次 = 1906 ns；
      `windowBundle` = 1888 ns；`ftiOf` 4 线程 0.38×。与 2026-11-27 数据同量级。
- [x] T1.3 `JitFunction.call` 的 TLS 访问清单：deadline 3、fnTable 3、win 5、iter 1、fault 1 = **14 次**；
      推算 **~4.4 µs / 8.6–9.7 µs（45–51%）**。

## T2 护栏（实现前后都必须绿）

- [x] T2.1 既有护栏先跑一遍留底：`ThreadLocalEnv_test`、`WindowIsolation_test`、`HostFaultTls_test`、
      `IterLifecycle_test`、`UnloadConcurrency_test`（全量基线 1221/1221）。
- [x] T2.2 新增 `RuntimeStateIsolation_test`（3 条）：deadline / 窗口栈 / 异常旁路各线程可见性。
      **旧实现上先跑绿**（1224 total，3 passed）。
- [x] T2.3 重入由既有 `JitFunctionClosure_test`（闭包回调重入）与 `AnyBridgeCall_test.p0_6`
      （有期限中断）覆盖；本变更不重复造同类用例。
- [x] T2.4 门控改为**字段检查**（`rs.iters` 为空 / `rs.faults` 为 None）而不是新增 ctx flags 位；
      语义由 `IterLifecycle_test` / `HostFaultTls_test` 覆盖。

## T3 `RuntimeState` + `RuntimeEnv`（新增文件）

- [x] T3.1 新增 `src/runtime/RuntimeState.cj`：deadlineNanos / fnTableBase / wins / iters / faults / freeHint；
      `Win` / `IterState` / `FaultEntry` 放宽到 `internal`。
- [x] T3.2 `RuntimeEnv` 增 `stateTls` + `public static func current()`；公开 deadline API 内部改读字段。
- [x] T3.3 `MachineEnv.fnTableBase` 改读字段（公开 API 不变）。
- [x] T3.4 T2.1 + T2.2 全绿。

## T4 `HandleTable` 一次返回窗口上下界

- [x] T4.1 新增 `openWindowWith(rs, cap) -> (base, cap)`；`openWindow(cap)` 保留转调。
- [x] T4.2 新增 `resetWindow(rs, keep)`、`syncTo(ctx, rs)`；旧签名保留转调。
- [x] T4.3 `JitFunction.call` 改用新 API，win 侧 5 次 TLS → 0。
- [x] T4.4 `WindowIsolation_test` / `HandleTable*_test` 全绿。

## T5 `JitContext.create` 参数化 deadline

- [x] T5.1 `create` 增 `deadlineNanos!: ?Int64 = None`（None 时回读 TLS，兼容测试直调）。
- [x] T5.2 `JitFunction.call` 传 `Some(rs.deadlineNanos)`，并改为「值不变不写」的条件协议。
- [x] T5.3 `LoopSafepoint_test` / `AnyBridgeCall_test.p0_6` 全绿（全量 1224/1224）。

## T6 `IterTable` / `HostFault` 字段门控

- [x] T6.1 不新增 ctx flags 位；`RuntimeState` 字段本身即门控（健康路径字段为空/None）。
- [x] T6.2 `IterTable.state()` 改读 `rs.iters`；`clearAll(rs)` 在空表时直接返回。
- [x] T6.3 `HostFault` 全部方法改读 `rs.faults`；`clearWith(ctx, rs)` 由 `JitContext.free(ctx, rs)` 调用。
- [x] T6.4 `IterLifecycle_test` / `HostFaultTls_test` / `HostCallTrampoline_test` 全绿。

## T7 `JitExecutor` 条件 set

- [x] T7.1 `invokeOff` 仅在 `fnTableBase` 变化时 set/restore（稳态 3 次 → 1 次 get）。
- [x] T7.2 `JitFunctionClosure_test` / `Q6Acceptance_test` 全绿。

## T8 复测与判定

- [x] T8.1 A/B 5 次（同机、同任务、`taskset 0-4`）：
      **慢峰 L1 9751–9883 → 6228–6299 ns（−36%）**；**快峰 5323–5524 → 3502–3758 ns（−32%）**；
      Q1 +48–56%、Q4 +50–55%；C1/F1/F4 在噪声内。
- [x] T8.2 判定 **keep**（L1/Q1/Q4 远超 MOV）。

## T9 变异验证

- [x] T9.1 `RuntimeEnv.current()` 改为每次返回新对象 ⇒ `RuntimeStateIsolation_test` **3 条全红**
      （deadline / window / fault）。已恢复。
- [x] T9.2 单例化与 T9.1 等价（都会让「每线程独立」失效），不再重复注入。
- [x] T9.3 门控是「字段为空则跳过」：去掉门控仍是正确语义（只是多一次空清理），
      因此不存在「恒不清」的变异形态；由 `IterLifecycle_test` 覆盖清理本身。

## T10 收口

- [x] T10.1 全量 `cjpm test --parallel 1` **1224/1224 / 0 失败**。
- [x] T10.2 `verify.md`；镜像 `f_jit/doc/spec/optimize-runtime-tls/`；
      `openspec validate optimize-runtime-tls --strict`。
- [x] T10.3 `doc/optimize-call-path.md` 增 §16，并在 §12.4 标注已被 §16 推翻。
- [x] T10.4 归档 `2026-11-27-optimize-runtime-tls`；提交并推送 `sts/1.3.x-LocalMode`。
