# Spec Delta

## ADDED Requirements

### Requirement: 布尔逻辑非的编码可审计

AArch64 后端的 `NOT_B`（`0x5E`）SHALL 编码为 `EOR Xd, Xn, #1`，且 `Rd = Rn = 9`（`N=1`、`immr=0`、`imms=0`，机器字 `0xD2400129`）；x86_64 SHALL 为 `xor qword [rsp], 1`。两侧 SHALL 只翻转 bit0，SHALL NOT 读写其它寄存器或其它栈槽。机器字 SHALL 由 `A64Emitter` 的字段构造法（`eorImm1(rd, rn)`）生成，SHALL NOT 以裸字面量手写。该指令 SHALL 同时具备编码用例与语义用例。

#### Scenario: 编码逐位与位域

- **WHEN** 编译 `{ => !true }` 并取 `NOT_B` 对应的机器字
- **THEN** 三条指令依次为 `ldr x9,[x20]` / `0xD2400129`（小端字节 `290140D2`）/ `str x9,[x20]`，且解码出的 `Rn` 与 `Rd` 均为 9

#### Scenario: 只翻转 bit0

- **WHEN** 对一个值为 0 与一个值为 1 的布尔槽执行 `NOT_B`
- **THEN** 依次得到 1 与 0，其余位与相邻栈槽不变

#### Scenario: 字段构造而非裸字面量

- **WHEN** 用 `eorImm1(9, 9)` 生成该指令
- **THEN** 输出与 `objdump` 实测一致；实现文件中不再出现新增的 `0xD2…` 裸字面量

#### Scenario: 非原生架构不计证据

- **WHEN** 在非 x86_64 主机上检视 x86_64 的 `NOT_B` 断言
- **THEN** 用例被明确跳过并标记「无证据」，不记为通过

### Requirement: 一元 `!` 按操作数类型分派

`Lowerer` 的 `Bang` 分支 SHALL 按 `lowerExpr(x)` 的静态类型分派：`BOOL` 编译为 `NOT_B` 并返回 `BOOL`；`I64` 编译为 `BNOT_I` 并返回 `I64`；其余类型 SHALL 报 `TYPE_MISMATCH`。三引擎 SHALL 对同一源码给出逐位一致的结果。

语义基线：`!true == false`、`!2 == -3`、`!-1 == 0`、`!0 == -1`。

#### Scenario: Bool 操作数走逻辑非

- **WHEN** 编译并执行 `{ b: Bool => !b }`，`b` 取 `true` / `false`
- **THEN** 依次得到 `false` / `true`，且字节码含 `NOT_B`

#### Scenario: Int64 操作数走位反

- **WHEN** 编译并执行 `{ n: Int64 => !n }`，`n` 取 `2` / `-1` / `0`
- **THEN** 依次得到 `-3` / `0` / `-1`，且字节码含 `BNOT_I` 而非 `NOT_B`

#### Scenario: 三引擎逐位一致

- **WHEN** 同一批 `!` 用例在解释器、x86_64、AArch64 上执行
- **THEN** 结果逐位相同；非原生架构标记「无证据」而不计通过

#### Scenario: 非法类型拒绝

- **WHEN** 编译 `{ s: String => !s }`
- **THEN** 报 `TYPE_MISMATCH`，不生成机器码

