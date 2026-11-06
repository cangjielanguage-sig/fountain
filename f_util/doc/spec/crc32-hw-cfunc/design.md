# Design

## 1. 总体

```
Crc32.compute/update
   └─ Crc32Hw（Linux only）
        ├─ CPU 特性探测
        ├─ CodeBuffer（mmap RW → 写 → mprotect RX → __clear_cache）
        ├─ 生成函数 → CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32>
        └─ 失败/不支持 → CrcEngine（纯软件）
```

- 生成函数统一 **raw 语义**：输入寄存器初值（未 finish、未 xorout），输出 raw；`initRegister/finish` 仍由 `CrcEngine` 做常数时间处理。
- `compute = finish(hw(init, ptr, len))`；`update = hw(crc, ptr, len)`。
- 只有 ISO-HDLC / CRC32C 两个变体接入；其余走软件。

## 2. CodeBuffer

照搬 f_jit `CodeBuffer` 的**模式**（同仓库、Apache-2.0；不 import f_jit）：

- `mmap(NULL, pages, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)`；
- 写入机器码；
- `mprotect(ptr, len, PROT_READ|PROT_EXEC)`（W^X，不用 RWX）；
- `__clear_cache(ptr, ptr+len)`（aarch64 必需，x86 同接口）；
- 失败任一步 → `None`，调用方回退软件；页面常驻进程生命周期（不 `munmap`，避免 CFunc 悬空）。
- 非 Linux：`@When[os == "Linux"]`，其它平台 stub 返回 `None`。

## 3. CPU 特性探测

- **x86_64**：`cpuid` 叶子 1，`ECX[1]` = PCLMULQDQ，`ECX[20]` = SSE4.2。
  - `cpuid` 本身用生成的 8 条指令小函数（`mov eax,1; cpuid; mov [rdi],...; ret`）调用，不依赖 `/proc`；`x86_64` 保证有 `cpuid`。
  - 若 CodeBuffer 都失败，直接回退软件，不需要探测。
- **aarch64**：`getauxval(AT_HWCAP) & HWCAP_CRC32`（`1 << 7`），libc FFI。
- 结果缓存一次；`F_UTIL_CRC_HW=0` 强制关闭。

## 4. Phase 1：低风险指令

### x86_64 CRC32C（`crc32` 指令）

函数 `(UInt32 crc, CPointer<Byte> p, UInt64 len) -> UInt32`：

```
mov eax, edi                 ; crc
cmp rdx, 8 / jb tail
loop8:
  crc32 rax, qword [rsi]     ; F2 48 0F 38 F1 06
  add rsi, 8
  sub rdx, 8
  cmp rdx, 8 / jae loop8
tail:
  test rdx, rdx / jz done
loop1:
  crc32 eax, byte [rsi]      ; F2 0F 38 F0 06
  inc rsi / dec rdx / jnz loop1
done:
  ret
```

- `crc32` 指令的寄存器语义就是 **raw**（无 init/final xor），与 `CrcEngine.update` 直接对齐。
- 尾部逐字节；4KB 时循环次数 512。

### aarch64 ISO-HDLC / CRC32C

```
; w0=crc, x1=p, x2=len
loop8: cmp x2,#8 / b.lo tail
       ldr x3,[x1],#8
       crc32x w0,w0,x3        ; ISO：crc32x；CRC32C：crc32cx
       sub x2,x2,#8 / b loop8
tail:  cbz x2,done
       ldrb w3,[x1],#1
       crc32b w0,w0,w3        ; ISO：crc32b；CRC32C：crc32cb
       sub x2,x2,#1 / b tail
done:  ret
```

- 同样 raw 语义；ISO 与 CRC32C 只差指令编码。
- 指令编码用 `aarch64-linux-gnu-as` 对照（若 WSL 无交叉汇编器，用 LLVM `llvm-mc` 或手工核对 ARM ARM；测试只能在 x86 上做差分，ARM 代码走代码评审）。

## 5. Phase 2：x86 ISO-HDLC（PCLMULQDQ，go/no-go）

- 算法：Intel 的 4-lane folding（16B×4 折叠 → 128→64 → 64→32 → Barrett），常量按 reflected CRC-32 生成/核对。
- 先生成**单块 16B 折叠**版本（代码量小、易对拍），跑通后再考虑 4-lane。
- 尾部（<16B）由 Cangjie 侧用 `CrcEngine` 处理；生成函数只处理 `len & ~15`。
- 常量不硬编码魔法数：用 Cangjie 的 GF(2) 多项式运算算 `x^(128*k) mod P`，与参考值对照。
- 尖刀验收：
  - 随机长度 `[0..1MiB]`、随机内容，与软件逐位一致；
  - 4KB ≥3× 软件（目标 5~10×）；
  - 失败（对拍错/性能不够/编码器写不出）→ **停止**，x86 ISO 保持软件，报告写清。
