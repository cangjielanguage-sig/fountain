# Design

## Context

当前报告链路是「HTML 摘要 + 临时目录里的 SVG 附件」：

- `ReportBuilder.build`（`fprobe/src/report/ReportBuilder.cj:77`）逐指标调用 `ChartRenderer.render`，把结果交给 `AttachmentStore.write` 落盘，再把 `Attachment` 塞进 `ReportDraft.attachments`；拓扑图走 `store.writeRaw("topology.svg", svg)`（`:157`）。HTML 里只写一句「拓扑附件: topology.svg」，图表本身不出现在正文。
- `ReportDraft`（`:27`）携带 `attachments` / `tempDir` / `cleanup()`；`ReportJob.runOnce`（`fprobe/src/report/ReportJob.cj:99`）把附件路径数组交给 `ReportSender.sendRich`，并在 `finally` 里 `draft.cleanup()`。
- `AttachmentStore`（`fprobe/src/report/Attachment.cj:40`）负责建批次目录、清洗文件名、递归删除，是报告链路里唯一碰磁盘的部分。
- `SupervisorRuntime.buildReportJob`（`fprobe/src/runtime/SupervisorRuntime.cj:307`）用 `probe_reportTmpDir` 构造 `AttachmentStore`，这是该配置键唯一的生产读取点。

与本次改造直接相关的既有事实：

- `f_chart` 的每个图表实现都以 `SvgBuilder.toSvgString()` 结尾（`f_chart/src/*.cj`），而该方法固定输出 `<?xml version="1.0" encoding="UTF-8"?>` 前导（`f_svg/src/SvgBuilderM7_test.cj:455` 已固化该契约）；`TopologyRenderer.render`（`fprobe/src/report/TopologyRenderer.cj:38`）同样走 `toSvgString()`。因此「去掉 XML 声明」不是可选的清理，而是所有图表的必经步骤。
- SVG 内部文本由 `f_svg` 自己转义：`escapeSvgText` / `escapeSvgAttribute`（`f_svg/src/SvgElement.cj:705`、`:718`）在序列化时处理文本节点与属性，设备名进入 `<text>` 不会破坏标记。
- 邮件渠道不需要改：`EmailAlarmChannel.sendRich`（`fprobe/src/channel/EmailAlarmChannel.cj:48`）把 `html` 原样放进 `OutgoingMail.html`，附件数组只用于构造 `MailAttachmentSpec`，空数组即纯 HTML 邮件。
- `Attachment` / `AttachmentStore` / `ReportDraft` 虽是 `public`，但 `fprobe` 是应用模块，仓库内没有 `fprobe` 之外的引用（`grep -rn` 确认），可以整体删除而不留兼容壳。

## Goals / Non-Goals

**Goals:**

- 把「图表 → 磁盘 → 附件」替换为「图表 → HTML 正文」，报告生成路径不再有文件系统副作用。
- 保证内联后的 SVG 在邮件客户端里仍是一个合法的 HTML 片段：不带 XML 声明、不被 HTML 转义、不进入属性。
- 让报告 HTML 结构可被机器断言：每个指标图一个 `div.fprobe-chart` + `h4`，拓扑一个 `div.fprobe-topology` + 独立小节。
- 删除附件相关的类、字段与清理逻辑，同时不改变渠道层契约。

**Non-Goals:**

- 不引入 `multipart/related` / `cid:` / data URI 等替代内联方式（见 proposal 的 Non-Goals）。
- 不做正文字节数上限、图表降采样或分页——报告体积问题只在日志里留可观测线索。
- 不改 `f_chart` / `f_svg` 的任何行为，包括 `toSvgString` 的 XML 前导。
- 不做旧临时目录的自动清理或迁移。

## Decisions

### D1：内联 = 原样拼接 `<svg>`，嵌入前剥掉 XML 声明

`ReportBuilder` 新增两个私有工具方法：

