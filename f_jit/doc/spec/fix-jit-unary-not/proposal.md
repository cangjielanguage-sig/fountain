# Proposal

## Why

宿主在脚本里写一元逻辑非后拿到相反的答案：`{ n: Int64 => !(n < 50) }` 在 `n = 49` 时 JIT 返回 `true`、解释器返回 `false`（`false` 才是语义期望）。这不是「某个边界值算错」，而是 **AArch64 后端的 `NOT_B` 从未真正执行逻辑非**——它对 `X0`（ctx 指针）取反，结果恒非零，桥再以「非零即真」解包，于是任何 `!expr` 在 JIT 上都恒为 `true`。所有写一元 `!` 的调用方（含 `!~` 正则不匹配、`!!x`、`!flag`）在 AArch64 上全部被静默答成 `true`。

根因已由位域解码确认，落在 `f_jit/src/backend/A64Lower.cj:324`：

```
this.e.word(0xD2400009u32) // eor x9,x9,#1（逻辑非；0↔1）
```

`0xD2400009` 的 `Rn` 字段（bit 9–5）是 `00000`，即 **`EOR X9, X0, #1`**，不是注释所写的 `EOR X9, X9, #1`（后者应为 `0xD2400129`）。`X0` 在序言 `movReg(19, 0)` 之后仍是 ctx 指针且该函数体不再写它，所以 `X9 = ctx | 1` 恒非零；写回操作数栈后 `RET` 把它当布尔返回。

此前把 A64 `0x5E` 排除，依据是源码行尾注释与「`eor x9,x9,#1` 并写回」的字形，**不是编码位域**——这正是本条缺陷能穿过既有全量用例的原因：`A64Lower` 没有单测，`0x5E` 也没有任何跨引擎语义用例，唯一相关用例是解释器的栈纪律（A1.2）与 x86 的字节断言。

## What Changes

- **修编码**：`A64Lower` 的 `0x5E` 改为 `EOR X9, X9, #1`（`0xD2400129`），并改由 `A64Emitter.eorImm1(rd, rn)` 以字段构造生成，不再手写裸字面量。
- **加红用例（先红后绿，严格 TDD）**：
  - 语义层：新增一元 `!` 的三引擎差分用例，**同时**断言「解释器结果 = 语言语义的绝对期望值」与「全部可用引擎四元组逐位一致（I7）」；矩阵覆盖比较、布尔字面量、布尔实参、双重取反、`&&`/`||`、正则 `!~`，边界取 49/50 与 Int64 极值。
  - 编码层：新增 `NOT_B` 三字断言（`ldr x9,[x20]` / `0xD2400129` / `str x9,[x20]`）与 `eorImm1` 的位域断言。
  - 形状层：新增 AST 与字节码形状断言（`Unary(Bang, …)` → `… LT_I; NOT_B; RET`），把「前端错」与「后端错」在一次失败里分离。
- **不改**：Parser / Lexer / Lowerer 的既有行为（已证伪，见 design §2.2）；`.fbc` 格式；公开 API；错误码；既有正确语义。
- **文档回写**：`design-m1.md:1528` 与 `jit-bytecode-m1.md:2132` 把 A64 的 `NOT_B` 写成 `ldr x11…`，实现是 `x9`，随本次订正。

## Capabilities

### New Capabilities

（无。）

### Modified Capabilities

- `f-jit-backend`：新增「布尔逻辑非的编码可审计」——`NOT_B` 的机器字、位域、构造方式与被允许的副作用。
- `f-jit-differential-acceptance`：新增「一元逻辑非的三引擎差分回归」——绝对值锚定 + 四元组逐位一致 + 生产者矩阵。
- `f-jit-compiler-frontend`：新增「一元逻辑非的产物形状可断言」——把前端形态固化为可回归判据，供定位分层。

## Impact

- **代码**：`f_jit/src/backend/A64Lower.cj`（`0x5E` 分支）、`f_jit/src/backend/A64Emitter.cj`（新增 `eorImm1`）。不改 `X86Lower`（`48 83 34 24 01` = `xor qword [rsp],1`，已逐字节核对正确）、不改 `Interp`（`a == 0`）。
- **测试**：新增 `f_jit/src/compiler/UnaryNotDiff_test.cj`（三引擎语义）、`f_jit/src/backend/A64NotBEncoding_test.cj`（编码与位域）、`f_jit/src/compiler/UnaryNotShape_test.cj`（AST + 字节码形状）。
- **产物与兼容**：同一源单元前后只差 `NOT_B` 的 4 个机器字节；字节码、verMajor、规则集、helper 编号、缓存键全部不变。
- **性能**：指令条数与访存次数不变（3 条 → 3 条）。
- **平台证据**：本机最小集 `Interp × AArch64` 可直接判定本缺陷；x86 侧按既有条件用例在原生 x86_64 上给出证据，非原生标「无证据」，不计通过。
- **不在本次范围**：`!` 操作数的 Bool 类型收口（当前 `!2` 三引擎本就分歧，属独立缺陷面，见 design §7 已知边界 B1）；0x50–0x6E 段的全面重编码审计（仅做本段抽样，见 tasks B6）；`BackendSelector` 的历史路径（已委派到 `A64Compiler`，无独立实现）。
