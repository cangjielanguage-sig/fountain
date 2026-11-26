# 任务：XmlWriter 字节暂存复用

> TDD：先建输出不变性回归网与分配基准（Red：非 ASCII 68 B/rune）→ 切缓冲与转义路径（Green）→ 全量回归。
> 只改 `f_xml` 包内类型；公开 API 0 变化。

## 1. 现状与测量

- [x] 1.1 探针：UTF-8 刷写 `StringGenerator.unsafeBytes()` 为数组视图，64 次刷写共 20,080 B（313 B/次），16 KB 复制不存在（验证：对照探针打印 `oldPerFlush=313`、`newPerFlush=261`，运行后删除）
- [x] 1.2 探针：`StringGenerator.append(r: Rune)` 每非 ASCII 码点新建 4 B 暂存，20000 汉字 1,362,824 B（68 B/rune）；复用暂存 57,536 B（2 B/rune）（验证：探针打印 `oldPerRune=68`、`newPerRune=2`，运行后删除）
- [x] 1.3 确认 `ByteScratch` 已有 `enc` 复用暂存、`putCp`、`reset`、`bytes`、`toUtf8String`（验证：`f_xml/src/ByteScratch.cj:34-101`）

## 2. 回归网与基准（Red）

- [x] 2.1 新增 `f_xml/src/XmlWriterScratch_test.cj`：UTF-8 多段刷写（> 32 KB，含汉字/emoji）与期望字符串逐字节相同（验证：旧实现上通过，锁住输出）
- [x] 2.2 用例：属性值非 ASCII 转义、CDATA `]]>` 拆分、UTF-16LE 多段刷写与一次性写出字节相同、单字节编码不可映射字符仍为 `?`（验证：旧实现上通过）
- [x] 2.3 分配基准：`F_XML_BENCH=1` 时测量 `putCp` 与 `StringGenerator.append(r)` 两条路径，断言 `<= 8 B/rune` 且复用路径总量低于基线 1/8；未开启时打印跳过原因（验证：旧实现上开启基准为 Red：68 B/rune）
- [x] 2.4 `cd f_xml && cjpm test` 全绿（新增行为用例 + 既有套件）（验证：Summary FAILED 0）

## 3. 实现（Green）

- [x] 3.1 `ByteScratch` 增加 `append(text: String)`（`copyTo` 整块搬入），扩容拷贝改 `copyTo`（验证：新增用例与既有 writer 测试通过）
- [x] 3.2 `XmlWriter` 的 `buffer` 由 `StringGenerator` 改为 `ByteScratch`，`appendText` / `flushBuffer` 同步改法（验证：UTF-8/UTF-16LE 输出对拍通过）
- [x] 3.3 `Escaper` 三个方法的 `out` 参数改为 `ByteScratch`，非 ASCII 走 `putCp`（验证：转义与 CDATA 用例通过）
- [x] 3.4 开启 `F_XML_BENCH=1` 重跑基准（验证：`allocPerRune <= 8`，复用总量低于基线 1/8）

## 4. 回归与契约

- [x] 4.1 `cd f_xml && cjpm test` 连续两次全绿（验证：无偶发失败，两次 Summary FAILED 0）
- [x] 4.2 `XmlWriter` / `Escaper` / `ByteScratch` 无 `public` 签名变化（验证：`git diff -- f_xml/src | rg "^[+-].*public"` 只命中新增测试类）
- [x] 4.3 既有 `XmlWriter_test` / `XmlWriterIncremental_test` / `WriterEncoding_test` / `FormatSamples_test` 全通过（验证：按套件过滤运行）

## 5. 产物与提交

- [x] 5.1 镜像 `openspec/changes/reuse-f-xml-writer-scratch/` 到 `f_xml/doc/spec/reuse-f-xml-writer-scratch/`，两份逐文件一致（验证：`diff -r` 仅差 `.openspec.yaml`）
- [x] 5.2 `openspec validate reuse-f-xml-writer-scratch --strict` 通过（验证：输出 `is valid`）
- [x] 5.3 提交到 `feature/local-mode-f-xml-writer`（验证：`git log -1 --stat` 只含预期文件）

## Workflow follow-up

- 推送 `feature/local-mode-f-xml-writer`，合并回 `sts/1.3.x-LocalMode`，合并后再跑 `f_xml` 全量。
- 执行 `opsx:verify`，通过后 `opsx:archive` 并同步主规格。
