# 编译延迟（二）：字节搬运与 x86 双遍解码

## Why

`optimize-emit-fixup` 之后，单次编译（200 注册函数 × 50 调用点，1 个函数、1230 B 字节码）
从 44.3 ms 降到 6.4–11.1 ms。剩余时间分布（同机插桩，2026-11-27）：

| 阶段 | 实测 | 说明 |
| --- | --- | --- |
| `Assembler.assemble` 的 `build` 段（CRC + 四段拼接） | **0.82–1.45 ms** | `crc32OfPayload` 逐字节拼一遍、`ByteWriter` 再逐字节拼一遍、`take` 再拷一遍 |
| `Assembler.assemble` 的 `layout` 段 | 0.44–0.74 ms | 函数体用 `for (k in 0..size) body[k] = code[k]` 逐字节拷 |
| `Assembler.assemble` 的 `validate` 段 | 0.27–0.69 ms | 逐指令栈校验，真实工作量 |
| `JitCompiler.compileUnitWith` | 2.62 ms | 其中 `for (x in b) out.add(x)` 逐字节进 `ArrayList`，再 `toArray()` 拷一遍 |
| `FbcReader.load` | 0.75–0.82 ms | `slices` 0.15 / `dir` 0.20 / `constSite` 0.24 / `head` 0.15 |
| `JitExecutor.create` | 3.07 ms | 含一次**重复**的 `flushICache`（`seal()` 内已刷过一次） |

x86_64 侧：`X86Lower.lower` 是「探针遍 + CFG 深度遍 + 发射遍」三遍，其中
**探针遍与发射遍各调用一次 `InsnDecoder.decode`**，每次都新建操作数数组；
本身复杂度是 O(n)，但白付一倍解码与分配。

## What Changes

1. **`JitCompiler.compileUnitWith`**：先收集各函数字节并累加总长，再一次性分配
   `Array<UInt8>(total)`，用下标写入；去掉 `ArrayList` 追加与 `toArray()` 拷贝。
2. **`FbcWriter`**：新增 `payload()` 一次性拼出四段载荷；`build()` 用它算 CRC 并直接拼
   「头 + 载荷」，不再经过 `crc32OfPayload` 的临时 `ArrayList`。
3. **`Assembler` 布局段**：函数体改 `f.body.code.clone()`（整块复制）。
4. **`JitExecutor.create`**：删掉 `seal()` 之后重复的 `buf.flushICache()`。
5. **`X86Lower.lower`**：探针遍把 `DecodedInsn` 与偏移缓存下来，发射遍直接复用，
   不再二次解码。

**语义不变**：产物字节逐位一致；`crc32OfPayload()` 仍保留原签名（内部改走 `payload()`）；
`CodeBuffer.seal()` 的刷新语义不变（刷新次数少一次，只是去掉重复）。

## Impact

- 预期：单次编译再降 **1.5–2.5 ms（约 −25~35%）**；
- A64 与 x86_64 **共用**第 1–4 项；第 5 项只影响 x86_64；
- 影响文件：`src/backend/JitCompiler.cj`、`src/bytecode/FbcWriter.cj`、
  `src/compiler/Assembler.cj`、`src/backend/JitExecutor.cj`、`src/backend/X86Lower.cj`
  （+ 护栏 `src/backend/CompileCopy_test.cj`）；
- 风险：`compileUnitWith` 改成两遍后，`JitArtifacts` 的 `offsets/lengths` 必须与拼接结果自洽
  （护栏逐函数比对）；x86 缓存复用若偏移对齐错误，`X86Compile_test` 的字节断言会红。