```cj
/** 去掉 SVG 的 XML 前导声明；只处理开头，不碰正文。 */
private static func inlineSvg(svg: String): String {
    let text = svg.trimAscii()
    if (!text.startsWith("<?xml")) {
        return text
    }
    match (text.indexOf("?>")) {
        case Some(end) => text[end + 2..].trimAscii()
        case None => text // 畸形输入：原样返回，交给邮件客户端决定
    }
}
```

指标图与拓扑图统一走 `inlineSvg`，再直接拼进 `html` 缓冲区。

**为什么不用 HTML 转义**：转义后收件人看到的是 `<svg ...>` 源码文本，等于没做内联。**为什么不用 `<img src="data:image/svg+xml;base64,...">`**：多数 Webmail 与 Outlook 会屏蔽 `data:` 图片，且 base64 会把体积放大约 33%，正好撞上报告体积的敏感点。**为什么不用 `multipart/related` + `cid:`**：需要改邮件渠道与 MIME 组装，属于 proposal 明确排除的范围。

**为什么必须剥声明**：`toSvgString()` 固定输出 `<?xml ...?>`，把它放进 `<body>` 会让 HTML 解析器进入 bogus comment 状态，部分客户端直接吞掉后续标记。剥声明是唯一一处对 SVG 文本的改写，除此之外一律原样。

### D2：`ReportDraft` 收缩为 `subject` / `text` / `html`

```cj
public class ReportDraft {
    public let subject: String
    public let text: String
    public let html: String

    public init(subject: String, text: String, html: String) { ... }
}
```

`tempDir`、`attachments`、`cleanup()` 一并删除，同时删掉 `ReportBuilder.cj` 里 `f_io.removeIfExists` 的 import。

**备选：保留字段但恒为空数组**——会留下一个永远为空、且没有任何写入者的公开字段，后来者无法从类型上判断它是否还有意义；仓库内也没有需要二进制兼容的调用方，直接删除更诚实。

### D3：删除 `Attachment` / `AttachmentStore` / `Attachment_test`

`fprobe/src/report/Attachment.cj` 与 `Attachment_test.cj` 整体删除。`std.env`、`f_io`、`f_time`、`f_util` 在 `fprobe` 内仍有其它使用者，`cjpm.toml` 不变。

**备选：保留 `AttachmentStore` 供将来导出报告文件**——没有需求支撑，且正是这次要去掉的磁盘依赖；将来真要做「报告存档」应重新设计而不是复用临时目录语义。

### D4：`ReportBuilder` 构造签名去掉 `store`

```cj
public init(selector: ChartSelector, renderer: ChartRenderer, clock: Clock,
    logInfo!: (String) -> Unit = {message => println(message)},
    logWarning!: (String) -> Unit = {message => eprintln(message)})
```

结尾日志从 `'报告批次 ${store.dir} 生成 ${attachments.size} 个附件'` 改为 `'报告生成 ${chartCount} 张图表，HTML ${htmlBytes} 字节'`：报告体积的观测点必须留在日志里，否则 D1 的体积风险不可观测。`chartCount` 与 `htmlBytes` 在 `build` 内累加/计算。

### D5：指标块用 `div.fprobe-chart` 承载标题与 SVG，失败的图表退化为纯文本行

有图表时：

```html
<div class="fprobe-chart">
  <h4>web1 CPU 使用率 (cpu.usagePercent)：95.0 %</h4>
  <svg ...>...</svg>
</div>
```

图表生成失败（`renderer.render` 抛异常）时退化为 `<p>CPU 使用率 (cpu.usagePercent): 95.0 %</p>`，与改造前的指标行完全一致。

**为什么把当前值从 `<p>` 挪进 `<h4>`**：`<h4>` 已经是「节点 + 指标 + 当前值/单位」的标题，再保留一条同内容的 `<p>` 会在同一视觉块里重复两遍数值。**为什么失败时用 `<p>` 而非空 div**：图表失败不能让指标从报告里消失，规格里「其余图表与报告发送不受影响」要求数值仍然可见。

