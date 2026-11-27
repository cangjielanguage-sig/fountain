# 编译路径并发优化（数据驱动）

> 状态：**全部完成并归档**：M0（C3 取消）、C0（并发编译缺陷修复）、C1、C2 均已落地。
> 关联：`doc/optimize-call-path.md`（调用路径已收口）、`doc/design-parallel-call.md`。

## 0. 已测事实（2026-11-27）

4 线程各编译 6 段**不同**源码，3 次运行（共享 7 核 A53、load 3+）：

| 配置 | 单线程 | 4 线程每编译 | 扩展比 |
| --- | --- | --- | --- |
| 各线程独立 `Compiler` | 0.41–0.70 ms | 0.33–0.52 ms | **1.23× / 1.30× / 1.35×** |
| 共用一个 `Compiler` | 同上 | — | **1.46× / 1.46× / 1.70×** |
| `JitMode.Off`（纯字节码） | 0.67–0.94 ms | 0.25–0.34 ms | **2.68× / 2.76× / 3.71×** |

结论：
- 共享 `Compiler` 不比独立 `Compiler` 慢 ⇒ `Compiler.mtx` / `ClassRegistry.mtx` 不是瓶颈；
- 关掉 JIT 发射后扩展比翻倍 ⇒ 限制在**产物形态**（代码发射 / 可执行内存），不在前端；
- `CompileCache`、`HostFieldTable.writeMtx`、`PromotionGroup`、`NativeMem` 均不在编译路径上或只占短临界区。

## 1. 目标与非目标

**目标**：把「多线程编译不同代码」的 4 线程扩展比从 1.3–1.7× 提到 ≥2.0×（本机 4 线程上限 2.2–2.4×）。

**非目标**：
- 不改前端语法/语义、不改编译产物；
- 不引入第三方依赖；
- 不为「零锁」而改公开 API。

## 2. 工作项（按执行顺序）

### M0 测量：一次编译里 mmap/mprotect 的次数与耗时占比（**先只测不改**）

- 目的：确认 C3（代码缓冲池化）是否值得立项。
- 做法：临时在 `CodeBuffer.alloc` / `seal` 加计数器与计时（用后删除），
  用探针编译 12 段不同源码，输出：
  - 每编译 `mmap` 次数、`mprotect` 次数、总字节；
  - `CodeBuffer` 段耗时占 `Compiler.compile` 的比例；
  - 4 线程下该占比是否放大。
- 判定：
  - 若 `mmap+mprotect` 占单次编译 **≥15%** 或 4 线程下占比 ≥25% ⇒ 立 C3；
  - 否则 C3 不做，只做 C1/C2。
- 环境限制：构建机**没有 strace**（已确认），只能用进程内计数。

### C1 `CompileCache.awaitReady` 改指数退避（消除对其它 key 的锁抢占）

- 现状：`awaitReady` 自旋最多 500 万次，**每轮都 `synchronized(mtx)`**；同 key 的等待者会持续抢
  全局缓存锁，间接拖慢其它 key 的 `claim/finish`。
- 改法（不依赖已废弃的 `Monitor`）：纯 CPU 退避 + 批量检查。
  - 每次检查后空转 `backoff` 次再查；`backoff` 从 64 起翻倍到 8192；
  - 总等待预算改为**墙钟**（如 30 s），不再用迭代次数；
  - 检查仍走 `mtx`，但单位时间取锁次数下降约 3 个数量级。
- 判定：等待者存在时，其它 key 的 `claim+finish` 延迟下降 ≥30%（微基准）；同 key 正确性用例全绿。
- 风险：等待粒度变粗（最坏 8192 次空转 ≈ 数十 µs），对 0.7 ms 级编译可忽略。

### C2 `Compiler.snapshot()` 缓存

- 现状：每次编译在 `this.mtx` 内遍历全部已注册函数，构造 `PredefinedSnapshot`（O(F) 拷贝）。
- 改法：`Compiler` 内缓存快照；`registerFunction/unregisterFunction/registerClass/registerType/
  registerInterface` 时置空。共享 `Compiler` 的多线程编译只读缓存。
