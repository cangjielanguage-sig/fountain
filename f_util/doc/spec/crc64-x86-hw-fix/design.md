# Design

## 1. 根因（已用反汇编证实）

`CrcGf.reflectX86Constants` 返回的布局是：

```
[P, K128, K192, mu, LUT(2), mask0F(2), maskF0(2), revIdx(2), 0,0,0,0]
```

即前 4 个常量各占 **8 字节**；LUT/mask/revIdx 各占 16 字节。

旧 `REF_CODE` 却按下面的方式加载：

```
movdqu xmm4, [rcx+0x00]   ; 实际 = P | K128
movdqu xmm5, [rcx+0x10]   ; 实际 = K192 | mu
movdqu xmm6, [rcx+0x20]   ; 实际 = LUT
movdqu xmm7, [rcx+0x30]   ; 实际 = mask0F
movdqu xmm8, [rcx+0x40]   ; 实际 = maskF0
movdqu xmm9, [rcx+0x50]   ; 实际 = revIdx
```

后续指令又把这些寄存器当作 `P/K128/K192/mu/LUT/mask0F/...` 使用：

- `pclmullqlqdq xmm2, xmm4` 用 P：低半正确；
- `pclmullqlqdq xmm2, xmm5` 期望 K128，实际低半是 K192；
- `pclmulhqhqdq xmm3, xmm6` 期望 K192，实际高半是 LUT；
- `pand xmm11, xmm9` 期望 mask0F，实际是 revIdx；
- `pshufb xmm13, xmm8` 期望 LUT，实际是 maskF0。

所以旧核返回 `0xF0F0F0F0F0F0F0F0`（maskF0）并不奇怪。**表路径（`F_UTIL_CRC_HW=off`）全绿，说明软件实现与常量生成器本身没有问题。**

## 2. 修复策略

保留 `CrcGf`/`CrcEngine`/公开 API 不变，只替换两个机器码数组：

| 数组 | 旧长度 | 新长度 | 说明 |
| --- | ---: | ---: | --- |
| `REF_CODE` | 539 | **495** | 反射：入口位反转 + 逐块 bit-reverse/16B 反转 + 折叠 + Barrett + 出口位反转 |
| `NORM_CODE` | 219 | **221** | 正常：逐块 16B 反转 + 折叠 + Barrett |

新核的常量契约与现有 `reflectX86Constants` **逐字节一致**：

| 偏移 | 内容 | 用途 |
| ---: | --- | --- |
| 0 | `P`（低 64 位） | 首块注入、Barrett 二次乘 |
| 8 | `x^128 mod P`（K128） | 折叠低半区、收尾高半区 |
| 16 | `x^192 mod P`（K192） | 折叠高半区 |
| 24 | `mu`（Barrett 商低 64 位） | Barrett |
| 32 | LUT（16B） | 反射核逐字节 bit-reverse |
| 48 | mask0F（16B） | 取低 nibble |
| 64 | maskF0（16B） | 取高 nibble |
| 80 | revIdx（16B） | 16 字节反序 |
| 96..127 | 0 | 保留 |

正常核只使用 `P/K128/K192/mu` 与 **偏移 32 的 revIdx**（`CrcGf` 的 normal 分支当前布局）。

## 3. 新核算法（与 aarch64 PMULL 核等价）

反射核：

```
crc = bitrev64(crc)                    // 入口
acc = clmul(crc, P) ^ B0               // 首块（B 已 bitrev + 16B 反序）
for each next 16B block:
    acc = clmul(acc.lo, x128) ^ clmul(acc.hi, x192) ^ B
t = clmul(acc.lo, P) ^ clmul(acc.hi, x128)
r = barrett(t)                         // q = high(clmul(t.hi, mu)) ^ t.hi
                                       // r = t.lo ^ low(clmul(q, P))
return bitrev64(r)                     // 出口
```

正常核：去掉入口/出口 `bitrev64`，块只做 `pshufb(revIdx)`。

x86 指令对应：

- `bitrev64`：`pshufb` nibble LUT + `psllw 4` + `pand maskF0` + `bswap`；
- 块 bit-reverse：同一套 LUT/mask，16 字节；然后 `pshufb revIdx`；
- 折叠：`pclmullqlqdq` / `pclmulhqhqdq`；
- Barrett：`pextrq` 取高位、`pclmul` 两次、`xor`。

