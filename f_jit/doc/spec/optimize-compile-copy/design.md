# 设计：批量字节搬运（A64/x86 共用）+ x86 单次解码

## 1. 目标

在 `optimize-emit-fixup` 之后（6.4–11.1 ms/次），把剩下的**纯搬运开销**去掉。
判定标准仍是 MOV = `max(3%, 2×离散度)`。

## 2. 五处改动与等价性

### 2.1 `JitCompiler.compileUnitWith`

旧：`ArrayList<UInt8>` 逐字节 `add`，末尾 `toArray()` 再拷一次；9.6 KB 机器码两趟搬运。

新：第一遍只收集 `bodies[i]` 并累加 `total`，第二遍 `Array<UInt8>(total)` 下标写入。
`ids/offs/lens` 同步改成定长数组，消除三个 `ArrayList` 与 `toArray()`。

**等价性**：`offsets[i]` 仍是前缀和，`lengths[i]` 仍是单函数字节数，拼接顺序不变。
护栏 `CompileCopy_test` 逐函数比对字节、offset、length、`entry()` 反查。

### 2.2 `FbcWriter`

旧：`crc32OfPayload` 逐字节拼 `ArrayList` → `toArray`；`build` 里 `wBytes` 再逐字节写一遍 →
`take` 又拷一遍。同一份 1.9 KB 载荷搬四趟。

新：`payload()` 一次分配、一次下标写入；`build` 用同一份 `body` 算 CRC 并与头部拼成最终数组。
`crc32OfPayload()` **公开签名保留**（内部改走 `payload()`），外部调用者无感。

**等价性**：CRC 输入字节序列不变；头部字段（四段长度、entryFn）不变；`Golden_test` 的
逐字节产物断言是最强护栏。

### 2.3 `Assembler` 函数体复制

`Array<UInt8>(size, repeat: 0)` + 逐字节循环 → `f.body.code.clone()`。
数组元素完全相同，只是去掉逐元素循环。

### 2.4 `JitExecutor.create` 的重复刷新

`CodeBuffer.seal()` 内部已调用 `flushICache()`；`create` 在 `seal()` 之后又调一次，
对页对齐后的整段（≥ 机器码长度）再刷一遍。删除后者。
`flushCounter` 只在 `CodeBuffer_test` 里被显式调用断言，不经 `create`，不受影响。

### 2.5 `X86Lower.lower` 的单次解码

旧：探针遍 `InsnDecoder.decode` 一次（分配操作数数组），发射遍再 `decode` 一次。

新：探针遍把 `DecodedInsn` 与偏移存进两个 `ArrayList`，发射遍按同一顺序复用。
偏移序列与旧实现逐条一致（都由 `insn.size` 累加），`depthAt` 查表键不变。

**等价性**：`X86Compile_test` / `X86Lower_test` 对字节编码有断言；解码结果对同一 `code/off`
是确定的，复用不改变任何字节。

## 3. 不做

- `FbcReader` 的 4 次 `sliceOf`（0.15 ms）：都是数组切片复制，已是最小形态；
- `Assembler.validate`（0.27–0.69 ms）：逐指令栈校验，真实工作量；
- `ByteWriter.wBytes` 的泛化改造：`Assembler` 只在 code 段用它（1.2 KB），
  改用 §2.2 的载荷拼接后收益已覆盖大半；避免为一个小循环引入 API 依赖。
- x86 的逐指令 `bind('L${off}')` 字符串建键：要改成偏移键需动 `bindLabel` 的外部契约，
  风险大于收益，留待有 x86 实测后再定。

## 4. 验证

- 护栏 `CompileCopy_test`：整单元 code == 逐函数产物拼接；offsets/lengths/entry 自洽；
  该用例在 aarch64 走 `A64Compiler`、x86_64 走 `X86Compiler`，**两种机器都有效**；
- 既有 `Golden_test`（`.fbc` 逐字节）、`X86Compile_test`（x86 编码字节）覆盖 §2.2 / §2.5；
- A/B：端到端 `compile + load + create`，同探针两臂（`git stash` 切换实现）。
