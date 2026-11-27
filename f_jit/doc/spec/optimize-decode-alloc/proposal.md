# 降低期不再逐指令解码分配

## Why

`A64Lower.lower` 与 `X86Lower.lower` 对每条字节码指令调用 `InsnDecoder.decode(code, off)`，
后者每次都 `Array<UInt8>(opsLen)` 新建操作数数组并逐字节拷贝。
本项目已多次实测「小数组分配」在本机约数百 ns：单元 250 条指令 ⇒ 250 次分配/编译。

`decode` 在降低期其实只提供两样东西：`op` 与 `size`（= `OpInfo.OPCODE_TABLE[op].len`），
而操作数可以按 `code[off + 1 + k]` 直读——`Assembler.validateFunc` 在
`optimize-compile-hotpath` 里已经这样改过，实测无副作用。

## What Changes

1. `A64Lower`：`translate(op, ops: Array<UInt8>, at, next)` →
   `translate(op, code: Array<UInt8>, opsAt: Int64, at, next)`；
   37 处 `u8/u16/i8/i32/u32/i64(ops, k)` 改为 `(code, opsAt + k)`。
   `lower` 循环改为 `op = code[off]`、`next = off + OpInfo...len`，不再 `decode`。
2. `X86Lower`：同构改造（36 处）；探针遍与发射遍都不再 `decode`，
   上一轮缓存的 `DecodedInsn` 数组随之删除（连解码都省了）。

**语义不变**：`decode` 在降低期的额外职责（RSVD/FORBID 拒绝、截断检查）在
`FbcReader.checkInstructionSet` 加载期已经做过；操作数读取的下标换算逐位一致
（`ops[k]` ≡ `code[off + 1 + k]`）。

## Impact

- 收益目标：降低期少 250 次小数组分配/编译（A64 与 x86 各一份）；
- 影响文件：`src/backend/A64Lower.cj`、`src/backend/X86Lower.cj`；
- 风险：73 处下标改写的机械错误由 `A64Emitter_test`（13 条期望机器字）、
  `X86Compile_test`（11 条）、`X86Lower_test`（50 条）、`Golden_test`（4 条）兜底；
- 已知教训：上一轮「TLS 成本」外推未兑现，本轮收益同样**以实测为准，不预设比例**。