- 判定：共享 `Compiler` 的 4 线程扩展比提升 ≥10%，或单编译 `snapshot` 占比降至 <3%。
- 风险：注册与编译并发时可能拿到旧快照 —— 与现状「注册不影响已编译产物」一致；
  但**同一线程注册后立即编译**必须看到新注册（用失效标记保证）。

### C3 代码缓冲池化 / 预分配（**条件项**，M0 支持才做）

- 目标：减少每单元 `mmap` + `mprotect`（W^X 切换）的次数。
- 候选：
  1. 页池：一次 `mmap` 大块，按单元切片分配，`mprotect` 按页批量切换；
  2. 代码缓冲复用：`JitFunction.close()` 归还缓冲，新编译优先复用（需清零与审计）；
  3. 按尺寸分级（小单元占多数）。
- 前提：M0 数据达标；W^X 与生命周期（`close` 后不得执行）需单独立规格。
- 判定：4 线程编译扩展比 ≥2.0×，且全量回归零失败。

## 3. 测量协议

- 每项改动前后各跑 5 次，取中位数与最好值；MOV = `max(3%, 2×离散度)`；
- 编译耗时用「4 线程各 6 段不同源码」的固定探针（源码带唯一 seed，避免缓存命中）；
- 其它指标（重复编译同一源码、单编译延迟）回退 ≤2%；
- 全量 `cjpm test --parallel 1` 零失败才保留。

## 4. 决策日志（实施时填写）

| 日期 | 项 | 指标 | 基线 → 改动后 | Δ | 决策 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-27 | 基线 | 4 线程编译扩展比 | — | 1.23–1.70×（JIT）/ 2.68–3.71×（Off） | 参考值 | 共享 VM，3 次 |
| 2026-11-27 | M0 | mmap+mprotect 占单次编译 | 16 237 ns / 687 035 ns = **2.4%**（1 线程）；32 109 ns / 547 102 ns = **5.9%**（4 线程） | — | **C3 不立项** | 每编译恰 1 次 mmap + 1 次 mprotect（4 KiB）；远低于 15% 门槛 |
| 2026-11-27 | C1 | 同 key 等待者对其它 key 的 claim+finish 延迟 | 187 071 → **3 003 ns/次** | **−98.4%** | **keep** | 退避 1 µs→500 µs；墙钟预算 30 s；T17 与全量 1206/1206 |
| 2026-11-27 | C0 | 并发编译崩溃 | 4 线程共享 Compiler 抛 `IndexOutOfBoundsException` | — | **修复** | `A64Emitter.auditMemBases` 改 ThreadLocal；确定性用例旧实现必红 |
| 2026-11-27 | C2 | snapshot 占比 / 4 线程每编译 | 41.5% / 813 µs → 0% / **584 µs**（−28%）；扩展比 1.53× → 1.84× | **−28%** | **keep** | F=200；注册/注销全失效；2 条语义用例 |
| | C3 | 4 线程扩展比 | | | | |

## 5. 停止条件

- M0 显示 mmap 占比 <15% ⇒ C3 不做，改用 profile 另找热点；
- C1/C2 连续两项未达门槛 ⇒ 停止编译路径优化，记录数据。

## 6. M0 结论与 C3 取消（2026-11-27）

临时给 `CodeBuffer.alloc` / `seal` 加计数与计时（用后已删除），1 线程 12 次编译、4 线程 48 次：

| | mmap 次数 | mmap 总耗时 | mprotect 总耗时 | 单编译占比 |
| --- | --- | --- | --- | --- |
| 1 线程 | 12（1 次/编译） | 97 188 ns | 97 657 ns | **2.4%**（16.2 µs / 687 µs） |
| 4 线程 | 48（1 次/编译） | 751 568 ns | 789 689 ns | **5.9%**（32.1 µs / 547 µs） |

结论：**代码缓冲的 mmap/mprotect 只占 2.4%–5.9%，C3（池化）不值得做**，按 §2 的判定门槛取消。
因此 1.3–1.7× 的扩展比限制不在这条路径上；剩余候选（GC / 分配器 / codegen 内部共享状态）
需要专用机 + profile，本机无 `perf`、无 `strace`，不再盲猜。

## 7. C1 结果（2026-11-27）

