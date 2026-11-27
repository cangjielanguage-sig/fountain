# 设计：降低期直读操作数

## 1. 下标换算

`InsnDecoder.decode` 的 `operands[k] = code[off + 1 + k]`，`opsLen = len - 1`。
因此把 `opsAt = off + 1` 传下去后：

```
u8(ops, k)  ≡ u8(code, opsAt + k)
u16(ops, k) ≡ u16(code, opsAt + k)
```

`A64Lower` / `X86Lower` 的六个读取助手本来就是 `(bs: Array<UInt8>, at: Int64)`，
签名不用动，只是实参从 `ops` 换成 `code`、下标加 `opsAt`。

## 2. 指令长度

`next = off + Int64(OpInfo.OPCODE_TABLE[Int64(op)].len)`，与 `decode` 的 `info.len` 同源。

## 3. 为什么可以跳过 decode 的检查

`decode` 会在 RSVD/FORBID 与操作数截断时报错。降低期的输入来自 `FbcReader.load`，
其中 `checkInstructionSet` 已逐指令校验过同一张 `Opcode` 表；截断也已在加载期拒绝。
`Assembler.validateFunc`（编译前端）同样先查 `info.cat` 再读操作数，路径一致。

## 4. x86 的额外简化

上一轮 `X86Lower` 已把 `DecodedInsn` 缓存进数组以避免二次解码；本轮连第一次解码也不需要，
因此**删除该缓存**（`insns` / `offs` 两个数组），每遍直接 `op = code[off]`。

## 5. 护栏与判定

- 字节级：`A64Emitter_test`（13）、`X86Compile_test`（11）、`X86Lower_test`（50）、`Golden_test`（4）；
- 端到端：`CompileCopy_test`、全量；
- 性能：同进程 `codegen` 中位数两臂，**收益以实测为准**（上轮教训：不预设比例）。
