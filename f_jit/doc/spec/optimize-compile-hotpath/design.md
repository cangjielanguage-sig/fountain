# 设计：字存储 / 免解码 / 预分配

## 1. `A64Emitter` 按字存储

现状：`out: ArrayList<UInt8>`，`word(w)` 做 4 次 `add`；2358 字 ⇒ 9432 次容器追加。

改为 `out: ArrayList<UInt32>`：

| 方法 | 改法 |
| --- | --- |
| `word(w)` | `this.out.add(w)` |
| `size()` | `this.out.size * 4`（**对外仍是字节**） |
| `readWord(at)` | `this.out[at / 4]` |
| `patchWord(at, w)` | `this.out[at / 4] = w` |
| `bind` / `reloc` | 用 `this.size()` 而非 `this.out.size` |
| `finish` / `resolve` | 新增 `bytes()`：预分配 `Array<UInt8>(size())`，逐字展开小端 |

**等价性**：字节序与小端展开规则逐位相同；`bind`/`reloc` 记录的仍是字节偏移。
护栏：`A64Emitter_test`（期望字）、`A64EmitterFixup_test`（分支 imm 位域）、
`Golden_test` / 全量（机器码逐字节对拍）。

## 2. `validateFunc` 免解码

`validateFunc` 只需要 `op`、`size`、以及少量操作数。`op` 与 `size` 来自
`OpInfo.OPCODE_TABLE[code[off]]`（已有的 `info`），操作数直接 `code[off + 1 + k]`。

- `InsnDecoder.u8(insn, k)` → `code[off + 1 + k]`
- `InsnDecoder.u16(insn, k)` → `Int64(code[off+1+k]) | (Int64(code[off+2+k]) << 8)`
- `effectArgc(op, insn)` → `effectArgc(op, code, off)`
- `loadedSlotOf(op, insn)` → `loadedSlotOf(op, code, off)`

**等价性**：`decode` 里唯一的额外职责是 RSVD/FORBID 拒绝，而 `validateFunc` 在调用 `decode`
之前已经判过 `info.cat`（同一张表），故拒绝面不变。

## 3. `checkCrc32` 预分配

```cangjie
let n = raw.size - off
let payload = Array<UInt8>(n, repeat: 0u8)
var i = 0
while (i < n) { payload[i] = raw[off + i]; i = i + 1 }
let actual = Crc32.isoHdlc.compute(payload)
```

去掉 `ArrayList` 的逐字节追加与 `toArray()` 的第二趟拷贝。
CRC 的输入字节序列完全相同。

## 4. 不做

- `Crc32.compute` 增加 `(data, off, len)` 重载：要动 `f_util` 公共 API，跨模块；
  当前只省一趟 1.9 KB 拷贝，收益不足以扩权；
- `sliceOf` 逐字节循环：无更廉价的数组切片 API，且总量仅 1.9 KB；
- `InsnDecoder.decode` 的通用去分配化：`A64Lower`/`X86Lower` 仍需操作数数组，
  要改 `translate` 的签名，风险大于本轮收益；本轮先把 `validate` 这条最大重复解码去掉。

## 5. 判定

MOV = `max(3%, 2×离散度)`；预期 −9~12%，同轮 A/B 方向一致即 keep。