| | 其它 key 的 claim+finish |
| --- | --- |
| 改动前（自旋 500 万次 + 每轮取锁） | 187 071 ns/次 |
| 改动后（墙钟退避 1 µs→500 µs） | **3 003 ns/次** |

−98.4%。等待者不再饿死其它 key；`T17`（同 key 管线只跑一次）与全量 1206 条全绿。

## 8. C0 与 C2 结果（2026-11-27）

### C0：测量中撞出的并发正确性缺陷（已修）

C2 的 4 线程对照用例抛 `IndexOutOfBoundsException`（`A64Emitter.noteMemBase` 的 `ArrayList.add`）：
`auditMemBases` 是**进程级**列表，并发编译既会越界，`reset` 又会清掉别的编译的审计项。
改为 `ThreadLocal`（审计生命周期 = 一次 `compileOnce`）。确定性用例
`A64AuditIsolation_test` 在旧实现上必红；压力用例 `CompileConcurrency_test` 覆盖 4 线程共享 Compiler。

**这是本次编译路径调查里最重要的产出**：并发编译在 aarch64 上原本是不安全的。

### C2：`snapshot()` 缓存（keep）

| 场景 | snapshot 占比 | 每编译 |
| --- | --- | --- |
| F=200，1 线程 | 11.6% | 1 247 → 1 076 µs（−13.7%） |
| F=200，4 线程共享 | **41.5%** → 0% | 813 → **584 µs（−28.2%）** |

4 线程扩展比 1.53× → **1.84×**。注册/注销全部失效，2 条语义用例锁定。

## 9. D1 分支回填索引化（2026-11-27，`optimize-emit-fixup`）

### 9.1 分段：编译延迟的大头不在前端

200 注册函数 × 50 调用点（`unit.dir.size = 1`，字节码 1230 B，机器码 9644 B）：

| 阶段 | 实测（改前） | 占单次编译 |
| --- | --- | --- |
| `JitExecutor.create` | 37.72 ms | 87% |
| `A64Emitter.finishOrNull`（插桩 16 次采样） | **33.42–52.95 ms** | 78–92% |
| `A64Lower.lower` | 1.33–1.79 ms | 3–4% |
| 前端 `SourceCompiler.compile` | 5.43–5.55 ms | 13% |

**根因**：`A64Emitter.labels` 是 `ArrayList`，`labelOffset` 线性扫全表；
`A64Lower` 对每个字节码偏移 `bind('L${off}')`，标签数与指令数同阶；
`finishOrNull` 对每条重定位查一次，`finish` 再查一次 ⇒ 约 2 × R × L 次字符串比较。
单函数 2411 条指令要 33–53 ms，即约 15 µs/指令。

### 9.2 改动

1. `labels` 改 `HashMap<String, Int64>`；`bind` 首次绑定优先（保留旧语义），`labelOffset` O(1)。
2. `finishOrNull` / `finish` 合并为单遍 `resolve(checkRange:)`，校验与回填一次完成。
3. 删除只服务于线性扫的 `A64Label`。

x86 侧 `X86Lower` 本来就是这个结构（`HashMap<String, Int64>` + 单遍 `finish`），
本次是把 A64 对齐到 x86，不是新设计。

### 9.3 数据

| 指标 | 改前 | 改后 | Δ |
| --- | --- | --- | --- |
| 端到端 `compile + load + create` | 44.32 / 24.06 / 45.07 ms | **11.06 / 11.10 / 6.42 ms** | **−85.5%（最优配对）** |
| `JitCompiler.compileUnitWith` | 37.72 ms | 2.62 / 5.11 / 2.77 ms | **−93.1%** |
| 逐函数发码 `perFnSum` | 35.34 ms | 1.39 / 2.56 / 1.45 ms | **−96.1%** |

护栏 `A64EmitterFixup_test` 4 条（改前先全绿，证明测的是既有语义）；
变异 A（`bind` 总覆盖）⇒ `firstBindWins` 红，变异 B（恒按 imm26 回填）⇒ `conditionalKindsUseImm19` 红。
全量 1239/1239。

### 9.4 剩余