标题里的三段都用既有 `escape`（`ReportBuilder.cj:205`）转义——节点名与指标标签来自配置/探测数据，属于不可信文本；SVG 不转义（D6）。

`<h4>` 而非 `<h3>`：`<h3>` 已被节点名占用（`:98`），保持「h2 章节 / h3 节点 / h4 指标」的层级。

### D6：拓扑进入独立的「拓扑」小节

```html
<h2>拓扑</h2>
<div class="fprobe-topology">
  <svg ...>...</svg>
</div>
```

纯文本对应一行 `拓扑: 已内联（<设备数> 个设备 / <链路数> 条链路）`，不再出现 `topology.svg`。`TopologyRenderer.render` 返回 `None`、或 `topology` 为 `None` 时，HTML 写 `<p>拓扑不可用</p>`、纯文本写 `拓扑不可用`（与改造前一致）。

**为什么保留 `TopologyRenderer.render` 的 `?String`**：`None` 的语义是「设备列表为空」，这是渲染器的输入契约，不该由 `ReportBuilder` 再判一次；改动它会把边界判断分散到两处。渲染器抛异常时由 `ReportBuilder` 捕获并按 `None` 处理，同样写「拓扑不可用」，避免一份坏拓扑中断整封报告。

**为什么统计设备/链路数**：内联后拓扑图没有文件名可供辨认，纯文本摘要需要一点可核对的量纲；数量直接取自 `TopologySample`，不额外计算。

### D7：转义边界——SVG 原样，HTML 自由文本一律 `escape`

内联路径上只有两类文本：

| 文本 | 去处 | 处理 |
| --- | --- | --- |
| 节点名、指标标签、当前值/单位、告警消息 | `<h3>` / `<h4>` / `<p>` | `escape()` |
| 图表 SVG、拓扑 SVG | `<div>` 内部 | 原样，仅去 XML 声明 |

SVG 内部的安全性由生产者保证：`f_chart` 与 `TopologyRenderer` 都经 `f_svg` 序列化，文本节点与属性分别走 `escapeSvgText` / `escapeSvgAttribute`。这条依赖必须在设计里写死：**新增任何其它 SVG 来源之前，必须先确认它自己做了转义**，否则内联就是把注入点开在邮件正文里。

配套用例：节点名取 `web1<img src=x onerror=alert(1)>`，断言 HTML 中该字符串被转义、且 `<div class="fprobe-chart">` 数量与图表数一致。

### D8：`sendRich` 契约不变，`ReportJob` 传空数组并删掉 `finally`

`ReportSender.sendRich(message, html, attachments: Array<String>, receivers)` 与 `f_probe.AlarmMessageChannel.sendRich` 的签名保持不变，`ReportJob.runOnce` 改为：

```cj
public func runOnce(): Unit {
    let draft = builder()
    try {
        sender.sendRich(draft.text, draft.html, [], receivers)
    } catch (e: Exception) {
        logError('报告发送失败: ${e.message}')
    } catch (e: Error) {
        logError('报告发送失败: ${e.message}')
    }
}
```

**备选：把 `attachments` 参数从接口里删掉**——`ReportSender` 是 `fprobe` 内部端口，但 `AlarmMessageChannel` 是跨模块契约，删参数会波及所有渠道实现与 `ChannelDispatcher.dispatchRich`；本次的目标是「不产生附件」，不是「不支持附件」。

`finally { draft.cleanup() }` 随之删除：没有临时目录，就没有需要抵消的副作用；保留一个空的 `finally` 只会误导读者。

### D9：`probe_reportTmpDir` 从「生效」降为「接受但不读」

`SupervisorRuntime.buildReportJob` 中的构造改为：

```cj
let builder = ReportBuilder(ChartSelector(), ChartRenderer(), SystemClock())
```

