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