| 项 | 改后占比 | 说明 |
| --- | --- | --- |
| 前端 `SourceCompiler.compile` | ~45% | `assemble` / `parse` / `lower` / `load` 均为真实工作量，需再分段才谈得上优化 |
| `compileUnitWith` 的逐字节拷贝 | ~19% | `for (x in b) out.add(x)`，可改 `add(all)` 或预分配，独立变更 |
| `A64Lower.lower` | ~13% | 1.3–1.8 ms，未 profile 到具体分支 |

## 10. D2 批量搬运与 x86 单次解码（2026-11-27，`optimize-compile-copy`）

### 10.1 改前分段（插桩）

| 位置 | 实测 | 原因 |
| --- | --- | --- |
| `Assembler.build`（CRC + 四段拼接） | **0.82–1.45 ms** | 同样 1.9 KB 载荷被搬四趟：CRC 的 `ArrayList`、`toArray`、`wBytes` 逐字节、`take` |
| `Assembler.layout` | 0.44–0.74 ms | 函数体 `for (k in 0..size) body[k] = code[k]` |
| `Assembler.validate` | 0.27–0.69 ms | 逐指令栈校验（真实工作量） |
| `JitCompiler.compileUnitWith` | 含在 2.62 ms 内 | 逐字节 `out.add(x)` + `toArray()`，9.6 KB 搬两趟 |
| `JitExecutor.create` | 含在 3.07 ms 内 | `seal()` 之后又 `flushICache()` 一次（对整页重复刷新） |
| `FbcReader.load` | 0.75–0.82 ms | head 0.15 / slices 0.15 / dir 0.20 / constSite 0.24 |

### 10.2 改动

1. `JitCompiler.compileUnitWith`：两遍（先收集字节与总长，再一次性分配下标写入）。
2. `FbcWriter`：新增 `payload()` 一次拼出四段；`build()` 用同一份载荷算 CRC 并与头拼接。
3. `Assembler` 函数体改 `clone()`。
4. `JitExecutor.create` 删掉 `seal()` 之后重复的 `flushICache()`。
5. `X86Lower.lower`：探针遍缓存 `DecodedInsn` 与偏移，发射遍复用（少一半解码与操作数数组分配）。

### 10.3 数据

端到端 `compile + load + create`（同探针，`git stash` 切臂，每次 5 轮取最小）：

| 臂 | 结果（ms） | 中位数 |
| --- | --- | --- |
| 改前 | 12.20 / 7.27 / 12.31 | **12.20** |
| 改后 | 9.92 / 10.05 / 6.20 / 10.01 / 10.14 | **10.01** |

**中位数 −18.0%**，最优配对 −14.7%。

护栏 `CompileCopy_test`（整单元 == 逐函数拼接，A64/x86 双架构有效）：
改前、改后均绿；变异 `lens[i] = size - 1` ⇒ 红。
`Golden_test` 4/4、`X86Compile_test` 11/11、`X86Lower_test` 50/50；全量 1241/1241。

### 10.4 剩余（下一次要动就要先测）

| 项 | 改后占比（估） | 备注 |
| --- | --- | --- |
| 前端 `assemble`（validate 0.3–0.7 + encode） | ~15% | validate 是逐指令栈校验，要优化得先看它内部 |
| `FbcReader.load` | ~12% | 切片 + 三张表解码，均为最小形态 |
| `A64Lower.lower` | ~20% | 1.3–1.8 ms，尚未 profile 到具体 opcode 分支 |
| `Assembler.validate` | ~10% | 同上 |

## 11. D3 发射器按字存储 / `validate` 免解码 / CRC 预分配（2026-11-27，`optimize-compile-hotpath`）

### 11.1 改前分段（插桩，250 条指令、9432 B 机器码）

| 位置 | 实测 |
| --- | --- |
| `A64Lower.lower` 的 `translate` | 1.41–1.65 ms |
| `A64Lower.lower` 的 `bind + decode` | 0.67–0.72 ms |
| `Assembler.validateFunc` 的 `decode` | 0.21–0.23 ms |
| `FbcReader.checkCrc32` | 0.15–0.53 ms |
| `FbcReader` 的 `dir+types` / `site+name` / 切片 | 0.24 / 0.30 / 0.17 ms |

