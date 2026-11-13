# Proposal

## Why

周期报告现在把每个指标图与拓扑图写成临时文件，再作为邮件附件发送。收件人必须逐个点开附件才能看到图表；移动端与部分 Webmail 对多附件折叠、SVG 附件预览的支持并不一致；报告进程还要依赖可写的临时目录，并在发送后清理——任何一步失败都会留下垃圾文件，或让这一期报告缺图。

把 SVG 直接内联进 HTML 正文后，报告是一封自包含邮件：打开即见图，发送链路不再触碰磁盘，也不再需要「临时目录创建 → 写入 → 发送 → 递归删除」这条生命周期。图表本就由本进程生成，内联不引入新的数据来源，也不改变渠道契约。

## What Changes

- `ReportBuilder` 把 `ChartRenderer.render` / `TopologyRenderer.render` 的结果直接写入 HTML 正文：
  - 每个指标图表包在 `<div class="fprobe-chart">`，`<h4>` 标题为「节点 + 指标 + 当前值/单位」；
  - 拓扑图包在 `<div class="fprobe-topology">`，归入新增的「拓扑」小节；
  - SVG 原样嵌入，不转义、不 base64；若以 `<?xml` 声明开头，先去掉该声明。
- `ReportDraft` 只保留 `subject` / `text` / `html`，删除 `attachments` / `tempDir` / `cleanup()`。
- 删除 `Attachment` / `AttachmentStore` 与 `Attachment_test`：仓库内没有其它调用方。
- `ReportJob.runOnce` 不再清理临时目录，`sendRich` 的附件数组固定为空。
- `SupervisorRuntime` 不再构造 `AttachmentStore`，也不再读取 `probe_reportTmpDir`。
- `probe_reportTmpDir` 不再生效：继续传入不会报错，但不再被读取；文档与 `fprobe.sh` 移除或标注废弃。
- 同步 README（中英）、`doc/configuration.md`、`doc/alarm-rules.md`、`doc/deployment.md` 与 `fprobe.sh`。
- 不新增依赖、不新增公开 API；`AlarmMessageChannel.sendRich` 与 `ReportSender.sendRich` 的签名保持不变。

## Capabilities

### New Capabilities

<!-- 无：本次只改既有 probe-reporting 的报告内容形态。 -->

### Modified Capabilities

- `probe-reporting`: 报告从「HTML 摘要 + SVG 附件」改为「HTML 摘要内联 SVG 图表与拓扑图」，发送时不再携带附件。

## Impact

- 代码：`fprobe/src/report/ReportBuilder.cj`、`fprobe/src/report/ReportJob.cj`、`fprobe/src/runtime/SupervisorRuntime.cj`；删除 `fprobe/src/report/Attachment.cj`；测试 `ReportBuilder_test.cj`、`ReportJob_test.cj`、`ReportTestSupport_test.cj` 调整，删除 `Attachment_test.cj`。
- 配置：无新增键；`probe_reportTmpDir` 从「生效」降为「兼容接受但不读取」。
- 依赖：不变。删除 `Attachment.cj` 后，`std.env` / `f_io` / `f_time` / `f_util` 的直接 import 随之消失，`cjpm.toml` 无需调整。
- 邮件：正文体积随图表数量增长；`EmailAlarmChannel.sendRich` 逻辑不变，空附件时只发 HTML/纯文本。
- 文档：中英 README、配置表、告警规则文档的图表说明、部署文档、`fprobe.sh` 的示例参数。
- 测试：`cd fprobe && cjpm test`，全部离线；`f_chart` 无需改动。

## Non-Goals

- 不做 MIME `multipart/related` / `cid:` 内联图片，也不使用 base64 data URI。
- 不做 SVG 栅格化为 PNG。
- 不改渠道契约；只实现基础方法的渠道仍只收到纯文本。
- 不保留报告批次文件或历史报告归档。

## Risks

- 部分邮件客户端（尤其老版本 Outlook 与企业邮件网关）会剥离 HTML 中的 SVG，图表区域可能留白。这是内联方案的已知取舍，不回退到附件。
- 报告邮件体积增大，收件人邮箱配额与网关单封大小限制可能被触发；本期不做额外压缩。
- SVG 原样进入 HTML 意味着信任边界必须收紧：图表只来自 `f_chart` 与 `TopologyRenderer` 的受控生成；节点名、指标名等用户可控文本只进入 `<h4>`，并且必须经过 HTML 转义，不能拼进 SVG 标记本身。
