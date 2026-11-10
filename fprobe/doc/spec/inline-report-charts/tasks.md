# Tasks

> 顺序按 design「Migration Plan」：先让 `ReportBuilder` 产出内联正文（含测试），再收缩
> `ReportDraft` 与删除附件基础设施，然后改发送链路，最后同步文档。每一组自带该组的
> 测试与文档，不把测试堆到末尾。

## 1. 内联图表与拓扑（ReportBuilder）

- [x] 1.1 在 `fprobe/src/report/ReportTestSupport_test.cj` 新增 `XML_SVG` 夹具（以 `<?xml version="1.0" encoding="UTF-8"?>` 开头，后接一个最小合法 `<svg>`），验证：`cd fprobe && cjpm test` 编译通过，且 1.2 的用例引用该夹具后能断言声明被剥离
- [x] 1.2 先写失败用例：用 `XML_SVG` 生成一张指标图，断言 `draft.html` 含 `<svg`、不含 `<?xml`，再在 `ReportBuilder` 内实现 `private static func inlineSvg`（`trimAscii` 后若以 `<?xml` 开头则截到第一个 `?>` 之后，畸形输入原样返回）；验证：该用例由红转绿，且无声明输入的 `FIXED_SVG` 输出与输入逐字节相等
- [x] 1.3 指标块改为 `<div class="fprobe-chart">` 包裹 `<h4>` 与内联 SVG，`<h4>` 文本为「节点 + 指标标签 + 当前值/单位」；验证：新增用例断言 `<div class="fprobe-chart">` 出现次数等于成功渲染的图表数、`<h4>` 同时含 `web1`、`CPU 使用率`、`95.0 %`，且 HTML 不再含 `web1-cpu_usagePercent.svg`
- [x] 1.4 图表渲染抛异常时退化为 `<p>指标标签: 当前值 单位</p>` 且不产生 `div.fprobe-chart`；验证：新增用例用抛异常的 `Chart` 替身断言退化行存在、其余图表数不变、`build` 未抛出
- [x] 1.5 拓扑改为独立 `<h2>拓扑</h2>` 小节加 `<div class="fprobe-topology">` 内联 SVG，纯文本写 `拓扑: 已内联（N 个设备 / M 条链路）`；验证：新增用例用 `TopologySample` 断言 div 与 `<svg` 出现、纯文本含设备数与链路数、全文不含 `topology.svg`；另保留 `None` 输入用例断言「拓扑不可用」
- [x] 1.6 转义边界用例：节点名取 `web1<img src=x onerror=alert(1)>`，验证：断言该字符串在 HTML 中以 `&lt;img` 形式出现、原文标记不出现，且 `<div class="fprobe-chart">` 计数不受影响
- [x] 1.7 结尾日志改为 `'报告生成 ${chartCount} 张图表，HTML ${htmlBytes} 字节'`（`chartCount` 在 `build` 内累加、`htmlBytes` 取拼接结果的 UTF-8 字节数），验证：用例注入 `logInfo` 收集器，断言日志含正确图表数，且不再含批次目录路径

## 2. 收缩 ReportDraft 并删除附件基础设施

- [x] 2.1 `ReportDraft` 改为只含 `subject` / `text` / `html` 三字段，删除 `attachments` / `tempDir` / `cleanup()` 及 `f_io.removeIfExists` 导入；验证：`ReportJob_test.cj` 的 `draftWith` 同步改为三字段构造后 `cjpm test` 编译通过
- [x] 2.2 `ReportBuilder.init` 去掉 `store: AttachmentStore` 参数与 `this.store` 字段，`build` 内不再调用 `store.write` / `store.writeRaw`；验证：`cjpm build` 通过，`grep -rn "store\." fprobe/src/report/ReportBuilder.cj` 无命中
- [x] 2.3 删除 `fprobe/src/report/Attachment.cj` 与 `Attachment_test.cj`；验证：`grep -rn "AttachmentStore\|reportTempDir" fprobe/src` 无残留（`reportTempDir()` 无使用者时从 `ReportTestSupport_test.cj` 一并删除，`std.env` / `std.fs` 导入随之清理），`cjpm test` 全绿

## 3. 发送链路与运行期装配

- [x] 3.1 `ReportJob.runOnce` 改为 `sender.sendRich(draft.text, draft.html, [], receivers)` 并删除 `finally { draft.cleanup() }`，同步更新方法注释；验证：`ReportJob_test` 断言 `FakeSender` 收到的附件数组长度与内层数组均为 0，并删除「发送后清理临时目录」的断言
- [x] 3.2 `SupervisorRuntime.buildReportJob` 改为 `ReportBuilder(ChartSelector(), ChartRenderer(), SystemClock())`，不再读 `probe_reportTmpDir`、不再构造 `AttachmentStore`；验证：`grep -rn "probe_reportTmpDir\|AttachmentStore" fprobe/src` 无命中，`cd fprobe && cjpm test` 全绿

## 4. 文档与脚本

- [x] 4.1 `fprobe/README.md` 与 `fprobe/README_en.md`：把「SVG 附件 / 落盘目录」表述改为「图表内联在 HTML 正文」，`probe_reportTmpDir` 标注为已废弃但保留兼容；验证：`grep -n "附件" fprobe/README.md` 与 `grep -n "attachment" fprobe/README_en.md` 的结果中不再有描述「报告发送附件」的段落
- [x] 4.2 `fprobe/doc/configuration.md`：`probe_reportTmpDir` 一行改为「已废弃：保留以兼容旧配置，报告不再落盘」；验证：打开该表核对 4.1、4.2 两处措辞一致
- [x] 4.3 `fprobe/doc/alarm-rules.md` 与 `fprobe/doc/deployment.md`：图表说明改为内联、部署说明去掉临时目录权限要求并补充「旧批次目录需手工删除」提示；验证：两文件内 `probe_reportTmpDir` 与「临时目录」表述均已处理，无残留「需可写临时目录」的要求
- [x] 4.4 `fprobe/fprobe.sh` 两处 `--probe_reportTmpDir` 示例加注「已废弃」；验证：`bash -n fprobe/fprobe.sh` 通过，`grep -n "probe_reportTmpDir" fprobe/fprobe.sh` 两行均带废弃标注

## 5. 集成验收

- [x] 5.1 在 `fprobe` 下执行 `cjpm build && cjpm test`，确认全部用例通过且无新增告警；验证：命令退出码为 0，测试汇总行显示失败数为 0
- [x] 5.2 端到端核对报告产物：用一个可控 `HistorySource` + 真实 `ChartRenderer` 生成一次 `ReportDraft`，验证：`html` 同时含 `<div class="fprobe-chart">`、`<div class="fprobe-topology">` 与 `<svg`，不含 `<?xml`，且 `draft` 上已无附件相关字段可访问

## Workflow follow-up

- 评审通过后执行 `/opsx:apply inline-report-charts`，逐任务 TDD，测试全绿再勾选。
- verify 通过、CRITICAL 清零后执行 `/opsx:archive inline-report-charts`，并用最终版覆盖 `fprobe/doc/spec/inline-report-charts/`。
- 归档后把 `feature/fprobe` 合入 `sts/1.3.x` 并推送；保留 `feature/fprobe`，不删除分支。
