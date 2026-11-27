# 编译延迟（三）：发射器按字存储、`validate` 免解码、CRC 预分配

## Why

`optimize-compile-copy` 之后单次编译约 10.0 ms（中位）。同机插桩（250 条指令、9432 B 机器码）：

| 位置 | 实测 | 说明 |
| --- | --- | --- |
| `A64Lower.lower` 的 `translate` | **1.41–1.65 ms** | 9432 B = 2358 字，`A64Emitter.word()` 每字做 **4 次** `ArrayList<UInt8>.add` |
| `A64Lower.lower` 的 `bind + decode` | 0.67–0.72 ms | 每指令一次 `InsnDecoder.decode`（**每次分配一个操作数数组**）+ 一次 `bind('L${off}')` |
| `Assembler.validateFunc` 的 `decode` | **0.21–0.23 ms** | 同一份解码，只为读 `size` 与几个操作数；`size` 已由 `OpInfo.len` 给出 |
| `FbcReader.load`：`checkCrc32` | 0.15–0.53 ms | 载荷先逐字节进 `ArrayList` 再 `toArray()`，两趟拷贝 |
| `FbcReader.load`：`dir+types` / `site+name` / 切片 | 0.24 / 0.30 / 0.17 ms | 表解码与切片拷贝 |

共同点：**每指令一次小数组分配**（本机实测单次分配约 300–700 ns），以及
**每 4 字节一次容器追加**。

## What Changes

1. **`A64Emitter` 改按 32 位字存储**：`out: ArrayList<UInt32>`，`word()` 一次 `add`；
   `readWord`/`patchWord` 直接按字索引；`size()` 仍返回**字节数**（`words * 4`）；
   `finish` 时一次性展开成字节数组（预分配）。
2. **`Assembler.validateFunc` 不再调用 `InsnDecoder.decode`**：`op = code[off]`、`size = info.len`，
   操作数用 `code[off + 1 + k]` 直读；`effectArgc` / `loadedSlotOf` 改签名收 `(op, code, off)`。
3. **`FbcReader.checkCrc32` 预分配**：`Array<UInt8>(n)` 一次拷贝，去掉 `ArrayList` + `toArray`。

**语义不变**：机器码字节逐位一致（小端同序）；校验的接受/拒绝面逐条不变（`info.cat` 检查已在
`decode` 之前做过）；CRC 输入字节序列不变。

## Impact

- 预期：`A64Lower` **−0.6~0.9 ms**、`validate` **−0.2 ms**、`load` **−0.1 ms**，合计 **−9~12%**；
- A64 与 x86_64 均受益于第 2、3 项；第 1 项仅 A64；
- 影响文件：`src/backend/A64Emitter.cj`、`src/compiler/Assembler.cj`、`src/bytecode/FbcReader.cj`
  （+ 护栏 `src/backend/A64EmitterSize_test.cj`）；
- 风险：`A64Emitter.size()` 的「字节」口径必须保持（`bind`/`reloc` 都用它），由护栏与
  `A64EmitterFixup_test` 的分支偏移断言共同锁定。
