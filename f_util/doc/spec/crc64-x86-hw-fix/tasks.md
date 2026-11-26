# Tasks

## 1. Red：钉住 x86 CRC-64 硬件错误

- [x] 1.1 在 `CrcEngine_test.cj` 新增 `crc64HwXz256MatchesSoftwareRegression`（XZ、256B、硬件 vs 软件）。
- [x] 1.2 运行 `CrcEngine_test`：新用例失败（hw `0xF0F0F0F0F0F0F0F0` vs sw `0x900A62B82E57A77B`），既有 6 个用例同样失败；`F_UTIL_CRC_HW=off` 下表路径通过。

## 2. Green：替换折叠核字节

- [x] 2.1 用新单块反射核（495B）替换 `REF_CODE`，正常核（221B）替换 `NORM_CODE`；补常量偏移/算法注释。
- [x] 2.2 新用例 + `crc64HwMatchesSoftwareForXz` / `crc64HwSegmentedMatchesOneShot` / `crc64HwThreeStateMatchesReference` 全部转绿。
- [x] 2.3 `CrcEngine_test` 全量 **17/17**；`CrcGf_test` **7/7**；`F_UTIL_CRC_HW=off` 下 `CrcEngine_test` **17/17**。
- [x] 2.4 `Crc32CodegenTest` **10/10**，CRC-32 路径无回归。

## 3. 性能与回归

- [x] 3.1 `F_UTIL_PERF=1`：6 变体硬件 11.1~12.6 GB/s、4 KiB 429~483 ns（门禁 ≥500 MB/s、≤1.34 µs）；CRC-64/XZ 表路径 339.2 MB/s、CRC-16/MODBUS 96.6 MB/s。
- [x] 3.2 `f_util` **79/79**；`f_pool` **72/72**（首轮并发用例受宿主 load 影响报 1 次 ERROR，单独重跑全绿）；`f_codec` **16/16**、`f_protocol` **85/85**、`f_rpc` **2/2**、`f_mq` **149/149**。
- [x] 3.3 README 中英补 x86_64 实测；design 回填 Red/Green 与性能数据。

## 4. 收尾

- [x] 4.1 `openspec validate crc64-x86-hw-fix --strict`；同步 `f_util/doc/spec/crc64-x86-hw-fix/`。
- [x] 4.2 提交；报告修复前后数据与回归结果。