### 11.2 改动

1. `A64Emitter.out` 由 `ArrayList<UInt8>` 改 `ArrayList<UInt32>`：`word()` 一次 `add`；
   `size()` 仍返回字节（`words*4`），`finish()` 新增 `bytes()` 一次展开。
2. `Assembler.validateFunc` 不再 `InsnDecoder.decode`：`op`/`size` 取自 `info`，操作数直读 `code[off+1+k]`。
3. `FbcReader.checkCrc32` 改预分配数组，去掉 `ArrayList` + `toArray` 两趟。

### 11.3 数据（同进程中位数；该机双峰，单次端到端不可判）

| 阶段 | 改前 | 改后 | 快模式配对 | 慢模式配对 |
| --- | --- | --- | --- | --- |
| `codegen` | 3.731 / **2.322** / 3.743 | 3.766 / 3.608 / **2.157** | **−7.1%** | −1.3% |
| `load` | 0.973 / **0.499** / 0.913 | 0.902 / 0.908 / **0.493** | −1.2% | **−7.3%** |
| `front` | 4.707 / 2.448 / 4.640 | 4.336 / 4.285 / **2.441** | −0.3% | **−8.1%** |

三个维度在两个模式下都没有退化，折算单次编译 **−0.2~0.5 ms（−3~5%）**。
判定 **keep（边际）**——收益明显小于 D1/D2，价值主要在消除结构性浪费。

护栏：新增 `A64EmitterSize_test` 3 条（字节口径/小端展开/分支偏移），
改前先绿；变异「`size()` 少乘 4」⇒ 2 条红。
`A64Emitter_test` 13/13、`Golden_test` 4/4、`CompileCopy_test` 1/1；全量 1244/1244。

### 11.4 下一步线索（都必须先单独测）

1. **审计表去 TLS**：`A64Emitter.strOff/ldrOff` 每次内存操作 `auditTls.get()`；
   本项目早前实测 `ThreadLocal.get` ≈300 ns，每函数约 1000 次 ⇒ 约 **0.3 ms**。
   审计生命周期 = 一次 `compileOnce`，改成发射器实例字段即可。
2. **`bind('L${off}')`**：250 次/函数的字符串拼接 + 哈希插入，可改惰性绑定或整数偏移键。
3. **`InsnDecoder.decode` 的操作数数组**：`A64Lower`/`X86Lower` 仍每指令分配一次，
   要消除需把 `translate` 的 `ops` 参数改成 `(code, off)` 直读。

## 12. D4 审计表随发射器实例（2026-11-27，`optimize-emit-audit`）

### 12.1 改动

`A64Emitter.auditTls`（`ThreadLocal<ArrayList<Int64>>`）→ 实例字段 `audit: ArrayList<Int64>`；
`noteMemBase` / `resetAudit` / `auditSnapshot` 由静态改实例；`auditAllows` 保持静态纯函数。
`A64Compiler.compileOnce` 改用 `e.resetAudit()` / `e.auditSnapshot()`。

审计生命周期本就等于一次 `compileOnce`（每次编译新建发射器），实例字段天然隔离。

### 12.2 数据：**未测得收益**

`JitCompiler.compileUnitWith` 同进程 21 次中位数：

| 臂 | 各进程（ms） | 快模式配对 | 慢模式配对 |
| --- | --- | --- | --- |
| 改前 | 3.539 / **2.128** / 3.552 | — | — |
| 改后 | **2.165** / 3.395 | +1.7% | −4.4% |

598 次 TLS get × 约 300 ns ≈ 180 µs（预期 −8%）**没有兑现**：两个模式方向相反，差异在噪声内。
改动保留的理由是「严格更少工作 + 审计生命周期显式化」，不宣称加速。

**教训**：跨场景外推微基准的单项成本（TLS get）不可靠；动热点前应对该入口做同进程 A/B。

护栏：`CompileConcurrency_test`、`EmitAudit_test`（改实例 API，断言不变）、
`A64AuditIsolation_test`（改为双实例隔离，新增「对方那份不受影响」）、
`A64Emitter_test` 13/13、`Golden_test` 4/4；全量 1246/1246。
