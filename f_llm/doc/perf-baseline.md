# f_llm KnowledgeChunker 内存基准（local mode 试点，参考值）

> 只作回归参考，不作 CI 门禁。门禁是正确性与 local / 堆逐元素等价。
> 本文件记录 `local-mode-f-llm-knowledge-chunker` 试点前后的峰值内存口径与实测。

## 方法与口径

- 环境：Linux aarch64，Cangjie SDK `1.3.0-alpha.20261118001016`，`cjpm test` 的 release 配置，单次运行、含噪声。
- 被测入口：`KnowledgeChunker.splitImpl(content, 400, 50, useLocal)`；`maxChars=400`、`overlap=50` 与公开默认值一致。
- 输入：
  - ASCII 门限边界：2,097,152 字节（2 MiB，走 local）与 2,097,153 字节（2 MiB+1，走堆）；
  - 中文门限边界：699,050 个汉字（2,097,150 字节，走 local）与 699,051 个汉字（2,097,153 字节，走堆）；
  - 大文档对照：8 MiB ASCII（走堆）。
- 堆增量：基准进程内取 `getAllocatedHeapSize()` 在调用前后的差值；`chunks` 在测量时仍存活，因此包含切块结果本身。
- local 峰值：`ArrayList<Rune>` 在 `splitImpl` 返回时随 local region 整块释放，函数外无法用 `getAllocatedLocalObjectSize()` 观察其过程峰值。按同一 SDK、同一构造方式（`ArrayList<Rune>(total) @ local!` + 精确容量 `add`）用独立探针实测：
  - 1,000 rune：4,064 B；10,000 rune：44,112 B；100,000 rune：404,112 B；1,000,000 rune：4,004,112 B；2,097,152 rune：8,392,720 B；
  - 即 `4 × rune 数 + 4,112 B`（头/对齐开销约 4 KB），`Rune` 宽度确认为 4 字节。
- peak RSS：基准测试进程内读取 `/proc/self/status` 的 `VmHWM`，包含测试框架自身的基线，只用于同进程内 local / 堆两档对比。
- 基准测试：`f_llm/src/store/KnowledgeChunkerLocalModeBench_test.cj` 的 `tierBenchmarks`，只打印不设门禁。

## 实测

| 场景 | 档位 | local 理论峰值 | 堆增量（3 次） | 耗时（3 次，`-O2`） | 进程 VmHWM |
|---|---|---|---|---|---|
| ASCII 2,097,152 B（2 MiB） | local | 8,392,720 B | −27.3 / −25.9 / −25.9 MB（仅 chunk，GC 噪声） | 50 / 50 / 49 ms | 121.5 / 117.7 / 117.5 MB |
| ASCII 2,097,152 B | 堆（强制对照） | 0 | 19.37 / 19.37 / 19.35 MB | 39 / 37 / 37 ms | 同进程，被上一行覆盖 |
| ASCII 2,097,153 B（2 MiB+1） | 堆 | 0 | 19.36 / 19.35 / 19.37 MB | 52 / 53 / 48 ms | 121.5 / 117.7 / 117.9 MB |
| 中文 699,050 字（2,097,150 B） | local | 2,800,312 B | 7.84 / 7.84 / 7.85 MB | 28 / 27 / 26 ms | 126.7 / 127.5 / 127.8 MB |
| 中文 699,051 字（2,097,153 B） | 堆 | 0 | 10.64 / 10.65 / 10.64 MB | 26 / 25 / 24 ms | 135.2 / 136.5 / 136.3 MB |
| ASCII 8,388,608 B（8 MiB） | 堆 | 0 | −1.3 / −0.2 / +0.2 MB（GC 噪声） | 209 / 204 / 212 ms | 153.6 / 138.1 / 153.6 MB |

- 进程基线 `VmHWM` 约 68–70 MB（测试框架与已加载数据）；`VmHWM` 在同一进程内单调递增，因此表中后几行是累计峰值，不能按行相减。
- `堆增量` 受 GC 影响明显，负值表示运行期间回收了之前的临时对象；判断档位差别应看同一输入下 local / 强制堆两行：2 MiB ASCII 的 local 档堆增量始终 ≤ 0（只有 chunk），强制堆档稳定在 +19.4 MB（rune 缓冲约 8 MiB + chunk 结果）。
- 中文 2 MiB 的 local 档堆增量稳定在 +7.84 MB，低于同尺寸 ASCII 的强制堆档；与中文 rune 数只有 699,050 相符。
- 耗时是参考值：local 档比强制堆档略慢（50 ms vs 37–39 ms），来自 local 分配与记账成本；本轮不以吞吐量验收。
- `-O2` 数据通过在 `[package].compile-option` 临时追加 `-O2` 得到，未提交该优化选项；提交状态是 `cjpm test` 默认（未优化）构建，未优化下整轮 680 条用例同样全绿（9 条外部 BgeM3 连接错误保持基线）。

## 说明

- 2 MiB ASCII 的 local 理论峰值 = 2,097,152 × 4 + 4,112 = 8,392,720 B，比 8 MiB 预算多 4,112 B（约 0.05%），来自容器头/对齐；不属于「明显超过预算」，故维持 2 MiB 门限。
- 门限以上走堆，local 占用只有切块过程中的少量临时值；门限以下堆增量应显著低于堆档（rune 缓冲不再计入堆）。
- 与 `cjLocalRegionMaxSize`（默认 256 MB，全线程合计）的关系：单次最多约 8 MiB local，默认上限可容纳约 32 个并发切块；更高并发需调大该环境变量或降低单次内容。
- 中文在 2 MiB 内容时 rune 数约 699,050，local 理论峰值 = 699,050 × 4 + 4,112 = 2,800,312 B（约 2.67 MiB），低于 ASCII 最坏情况。
- 未优化构建（`-O0`，`cjpm test` 默认）下，从 mode 化 `ArrayList` 读元素会在当前 local region 留下 32 B/次的临时对象，直到函数返回；`-O2` 无该开销。因此实现把 local / 堆的窗口循环拆成两个 helper，堆路径使用普通 `ArrayList<Rune>`，在任何构建档位都不碰 local region。
- ohos 目标不支持 `--enable-local-mode`，本模块在 `aarch64-linux-ohos` / `x86_64-linux-ohos` 上不构建，与 `f_base` / `f_data` / `f_svg` 的 local-mode 基线一致。
- 以上数值为参考、非 CI 门禁；不做吞吐量承诺。逐元素等价与门限判定由 `KnowledgeChunkerLocalMode_test.cj` 覆盖。
