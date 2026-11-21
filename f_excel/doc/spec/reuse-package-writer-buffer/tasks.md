# 任务：OPC 包生成的 XML 部件缓冲复用

> 约定：仓颉工程走 TDD —— 先让新用例红，再实现到绿；每个任务组完成即独立提交（「有单元测试后再提交」）。分支：`feature/reuse-package-writer-buffer`。

## 0. 准备与基线

- [x] 0.1 分支已建：`feature/reuse-f-excel-buffers`（基于 `origin/sts/1.3.x-LocalMode`）
- [x] 0.2 在 `f_excel` 下跑 `cjpm test`，记录基线：**184 通过 / 0 失败**
- [x] 0.3 用当前实现生成固定夹具（1 sheet、少量数字/文本/样式单元格、无图片）的包，解包后把 `[Content_Types].xml`、`_rels/.rels`、`xl/workbook.xml`、`xl/_rels/workbook.xml.rels` 四个部件的字节原样保存下来，作为后续 golden 常量；`xl/styles.xml` 记录长度与前/中/后各一段关键片段
- [x] 0.4 核实 `std.io.ByteBuffer` 语义：`bytes()` 是 `Array(rawptr, start, len)` 视图、`clear()` 会擦零 `[0,start+length)`、`ZipWriter.add` 同步 CRC/压缩且不保留 `data`；结论写入 design「关键前提」

## 1. 测试先行（`f_excel/src/PackageBuffer_test.cj`）

- [x] 1.1 建 `@Test public class PackageBuffer_test`，加固定夹具构造（`fixtureDoc()`、`withImageDoc()`、`manySheets(2048)`）
- [x] 1.2 写 T3 `bytesViewMustBeConsumedBeforeReuse`：先取 `bytes()` 视图、再在同一 buffer 写新内容，断言旧视图随底层数组变化（钉死 std 视图语义）；应**直接绿**
- [x] 1.3 写 T2 `twoPackageWritesProduceSameParts`：同一文档连写两次、解包逐部件比对；应**直接绿**
- [x] 1.4 写 T4 `partsMatchPinnedBaseline`：把 0.3 抓到的四个小部件字节固化为常量断言（styles 用长度 + 片段），应**直接绿**
- [x] 1.5 写 T1 `reusedPartsEqualFreshParts`（7 类部件 + styles 的复用 vs 新建 + 反向断言：不同输入必须不同）、T5 `alternatingReuseHasNoCrosstalk`（大→小→大）、T6 `garbageInBufferIsCleared`、T7 `bufferGrowsForLargePart`、T8 `drawingPartsUseSharedBuffer`；**T1/T5/T6/T8 在复用缓冲前先复制/序列化上一次视图**
- [x] 1.6 跑 `cjpm test`：确认 T1/T5/T6/T7/T8 因复用重载尚不存在而**红**（编译失败即视为红），T2/T3/T4 绿

## 2. `PackageWriter` 单缓冲改造

- [x] 2.1 顶层加 `internal let OPC_PART_BUFFER_INITIAL_CAPACITY: Int64 = 256 * 1024`，并写明用途注释
- [x] 2.2 `contentTypes` 加复用重载：`buffer!: ByteBuffer`（`std.io.ByteBuffer`）为**第二位必填**参数，进入 `buffer.clear()`，函数体保持原样，末尾 `buffer.bytes()`（视图）；老签名改为委托（内部新建 256 KiB 缓冲）
- [x] 2.3 `rootRels` 同上（`rootRels(buffer: ByteBuffer)`）
- [x] 2.4 `workbookXmlFromNames` 同上（第三位加 `buffer: ByteBuffer`）
- [x] 2.5 `workbookRels` 同上（第二位加 `buffer: ByteBuffer`）
- [x] 2.6 `drawingXml` / `drawingRels` / `sheetRels`：`private` 改 `internal`，加 `buffer: ByteBuffer` 末位参数并按 D2 契约清空/取快照（不保留老签名）
- [x] 2.7 `write()` 内建一个 `ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)`，7 处生成器全部改传它；`styles.xml` 改调 `StylesWriter.write(styles, parts)`
- [x] 2.8 跑 `cjpm test`：T1/T5/T6/T7/T8 转绿（`StylesWriter` 复用重载若还没做，T1 的 styles 段暂时红，见 3.1）

## 3. `StylesWriter` 复用重载

- [x] 3.1 `StylePool.cj`：新增 `write(pool: StylePool, buffer: ByteBuffer): Array<Byte>`（进入 `clear()`、末尾 `bytes()`）；`write(pool)` 改为委托并新建 256 KiB 缓冲
- [x] 3.2 跑 `cjpm test`：T1 的 styles 段转绿

## 4. `ExcelWriter` 对齐

- [x] 4.1 `init` 内用局部 `parts` 串起 4 个前置部件（`contentTypes(..., buffer: parts)` / `rootRels(parts)` / `workbookXmlFromNames(..., parts)` / `workbookRels(..., parts)`）
- [x] 4.2 `finish()` 内用局部 `parts` 调 `StylesWriter.write(styles, parts)`
- [x] 4.3 跑 `cjpm test`：`ExcelWriter_test` / `Style_test` / `RoundTrip_test` 全绿

## 5. 基准（`f_excel/src/Package_bench.cj`）

- [x] 5.1 按设计建 `@Test public class Package_bench`，`init()` 构建固定夹具，输出 sink 预分配并每轮 `clear()`
- [x] 5.2 加用例：`benchPackageWrite`、`benchSevenPartsReused`、`benchSevenPartsFresh`、`benchStylesReused`、`benchStylesFresh`、`benchPartsWithDrawingsReused`、`benchPartsWithDrawingsFresh`；每轮把 `bytes().size` 累加到字段防优化
- [x] 5.3 跑 `cjpm bench`，确认可执行并记录两组参考数据（不作 CI 性能判定）

## 6. 回归与收尾

- [x] 6.1 `cd f_excel && cjpm test` 全量绿（184 + 新增），无新增 warning
- [x] 6.2 检查 `git diff`：XML 生成逻辑内容零改动，只有缓冲来源与 `buffer.clear()`；`public` 声明零变更（`git diff | grep '^[-+].*public'` 应为空或仅与本次无关）
- [x] 6.3 更新 `f_excel/README.md` 的测试计数与相关说明（若新增文件/用例数变化）
- [ ] 6.4 提交（先测后提交），完成后 `git merge --no-ff` 回 `sts/1.3.x-LocalMode` 并推送

## 验收命令

```bash
cd f_excel
cjpm test      # 全绿
cjpm bench     # 复用 vs 新建 对照数据
```