## 4. 正确性证据

新核先用 **独立 C 参考实现**验证（不经过仓颉）：

- 长度：16/32/48/64/256/1024/4096；
- 变体：XZ、ISO、REDIS（反射）与 ECMA（正常）；
- 结果：**4 × 7 = 28 组逐位一致**（`got == want` 全部为 1）。

字节由 `as --64` 汇编后 `objcopy` 提取，`objdump -d -M intel` 逐条核对；入口偏移 `REF=0`、`NORM=0x1EF`。

**Red/Green 记录（WSL Ubuntu 24.04 / x86_64）**：

- Red：新增 `crc64HwXz256MatchesSoftwareRegression` 失败，硬件 `0xF0F0F0F0F0F0F0F0` vs 软件 `0x900A62B82E57A77B`；
- Green：`CrcEngine_test` **17/17 PASSED**；`CrcGf_test` 7/7；`Crc32CodegenTest` 10/10；`f_util` 全量 **79/79**；
- `F_UTIL_CRC_HW=off`：`CrcEngine_test` 17/17 仍绿（三态/回退含在内）。

## 5. TDD 与验收

1. **Red**：现有 `crc64HwMatchesSoftwareForXz` 等 6 个用例已在 x86_64 失败；再新增一个聚焦用例 `crc64HwXz256MatchesSoftwareRegression`（256 字节，XZ），确认同样失败。
2. **Green**：替换两个字节数组，跑：
   - `CrcEngine_test`（6 变体、任意长度/切分、三态、回退、性能门控）；
   - `CrcGf_test`（常量/折叠模型，含 `F_UTIL_CRC_HW=off`）；
   - `Crc32CodegenTest`（确认 CRC-32 不受影响）；
   - `f_util` 全量；
   - `f_protocol` / `f_codec` / `f_rpc` / `f_mq` 全量回归。
3. **性能**：`F_UTIL_PERF=1` 下 1 MiB ≥500 MB/s、4 KiB ≤1.34 µs（6 个变体）。
4. **回退**：`F_UTIL_CRC_HW=off` / `forceAllocFailureForTest(true)` 仍全绿。

**性能实测（x86_64，`F_UTIL_PERF=1`，1 MiB）**：

| 变体 | 1 MiB 吞吐 | 4 KiB 单次 |
| --- | ---: | ---: |
| ECMA-182 | 12,574.8 MB/s | 429.6 ns |
| WE | 11,785.9 MB/s | 459.5 ns |
| XZ | 11,718.0 MB/s | 475.2 ns |
| GO-ISO | 11,054.9 MB/s | 476.3 ns |
| REDIS | 11,108.8 MB/s | 482.8 ns |
| JONES | 11,565.0 MB/s | 473.3 ns |

全部远超门禁（≥500 MB/s、≤1.34 µs）；CRC-64/XZ 表路径 339.2 MB/s、CRC-16/MODBUS 表路径 96.6 MB/s 也通过。

**回归（默认构建）**：`f_util` 79/79、`f_pool` 72/72、`f_codec` 16/16、`f_protocol` 85/85、`f_rpc` 2/2、`f_mq` 149/149。
`f_pool` 首轮在宿主高负载下 `concurrentBorrowNeverSharesBuffer` 报 1 次 ERROR（8 线程 × 池 4 的等待超时），单独重跑 72/72；该用例不依赖 CRC，归类为负载敏感，不阻塞本变更。

## 6. 风险

| 风险 | 缓解 |
| --- | --- |
| 机器码字节/偏移错 | C 参考 28 组对拍 + objdump 核对 + 全套 6 变体用例 |
| 常量布局再次漂移 | 新核严格按 §2 偏移加载；注释写明每个偏移 |
| 性能不达标 | 单块核先过正确性；若 4 KiB 超 1.34 µs，再评估 4-lane（本变更不预先做） |
| 影响 CRC-32/ARM | 只改 `crc64_native_x86.cj` 的两个数组与注释 |

## 7. 交付物

- `f_util/src/crc64_native_x86.cj`：新 `REF_CODE`/`NORM_CODE` + 偏移/算法注释；
- `f_util/src/CrcEngine_test.cj`：聚焦回归用例；
- 本变更 `doc/spec/crc64-x86-hw-fix/`；
- 测试/性能结果回填本文件与 `tasks.md`。
