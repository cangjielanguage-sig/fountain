# CRC-32 生成式硬件路径（x86_64）

> 变更：`crc32-hw-cfunc` ｜ 日期：2026-11-06 ｜ 结论：Phase 1（CRC32C）与 Phase 2（ISO-HDLC）均采纳

## 1. 实现

| 路径 | x86_64 | aarch64 |
| --- | --- | --- |
| CRC32C | SSE4.2 `crc32`（8 字节循环 + 尾字节） | `crc32cx` / `crc32cb`（8 字节循环 + 尾字节） |
| ISO-HDLC / JAMCRC | PCLMULQDQ 16 字节折叠 + Barrett；尾部软件补 | `crc32x` / `crc32b`（8 字节循环 + 尾字节） |

- `CodeBuffer`：`mmap` RW → 写机器码 → `mprotect` RX（W^X）→ `__clear_cache`；失败回退软件。
- CPU 探测：`/proc/cpuinfo` 的 `sse4_2` / `pclmulqdq`；`F_UTIL_CRC_HW=0` 强制软件。
- 无第三方库、无 C 垫片；非 Linux x86_64 编译 stub。

## 2. 4KB 单次 CRC（含 `acquireArrayRawData` + CFunc 调用）

| 实现 | ns/次 | 相对软件 |
| --- | ---: | ---: |
| 软件 `CrcEngine`（slicing-by-4） | ~2500~2900 | 1.0× |
| 生成 CRC32C | ~420~440 | ~6× |
| 生成 ISO-HDLC（PCLMULQDQ） | **~390** | **~6.5~7.4×** |

数据来自 x86_64 `-O0` 尖刀（`taskset -c 2`）；生产 `-O2` 下函数体不变，调用侧开销更低。

aarch64 的生成函数各 56 字节，已在 QEMU 上做功能验证（见 §3）；真机性能待有 ARM 机器时补测。

### aarch64 机器码（汇编器核对）

```
ISO:    cbz len / cmp #8 / b.lo tail / ldr x3,[x1],#8 / crc32x w0,w0,x3
        / sub / cmp / b.hs / tail: ldrb + crc32b + cbnz / ret
CRC32C: 同上，crc32x -> crc32cx，crc32b -> crc32cb
```

## 3. 正确性

- f_util 生成式用例 9/9：黄金向量、随机长度（0..65536）、增量多段、强制软件回退、4 线程并发。
- f_protocol 4KB 帧 CRC 守卫：`frameCrc32=3762771613` 与软件路径完全一致。
- aarch64：用 `aarch64-linux-gnu-as` 生成/核对机器码，在 `qemu-aarch64` 上跑 64B/65B 两种长度：
  ISO `ffbae609` / `4a2f75d7`、CRC32C `3d0f7d5d`，与 Python 参考逐位一致。
- 全量回归：f_util 59/59、f_codec 16/16、f_protocol 85/85、f_rpc 2/2、f_mq 149/149（x86_64）。

## 4. 端到端

f_protocol 4KB：C p50 **3566 → 1341 ns（-62.4%）**；floor 2847 → 620 ns；no-CRC 627 ns 不变。
详见 `f_protocol/doc/perf/frame-encode-4k.md` §11。

## 5. 已知限制

- 生成路径只覆盖 Linux x86_64 / aarch64；其它 OS/架构编译 stub，始终走软件。
- aarch64 已通过 QEMU 功能验证，尚未在真机上取性能数据；`getauxval(HWCAP_CRC32)` 缺失时回落 `/proc/cpuinfo` 的 `crc32`。
- `mprotect` 被 SELinux/seccomp 拦截时回退软件；代码页常驻，不 `munmap`。
- `Crc32.update` 每次会进一次 `ensureReady` 的 `Mutex`（~几十 ns）；若后续成为热点可改无锁快路径。
- ISO 生成函数只处理 16 字节整数倍，尾部由软件补；4KB 帧无尾部。
