# Tasks

## 1. Phase 1：CodeBuffer 与探测

- [x] 1.1 `CodeBuffer` 用例：alloc/write/seal/flush/free，失败返回 `None`/false。
- [x] 1.2 实现 Linux-only `CodeBuffer`（mmap RW → mprotect RX → `__clear_cache`），非 Linux stub。
- [x] 1.3 CPU 探测：`/proc/cpuinfo` 的 `sse4_2` / `pclmulqdq`；`F_UTIL_CRC_HW=0` 关闭。
- [x] 1.4 生成 x86_64 CRC32C（`crc32` 指令），汇编器核对字节；黄金向量/随机长度对拍。
- [x] 1.5 aarch64 ISO/CRC32C：本机无 ARM；暂由 stub 覆盖，代码生成留待 ARM 环境（本变更不含）。
- [x] 1.6 `Crc32` 接入：`hwKind` 判定、`compute/update` raw 快路径、空数组/失败回退。
- [x] 1.7 f_util 生成式用例：CRC32C 黄金值 + 随机长度 + 增量 + 回退 + 4 线程（9/9 通过）。

## 2. Phase 2：x86 ISO-HDLC（PCLMULQDQ）

- [x] 2.1 尖刀：单块 16B 折叠 + Barrett，随机长度/内容与软件逐位对拍。
- [x] 2.2 达标：4KB **393 ns/次**（约 6~7× 软件）；未做 4-lane，单块已满足门槛。
- [x] 2.3 集成：`len` 16 字节整数倍走硬件，尾部软件；4KB/64KB/1MB 对拍通过。
- [x] 2.4 f_protocol 4KB：C p50 **1341 ns**（目标 ≤2500）；floor 620 ns；no-CRC 627 ns。
- [x] 2.5 写报告：`frame-encode-4k.md` §11；f_util README 中英补充。

## 3. 收尾

- [x] 3.1 README 中英：生成器、CPU 要求、回退、`F_UTIL_CRC_HW`。
- [x] 3.2 全量回归：`f_util` / `f_codec` / `f_protocol` / `f_rpc` / `f_mq`（结果见提交记录）。
- [x] 3.3 `openspec validate --strict`；Phase 1/2 均达标，提交。