配置项本身不从 `Validation` 里删：仓库没有「未知键报错」的校验逻辑（`fprobe/src/config/` 下无相关分支），删键对老配置文件没有任何收益，反而会让升级检查清单多一条。文档中标注为「已废弃：保留以兼容旧配置，报告不再落盘」。

### D10：测试改造以断言正文结构为主

- `ReportBuilder_test`：
  - 断言 `<div class="fprobe-chart">` 出现次数等于成功渲染的图表数；
  - 断言正文含 `<svg`、不含 `<?xml`、不含 `web1-cpu_usagePercent.svg`；
  - 断言 `<h4>` 同时含节点名、指标标签与当前值/单位；
  - 新增「图表抛异常 → 退化为 `<p>` 且报告仍生成」用例；
  - 新增「拓扑内联 → `<div class="fprobe-topology">` 出现、纯文本含设备/链路数且不含 `topology.svg`」用例。
- `ReportTestSupport_test`：新增 `XML_SVG`（带 `<?xml version="1.0" encoding="UTF-8"?>` 前导的固定 SVG）用于覆盖 D1 的剥离分支；`reportTempDir()` 与 `std.fs.Directory` 引用在 `AttachmentStore` 删除后若无使用者则一并删除。
- `ReportJob_test`：`draftWith` 改为直接构造三字段 `ReportDraft`；断言 `FakeSender` 收到的附件数组为空；删除「发送后清理临时目录」相关断言。
- `Attachment_test.cj` 删除。

### D11：文档与脚本同步，一次改到位

`fprobe/README.md`、`fprobe/README_en.md`、`fprobe/doc/configuration.md`、`fprobe/doc/alarm-rules.md`、`fprobe/doc/deployment.md`、`fprobe/fprobe.sh` 中所有「SVG 附件 / 临时目录」表述改为「图表内联在 HTML 正文」，`probe_reportTmpDir` 统一标注废弃。

## Risks / Trade-offs

- **邮件客户端剥离内联 SVG**（企业网关、老版 Outlook）→ 图表区域留白。缓解：`<h4>` 已包含节点、指标与当前值，即使 SVG 被剥离，读者仍能拿到数值；纯文本摘要始终完整。
- **正文体积随图表数线性增长**，可能触发网关单封大小限制 → 缓解：日志记录图表数与 HTML 字节数（D4），运维据此裁剪 `probe_chart_*` 的指标范围；本期不做压缩或降采样。
- **信任边界收窄为「SVG 只来自 `f_chart` / `TopologyRenderer`」** → 缓解：D7 把这条约束写进设计，并由「节点名注入」用例守住 HTML 侧；SVG 侧依赖 `f_svg` 的转义，属于既有能力。
- **删除 `public` 类属于编译期破坏性变更** → 缓解：仓库内无 `fprobe` 之外的引用，`cjpm test` 会立刻暴露遗漏；不提供兼容层。
- **`probe_reportTmpDir` 变成静默无效项**，使用者可能以为报告仍写盘 → 缓解：三处文档与 `fprobe.sh` 明确标注废弃，日志不再出现批次目录路径。
- **旧临时目录残留**（升级前生成的 `./data/fprobe-report/*`）→ 不自动删除：清理用户数据属于运维决策，文档在部署说明里给出手工删除提示。

## Migration Plan

1. 代码与测试一次性合入：先删 `Attachment` 相关代码，再改 `ReportBuilder` / `ReportJob` / `SupervisorRuntime`，最后按 `cjpm test` 的红灯逐个补齐断言。
2. 升级无需数据迁移：旧配置里的 `probe_reportTmpDir` 保持可解析、只是不再读取；旧批次目录不会被访问。
3. 回滚：`git revert` 该提交即可恢复附件路径，但被删的 `Attachment.cj` 恢复后需要重新验证 `ReportJob` 的清理逻辑——因此发布前应在预发环境完整跑一次 CRON 报告。
4. 发布后观察点：报告邮件正文是否含 `<svg>`、日志中的「报告生成 N 张图表，HTML M 字节」、临时目录是否不再新增批次。