- 集成后 f_protocol 的 C 路径才会在 x86 上明显下降；Phase 1 只影响 `crc32c`。

**实施结果（2026-11-06）**：

- CRC32C 与 ISO 均生成成功；ISO 单块折叠尖刀 4KB **393 ns/次**（含 acquire/FFI），与软件逐位一致。
- 关键修复：96→64 折叠必须用 `(v0 >> 4) ^ product`，不能把原 `v0` 再异或进去；尖刀对拍发现并修正。
- 最终 f_protocol：C p50 **1341 ns**（-62.4%）、floor 620 ns、no-CRC 627 ns；16T 绝对 2.78M fps（扩展 3.74×，宿主 load 11~18，需空闲复测）。

## 6. Crc32 集成

- `Crc32` 构造时按参数判定 `hwKind`：
  - `Iso`：`poly=0x04C11DB7, init=0xFFFFFFFF, refin/refout=true, xorout=0xFFFFFFFF`
  - `Crc32c`：`poly=0x1EDC6F41, init=0xFFFFFFFF, refin/refout=true, xorout=0xFFFFFFFF`
  - 其余 `None`。
- `compute/update`：
  1. `hwKind != None` 且 `Crc32Hw.available()`；
  2. `data.size == 0` 走软件；
  3. `acquireArrayRawData` → `unsafe { cf(...) }` → `releaseArrayRawData`；
  4. 异常/空指针/`mprotect` 失败 → 软件。
- 窗口内只有 CFunc 调用，不构造对象、不日志。
- 线程安全：生成函数不可变；探测/生成只做一次（`Mutex`）。

## 7. 测试与基准

**测试**

1. `CodeBuffer`：alloc/write/seal/flush/free，失败路径返回 false/None。
2. CPU 探测：本机 x86 有 `pclmulqdq/sse4_2`；强制关闭时 `available()==false`。
3. CRC32C（x86 可测）：黄金向量 + 随机长度/内容 + `init/update/finish` 多段对拍。
4. ISO（x86 Phase 2 可测；aarch64 仅代码评审 + 交叉汇编对照）。
5. 回退：`F_UTIL_CRC_HW=0`、`mprotect` 失败模拟（保留一个测试钩子）、非 Linux。
6. 4 线程 × 10k 次 4KB 一致性。
7. f_protocol 现有 4KB round-trip / 帧 CRC 守卫。

**基准**

- `f_util`：CRC32C / ISO，4KB / 64KB / 1MB，native vs 软件，3 轮中位。
- `f_protocol`：C / no-CRC / floor / MT(1/4/8/16)，`-O2`，3 轮中位；对比当前 C p50 3566 ns。
- 报告：`f_util/doc/perf/crc32-codegen.md`、`f_protocol/doc/perf/frame-encode-4k.md` §12。

**采纳门槛**

- Phase 1：CRC32C ≥3× 软件；所有测试/回归绿；无第三方依赖。
- Phase 2：ISO ≥3× 软件（目标 10×）；f_protocol C p50 ≤2500 ns（目标 ~1500）；否则不合并 Phase 2。

## 8. 风险

| 风险 | 缓解 |
| --- | --- |
| PCLMULQDQ 常量/序列错 | 单块尖刀 + 随机逐位对拍；不达标就停 |
| W^X / SELinux 拦截 `mprotect` | 失败回退软件；记录一次告警 |
| CPUID 探测误判 | 生成前用 `cpuid` 实读；不支持就不生成 |
| aarch64 无本机测试 | 交叉汇编对照 + 代码评审；实验室有 ARM 再补跑 |
| 代码页泄漏/悬空 | 页面常驻，不 free；CFunc 全局唯一 |
| `acquireArrayRawData` 窗口 | 只含 CFunc 调用 |
| 生成器写错字节 | 单元测试逐条断言编码 + 反汇编对照 |

## 9. 基线

叠加在 `bench/frame-attrib`（线程本地池 + P0，C 3566 ns）之上；合并顺序：先 `frame-attrib`，再本变更。

## 10. 交付物

- `f_util/src/code_buffer.cj`、`crc32_codegen_x86.cj`、`crc32_codegen_aarch64.cj`、`crc32_native_stub.cj`、`crc32.cj` 改动；
- `f_util/src/crc32_codegen_test.cj`、`crc32_bench_test.cj`；
- `f_util/README` 中英；
- `f_util/doc/perf/crc32-codegen.md`、`f_protocol/doc/perf/frame-encode-4k.md` §12；
- `f_util/doc/spec/crc32-hw-cfunc/` 规划副本。
