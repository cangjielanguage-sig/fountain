# Spec Delta

## Purpose

`f-jit-backend` 规定 `f_jit` 后端把字节码降低为本地机器码时必须维持的**栈与调用契约**：
x86_64 与 aarch64 均要求「调用外部入口时栈 16 字节对齐」，且该对齐必须**由控制流推导**，
不能由线性扫描的计数器推断（后者在分支汇合处会漂移）。

## ADDED Requirements

### Requirement: x86_64 调用点的栈深度由控制流推导

`X86Lower` SHALL 在降低前对函数字节码做控制流数据流分析，得到**每条指令入口处的操作数栈深度**；
降低每条指令前 SHALL 以该深度设定栈模型（不得沿用跨标签累加的线性计数）。

分析 SHALL 覆盖 `JMP` / `JZ` / `JNZ` / `LOOP_BACK` 与所有调用类指令的栈效应；
任一指令的栈效应无法判定时，该函数 SHALL 放弃 JIT 并退回解释器（不生成机器码）。

#### Scenario: 条件分支汇合后的 helper 调用（CastOr 失败路径）

- **WHEN** 编译并执行 `{ u: ReflectUser => u as ReflectAdmin ?? ReflectAdmin("fallback") }`，
  且实参为 `ReflectUser`（运行期转型不命中、走 `??` 兜底）
- **THEN** 调用返回 `fallback` 对象，进程不发生 SIGSEGV
- **AND** `{ u: ReflectUser => u as ReflectAdmin }` 在同样输入下以错误码 **7（BAD_CAST）** 失败

#### Scenario: 汇合深度不一致时退回解释器

- **WHEN** 某字节码偏移从不同前驱到达且推导出的栈深度不一致（构造性用例）
- **THEN** 该函数不生成机器码、退回解释器执行
- **AND** 结果 / 错误码 / site 与纯解释器路径逐位一致

### Requirement: 调用点的 16 字节栈对齐由推导深度决定

在 x86_64 上，所有 `CALL_HELPER` / `CALL_HOST` / `CALL_FUNC` / `CALL_CLOSURE` 调用点在执行
`call` 时 `rsp` SHALL 满足 16 字节对齐（`rsp % 16 == 0`）；补齐字节 SHALL 与推导深度同源，
并在调用返回后**对称撤销**（栈指针恢复到调用前）。

#### Scenario: 分支汇合点之后的调用序列

- **WHEN** 一段字节码在前向条件跳转后汇合，并在汇合分支内调用 `argc ≥ 1` 的 helper
- **THEN** 生成的机器码在该调用前插入的对齐补丁与「汇合点推导深度」的奇偶一致
- **AND** 调用返回后栈指针恢复，后续指令的深度与汇合点一致

#### Scenario: 两架构结果一致（回归）

- **WHEN** 同一单元（含上述 `CastOr` 形态）在 x86_64 与 aarch64 上分别执行
- **THEN** 结果 / 错误码 / site / 报告文本逐位一致（I7 不变）
