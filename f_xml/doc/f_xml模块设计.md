# f_xml —— 仓颉 XML 解析 / 生成模块设计

> 版本 **v1.1** ｜ 2026-10-24 ｜ 状态：待评审
>
> 定位：fountain 的**通用 XML 模块**。**流式事件解析 → 构建 DOM**；**从 DOM 生成 XML**。
>
> **不绑定任何业务格式。** RSS / Atom、SVG、SOAP、Maven POM、Android 布局、OOXML 系列、任意配置文件——只要是 XML 1.0，这个模块就该能用。它不理解任何业务标签，只负责把 XML 讲清楚。
>
> v1.0 → v1.1（一项纠错）：
> - **`unsafeBytes()` 不是快照拷贝，是原始数据（零成本）**。v1.0 按"每次调用 O(n) 拷贝"推断是错的（10.2）
> - 但"不要缓存、要用就重新取"的建议仍成立——扩容会换底层数组
>
> v0.9 → v1.0（四项确认）：
> - `unsafeBytes()` 是**快照语义**：append 后旧数组不失效，但也**不含新内容**（10.2）
> - `XmlWriter.close()` 之后再取是**未定义行为**，写进类注释（10.2）
> - `xml` / `xmlns` 前缀的跳过规则**覆盖属性名与元素名**（13.4.2）
> - `AttributeValue` 超限的错误消息**带属性名**（5.4.2）
>
> v0.8 → v0.9（四项确认）：
> - `unsafeBytes()` **返回内部字节数组且已剪除冗余容量**，不需配合 size 截断（10.2）
> - `StringGenerator` **非线程安全**，`XmlWriter` 单线程使用（10.2）
> - `EntityLimitKind.AttributeValue` 独立分类确认（9）
> - `assumeQNameInValues` **必须跳过 `xml` / `xmlns` 两个保留前缀**（13.4.3）
>
> v0.7 → v0.8（四项决策落定）：
> - `XmlException` 新增 **`entityLimitKind`**，区分软阈值与硬限制（9 / 5.4.1）
> - 文本累积用 **`fountain::f_base.StringGenerator`**，不用 `std.core.StringBuilder`（10.2）
> - `defaultNamespace` 与 `namespaces` 的分工写进文档（13.3.1）
> - `C14nOptions` 新增 **`assumeQNameInValues`**，宁多勿漏开关（13.4.2）
>
> v0.6 → v0.7（三项决策落定）：
> - **`defaultNamespace` 改为严格标准兼容语义**：存在时无前缀名字**只**按它匹配，
>   不再"先找无命名空间再兜底"（13.3.1）
> - 恶意样本测试固定 `EntityOverflowPolicy.Strict`，正常文档测试用 `Spill`（12.8 / 14.2）
> - `C14nOptions.withComments` 默认 `false` 确认（签名场景不用注释）
>
> v0.5 → v0.6（四项决策落定）：
> - `EntityLimits` 超限**不再直接失败**，改为**溢出到临时文件续跑**（5.4.1）；
>   新增硬上限 `maxExpandedHardLimit` 防止磁盘被写爆
> - **回调签名保留 `XmlAction` 返回值**，新增**单回调 lambda 重载**；明确**不采纳**
>   `stop()` / `skipCurrentElement()`（3.4 详细解释）
> - **XPath M2 支持命名空间前缀**：新增 `XPathContext`，并说明 XPath 1.0
>   默认命名空间的反直觉规则（13.3）
> - **C14N 同时做 inclusive 与 exclusive**：`C14nMode` 三值，exclusive 支持 `InclusiveNamespaces`（13.3）
>
> v0.1 → v0.2：明确通用定位，移除全部业务格式专属描述——下游怎么用这个模块，写在各下游模块自己的文档里。
>
> v0.2 → v0.3：
> - **完全自研，不参考任何现有 XML 实现**（删去「评估 `xml_stream`」这一备选方案）
> - 确定字符层：解析用 `std.io.StringReader` / `charset4cj.TextReader`，生成用 `std.io.StringWriter` / `charset4cj.TextWriter`
> - 新增 2.1~2.5：字节嗅探、按行取字符、两套 Reader 分工、已知缺陷与规避
> - 删去「与其他实现做差分测试」；**验收基准定为 W3C xmlconf 20130923**（已确认），可跑断言 1937 条
>
> v0.3 → v0.4（九项决策落定）：
> - **支持 DTD 内部子集实体**（普通 + 参数），外部实体仍不加载；新增三层膨胀上限（5.4）
> - 回调改为返回 `XmlAction`，新增**拉模式**与 **`skipElement()`**（3.2 / 3.3）
> - 生成侧新增 **CDATA 模式**与**自定义实体**（7.5 / 7.6）
> - `PrefixStream` 归入 `f_io`（1.4）；`bufSize` 可配（`XmlParserOptions`）——**其中 PrefixStream 的归属在 v0.5 已改回 f_xml**
> - 引入 **M1 / M2 / M3 里程碑**：XPath 进 M2，XML 1.1 与 C14N 进 M3（13 章）
> - xmlconf 可断言数从 1937 提升到 **2154**（内部实体用例 228 条进可跑集，12.4）；
>   最终（五条排除规则）为 **可跑 2062 / 断言 2038**，实测全部通过，见 12.4
>
> v0.4 → v0.5：
> - **输入只认 `std.io.InputStream`**：`Array<Byte>` / `String` / 文件 / TCP / UDP 都行，
>   `f_io.ByteBuffer` 可传入但**不依赖**（1.4）
> - `PrefixStream` 改为 **f_xml 自实现**（f_io 保持现状、不再增补）
> - 新增 2.7：`InvalidByteMode`（读）与 **`InvalidCharMode`（写）**，
>   后者用往返校验绕开 charset4cj 未声明的不可映射字符行为

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 适用范围 | 通用 XML 1.0（含命名空间），**不绑定任何业务格式** |
| 解析模式 | **推模式**（`XmlEventHandler` 回调）+ **拉模式**（`nextEvent()`），共用同一词法器 |
| DOM 构建 | 由 `DomBuilder`（一个事件处理器）把事件流累积成树 |
| 生成模式 | 从 DOM 树序列化；**CDATA 模式**（`auto` / `always` / `never`）、**自定义实体引用** |
| 里程碑 | **M1** 解析/DOM/生成/内部实体；**M2** XPath 1.0 子集（**含命名空间前缀**）；**M3** XML 1.1 + C14N（**inclusive 1.0/1.1 + exclusive**） |
| 命名空间 | 支持（`xmlns` / `xmlns:prefix` → `QName{prefix, local, uri}`） |
| DTD 内部子集实体 | **支持展开**（普通实体 + 参数实体）；软阈值超限**溢出到临时文件**续跑，硬限制拦截（5.4.1） |
| 外部实体 / 外部 DTD 子集 | **不加载**。`SYSTEM` / `PUBLIC` 一律不发起请求——XXE 与 SSRF 的防线 |
| 跳过子树 | `skipElement()`，推 / 拉两种模式都可用 |
| 编码（解析） | 字节层嗅探：BOM → 声明 → 默认 UTF-8；覆盖 UTF-8 / UTF-16 / UTF-32 / GBK 等 |
| 编码（生成） | 由 `charset4cj` 指定，默认 UTF-8 |
| 字符层（读） | UTF-8 → 自研 `Utf8Strict` / `Utf8ReplaceDecoder` 字节解码；其他编码 → `charset4cj.TextReader` |
| 字符层（写） | UTF-8 → `std.io.StringWriter`；其他编码 → `charset4cj.TextWriter` |
| 数据源 | 只认 `std.io.InputStream`：`Array<Byte>` / `String` / 文件 / TCP / UDP / 任意 ByteBuffer 实现；**不依赖 `f_io.ByteBuffer`** |
| 失败策略 | 读 `InvalidByteMode`（Strict / Replace）、写 `InvalidCharMode`（Throw / Replace），默认都严格（2.7） |
| 依赖 | `charset4cj`（包 `charset4cj.charset`，跟随最新发布版）+ 标准库，**无其他第三方依赖** |
| 验收基准 | W3C xmlconf **20130923**：2586 条用例中可跑 **2062** 条，**断言 2038 条**（五条排除规则，Gate A 实测全过，详见 12.4） |

**两种用法并存，不是二选一——按文档规模选**：

```
小文档（几 KB ~ 几 MB）
  配置文件、SOAP 响应、RSS、POM、单条协议消息
  → parse() 直接得到 DOM，用着方便

大文档（几十 MB ~ GB 级）
  数据导出的 XML、日志式 XML、几十万条记录
  → 传自定义 handler 流式消费，不建树
```

判断标准很简单：**DOM 的内存开销约是 XML 体积的 5~10 倍**。10 MB 的文档建树峰值可能到 100 MB，这类就必须走事件流。

---

## 1. 定位与依赖

### 1.1 在模块链里的位置

```
                 ┌───────────────┐
                 │    f_xml      │  ← 本文档（通用 XML 能力）
                 │ charset4cj 编码│
                 └───────┬───────┘
                         │ 被使用
        ┌────────────────┼─────────────────┐
        ▼                ▼                 ▼
   RSS / Atom 阅读器   SVG / SOAP 处理   任意业务侧 XML
```

**f_xml 不依赖任何业务模块，也不为某个业务模块定制接口。** 它只提供 XML 本身的能力：切词、事件、DOM、序列化、命名空间、转义。

一个消费者需要什么，就看它能用这些原语组合出来什么：

| 消费者类型 | 典型用法 | 模式 |
|---|---|---|
| 配置 / POM 解析 | 整个文档建 DOM，按路径取值 | DOM |
| RSS / Atom 阅读器 | 整个 feed 建 DOM，按 `<item>` 取字段 | DOM |
| SVG / SOAP 处理 | 建 DOM，改节点，再序列化 | DOM + 生成 |
| 记录式 XML（日志、流水、清单） | 逐条事件消费，从不建树 | 事件流 |

### 1.2 自研范围与边界

**完全自研，不参考任何现有 XML 实现。** 包括不阅读、不移植、不比对 `xml_stream`、`xml-ffi`、expat、libxml2、RapidXML 等实现的代码与结构。

理由是这类实现都带着多年积累的兼容性补丁和特例分支，照搬会把别人的历史包袱一并继承，而且很难分辨哪些分支是真正的规范要求、哪些只是迁就某个畸形文件。

**唯一的行为依据是 XML 1.0 规范（含 Namespaces in XML 1.0）。** 规范没写的行为不做，规范写了的必须做，规范允许实现自决的（属性顺序、空白保留策略等）在本文档里写明选择。

自研与外部依赖的分界：

| 层 | 谁实现 |
|---|---|
| 字节 → 字符 | 自研 `Utf8Strict` / `Utf8ReplaceDecoder`（UTF-8）/ `charset4cj.TextReader`（其他编码） |
| 字符 → 语法元素 | **f_xml** |
| 语法元素 → 事件 | **f_xml** |
| 事件 → DOM | **f_xml** |
| DOM → 字节 | `std.io.StringWriter` / `charset4cj.TextWriter` |
| 字符集编解码 | `charset4cj` |

分界的原则：**编码转换是通用能力，交给专门的库；XML 语义是本文档的全部职责，一行都不外借。**

### 1.3 依赖与版本

```toml
[dependencies]
"fountain::f_base" = {path = "../f_base"}
"cangjie_tpc::charset4cj" = "1.0.5"
```

| 项 | 实测值 | 说明 |
|---|---|---|
| 中心仓版本 | **v1.0.5** | 与仓库其它 9 个模块统一（`f_base` / `f_zip` / `f_process` / `f_httpclient` …） |
| 包名 | `charset4cj.charset` | 1.0.5 的导入路径**已经**是 `charset4cj.charset.*`；「1.0.6 才改布局」不成立 |
| 公开再导出 | `Charset` / `Charsets` | `XmlWriterOptions.charset` 出现在公开 API，`f_xml` 需 `public import` 这两个类型，否则调用方无法命名它 |
| 声明工具链 | `cjc-version = "1.2.0"` | 本地 1.3.0 实跑通过 |

> **一个必须知道的历史包袱**：`charset4cj` 的 master 分支停留在 `cjc_version 0.39.8`，代码里用的是 0.x 时代的 `Char` 类型。**仓颉 1.x 没有 `Char`，只有 `Rune`**（实测 `cjc` 报 `undeclared type name 'Char'`）。1.0.5 标签已全部改为 `Rune`，但**必须锁定标签/版本，不能取 master**。

### 1.4 输入抽象：只认 `InputStream`

**f_xml 不依赖 `f_io.ByteBuffer`，也不依赖任何具体的缓冲区实现。** 它只认 `std.io.InputStream`。

```cangjie
public static func parse(input: InputStream, options!: XmlParserOptions = XmlParserOptions()): XmlDocument
public static func parse(bytes: Array<Byte>, options!: XmlParserOptions = XmlParserOptions()): XmlDocument
public static func parse(text: String, options!: XmlParserOptions = XmlParserOptions()): XmlDocument
public static func parse(path: Path, options!: XmlParserOptions = XmlParserOptions()): XmlDocument
```

| 数据源 | 怎么进来 |
|---|---|
| `Array<Byte>` | `parse(bytes)`，内部包成字节流 |
| `String` | `parse(text)`，已是字符，跳过节流 |
| 文件 | `parse(path)`，`File` 本身就是 `InputStream` |
| **TCP / UDP** | 直接把 socket 的 `InputStream` 传进来 |
| `f_io.ByteBuffer` | **也能直接传**——它实现了 `InputStream`，但 f_xml **不 import 它** |

最后一行是这条设计的要点：**"支持 ByteBuffer" 与 "依赖 ByteBuffer" 是两件事。**
参数类型是 `InputStream`，任何实现了该接口的缓冲区都能用，而 f_xml 的依赖表里不需要出现它。

#### `PrefixStream` 由 f_xml 自己实现

字节嗅探会消费掉流开头的几个字节（BOM、`<?xml ...?>`），而 `InputStream` 不可回退，
所以需要一个"把已读前缀接回流头部"的适配器。

上一版把它放到 `f_io`。**现改为 f_xml 自实现**——`f_io` 已决定保持现状、不再增补能力，
而这段逻辑只有 40 行左右，放在字符层里反而内聚（嗅探与回放本来就是同一件事）。

```cangjie
package fountain::f_xml

/// 把一段已读出的前缀接回到原流头部
class PrefixStream <: InputStream {
    init(prefix: Array<Byte>, rest: InputStream)
    func read(buffer: Array<Byte>): Int64
    func close(): Unit
}
```

三条约定：

1. `prefix` 先出、`rest` 后接；读完后 `rest` 自然结束，`close()` 关闭 `rest`
2. `prefix` 是 `Array<Byte>` 而非 `InputStream`——它的来源就是"刚从 rest 读出来的那几个字节"
3. 不做任何编码判断，纯字节搬运

#### TCP / UDP 的两条注意

两者都是**不可回退的顺序流**，与文件不同：没有 `length`、不能 `seek`。

1. **不要 `readAll()` 之后才解析。** 那样对 TCP 长连接意味着"永远不返回"——
   连接不关闭就没有 EOF。必须边读边解析，读到能产出一个事件就产出一个。
2. **DOM 模式对网络流是"读到 EOF"语义。** `parse(input)` 建 DOM 会一直读到连接关闭才返回；
   长连接、流式推送场景只能用事件模式（推或拉）。

> 这也是 `parse(InputStream)` 和 `parse(path)` 在实现上必须分开考虑的原因：
> 前者不能假设"有尽头"，后者可以。

---

## 2. 总体架构

```
字节流
  │
  ▼
┌──────────┐   事件   ┌──────────────┐   ┌─────────┐
│  Lexer   │ ───────▶ │ EventHandler │──▶│   DOM   │
│ 词法分析  │          │  事件处理器   │   │  树      │
└──────────┘          └──────────────┘   └─────────┘
      ▲                      │
      │                      │ 可中断（返回控制指令）
      └──────────────────────┘
```

三层职责：

| 层 | 职责 | 不做的事 |
|---|---|---|
| **Lexer** | 把字节切成语法元素，处理实体、CDATA、注释、PI、DTD 跳过 | 不校验元素配对、不建树 |
| **Event** | 每个语法元素对应一次回调 | 不关心谁在听 |
| **Handler** | 决定"下一步做什么" | 不碰字节 |

**"由事件触发下一步做什么"具体指**：

- `DomBuilder` 收到 `onStartElement` → 压栈、新建节点；收到 `onEndElement` → 弹栈、挂到父节点
- `ItemStreamHandler` 收到 `onEndElement(item)` → 立刻把这条记录交给上层处理，然后丢弃，不再保留
- 消费方可以在 `onStartElement` 里返回 `Stop` → 解析器立即终止（例如"只读前 100 行"）

---

### 2.1 字符层：输入从哪来

架构图里「字节流 → Lexer」这一步，实际拆成五层：

```
InputStream（原始字节）
   │
   │ ① 字节嗅探（f_xml 实现）
   │    · 前 4 字节判 BOM：EF BB BF / FF FE / FE FF / 00 00 FE FF
   │    · 无 BOM 时按 XML 1.0 附录 F 的魔数判 UTF-16 字节序
   │    · 再读前 1 KB 找 <?xml ... encoding="..."?>
   │    → 得到 charset；已读字节进回放缓冲
   ▼
PrefixStream（f_xml 实现，见 1.4）
   │  把「已嗅探的前缀」+「原流剩余」拼成连续 InputStream
   ▼
 ┌──────────────────────────────┐
 │ UTF-8 ？                      │
 │   是 → Utf8Strict / Replace   │
 │   否 → charset4cj.TextReader  │
 └──────────────────────────────┘
   │  readln() 逐行取 String
   ▼
LineSource（f_xml 实现）
   │  行拼接 + 行号/列号跟踪
   ▼
CharWindow（f_xml 实现）
   │  peek(k) / advance() / mark()
   ▼
Lexer
```

**三个组件全部由 f_xml 自己实现**（不引入 f_io，也不依赖任何缓冲区）：

| 组件 | 为什么不能省 |
|---|---|
| 字节嗅探 | 两个 Reader 都要求调用方**预先给定** charset，都不做 BOM 检测；charset4cj 的 README 明确写 BOM 支持「待开发」 |
| `PrefixStream` | 嗅探消费了字节，而 `InputStream` 不可回退；`std.io` 没有 pushback 流。f_io 保持现状，所以自己写（约 40 行） |
| `CharWindow` | **两个 Reader 都没有 `peek`、没有位置信息**，而词法器至少要 1~4 字符前瞻：读到 `<` 之后必须判断下一个是 `/`、`?`、`!` 还是名字首字符 |

### 2.2 为什么按「行」取，不按「字符」取

`TextReader` 提供了 `read(): Option<Rune>`，看起来正是词法器要的接口。**但它不能用于逐字符扫描**，两个原因：

| 问题 | 代码位置 | 代价 |
|---|---|---|
| 每次调用新建解码器 | `read()` 函数体内 `var decoder = charset.newDecoder()` | 每字符一个对象 |
| 每次调用搬整个缓冲 | `rotateLeft(srcIndex)` 内 `for i in index..buf.size` | 每字符最多搬 8192 字节 |

逐字符读 1 MB 文档 ≈ 100 万次 `newDecoder` + 100 万次 8 KB 搬运 ≈ 8 GB 内存流量。**这是复杂度问题（O(n × bufSize)），不是常数因子问题**，调 `bufSize` 只是换一个常数。

`readln()` 把这两项都摊到「每行一次」，代价可以忽略；而它返回的 `String` 内部就是 UTF-8，窗口内判断字符**不需要再解码**。

附带一个好处：`readln()` 内部已经处理了「多字节字符跨缓冲边界」——解不完的尾部通过 `rotateLeft(srcIndex)` 留在缓冲里等下次。这是自己写字节解码时最容易漏的一处（漏了会在 8 KB 边界上偶发乱码）。

### 2.3 两个 Reader 的分工

| | `std.io.StringReader<T>` | `charset4cj.TextReader` |
|---|---|---|
| 编码 | **仅 UTF-8**（无 charset 参数） | 由 `charset!` 指定 |
| 读字符 | `read(): ?Rune` | `read(): Option<Rune>` |
| 读行 | `readln(): Option<String>` | `readln(): Option<String>` |
| 其他 | `readUntil(pred)`, `readToEnd()`, `lines()`, `runes()` | `readAllLine(): ArrayList<String>`（**禁用**） |
| 非法字节 | 抛 `ContentFormatException` | 由具体解码器决定 |
| `Seekable` | 底层流可 seek 时支持 | 不支持 |

分工只有一条：**UTF-8 走标准库，其他编码走 charset4cj。**

这样 99% 的文档不引入第三方解码开销；GBK / UTF-16 / UTF-32 也能覆盖。

`readAllLine()` 必须禁用——它把所有行塞进 `ArrayList<String>`，内存是 O(文档大小)，与「流式」定位直接冲突。

### 2.4 行拼接的三个约定

`readln()` 丢弃行终止符，所以拼回窗口时要显式处理：

1. **行尾补 `\n`，并把残留的 `\r` 归一成 `\n`。** XML 规范要求 `\r\n` 与孤立 `\r` 都归一成 `\n`；
   但 `TextReader.readln()` / `StringReader.readln()` 只在 `\n` 与 `\r\n` 处断开，
   **孤立 `\r` 会原样留在返回的 String 里**（charset4cj 的实现是"遇到 `\r` 看下一个是不是 `\n`"）。
   所以字符层要做两件事：补 `\n`，并把内容里残留的 `\r` 换掉。
   **这条不能让两层都做**——两边都归一化会得到 `\r\r\n` 之类的二次处理结果。
2. **区分「流结束」和「空行」。** `readln()` 返回 `None` 是流结束（**不补 `\n`**），返回 `Some("")` 是一个空行（**要补 `\n`**）。混淆这两者会让文档末尾凭空多一个换行，进而影响属性值规范化。
3. **不假设「一行等于一个 token」。** 属性值、注释、CDATA 都可能跨行，窗口必须支持跨行拼接后再交给词法器。

### 2.5 已知缺陷与规避

下面每一条都来自读 `charset4cj` v1.0.6 源码或实测，不是推测：

| 缺陷 | 影响 | 规避 |
|---|---|---|
| `readln()` 按**字节**找 `0x0A` | UTF-16/32 会在字符中间误断行（如 U+0A00 的低字节就是 `0x0A`） | UTF-16/32 输入**不做行切分**，改为按固定块解码 |
| 两个 Reader 都无 `peek` / 无位置 | 词法器无法前瞻 | `CharWindow` 自己维护游标与行列号 |
| 无 BOM 处理 | 首个字符变成 `U+FEFF`；看起来没坏，但字符串比较永远不相等 | 字节层跳过（2.1），BOM 优先级高于声明 |
| `TextWriter` 只有 `write(String)`，无 `flush`/`close` | 数据停在底层缓冲，可能丢内容 | 由调用方 final flush；能用 `StringWriter` 就优先用它 |
| `Encoder.encode()` 无 BOM 选项 | 写 UTF-16 不带 BOM，外部工具可能判错字节序 | f_xml 自己在输出开头写 BOM 字节 |
| `TextReader.read()` 缓冲尾部只有半个字符时返回 `None` | 会被误判成 EOF | 不走 `read()`，走 `readln()`；`readln()` 用 `rotateLeft(srcIndex)` 正确保留残余 |

### 2.6 字符层接口

```cangjie
package fountain::f_xml

/// 字符来源：由 StringReader / TextReader 适配而来
public interface RuneSource {
    /// 向前看第 offset 个字符（0 = 当前），不移动游标
    func peek(offset!: Int64 = 0): ?Rune
    /// 消费并返回当前字符
    func advance(): ?Rune
    /// 当前行列号（1-based），用于错误定位
    func position(): SourcePosition
}

public struct SourcePosition {
    let line: Int64
    let column: Int64
}
```

三个实现，按编码选：

| 实现 | 包装 | 适用 |
|---|---|---|
| `Utf8RuneSource` | `Utf8Strict`（`Strict`）/ `Utf8ReplaceDecoder`（`Replace`），共享 `ByteDecoder` | UTF-8（默认路径） |
| `CharsetRuneSource` | `charset4cj.TextReader` | GBK 等单 / 多字节字符集 |
| `BlockRuneSource` | 共享 `ByteDecoder` + UTF-16 / UTF-32 解码器 | UTF-16 / UTF-32 |

`BlockRuneSource` 是 M1 新增的第三个实现：`readln()` 按**字节**找 `0x0A`，而 UTF-16 里
`U+0A00` 的低字节就是 `0x0A`，会在字符中间断行；固定块解码还要处理「块尾半个字符」。
块读取、块尾回退（≤ 3 字节）、坏字节分类、行列号推进统一收在 `RuneSource.cj` 的 `ByteDecoder`
里，`Utf8` 的两个分支与 `BlockRuneSource` 共用，不各写一份。

`peek(offset)` 的语义要写死：**只保证 `offset ≤ 4` 时有效**（XML 最长前瞻是 `<!--` / `<![CDATA[` 这类 4 字符前缀）。这样实现可以用固定大小的环形窗口，不必无限缓冲。

**不提供 `byteOffset`。** `TextReader` 不暴露底层字节位置，硬算出来的值在跨缓冲边界时是错的——与其给一个会骗人的字段，不如只给行号列号。错误信息里用「第 3 行第 17 列」，这对定位已经够用。

---

### 2.7 解码与编码失败策略

字符层只在两个方向上出错：读（字节 → 字符）与写（字符 → 字节）。两边的策略都必须显式，
不能默认"悄悄替换"。

```cangjie
/// 读方向：字节序列不符合声明的字符集
public enum InvalidByteMode {
    | Strict      // 默认：抛 XmlException（带行列号）
    | Replace     // 按 maximal subpart 消费，产出一个 U+FFFD
}

/// 写方向：目标字符集表示不了某个字符
public enum InvalidCharMode {
    | Throw       // 默认：抛 XmlException（带码点与位置）
    | Replace     // 用 '?' 代替
}
```

#### 读方向（`InvalidByteMode`）

| 模式 | 行为 |
|---|---|
| `Strict` | 抛 `XmlException`，消息带行号、列号、坏字节偏移 |
| `Replace` | 按 **RFC 3629 maximal subpart** 消费，产出**一个** U+FFFD |

- **不提供"跳过"模式**：丢字节会让后续错位，可能解出"看起来正常但内容错误"的字符，
  这比 U+FFFD 难查得多——U+FFFD 至少是可见的"这里坏了"
- `Replace` 下 U+FFFD 与其他字符完全等价：参与长度、进入 DOM、影响比较。
  要精确统计坏字节数，只能在 `Strict` 下按异常处理
- XML 对非法字符/非法编码本身是 **fatal error**，所以 `Replace` 是给"脏输入也要尽量读"的场景准备的。
  用它就等于接受"这份文档不保证良构"

#### 写方向（`InvalidCharMode`）

难点在**检测**：`charset4cj` 的 `Encoder.encode` **没有声明"不可映射字符"的契约**——
`indexPointer` 找不到码点时返回 `-1`，各字符集实现拿到 `-1` 后是抛、是替换成 `?`、还是跳过，并不统一。
所以**不能靠"等它抛异常"来实现 `Throw`**。

f_xml 的做法是**往返校验**：

```
1. bytes = encoder.encode(s)
2. back  = decoder.decode(bytes)
3. back == s ? 正常 : 说明有字符被替换或丢失
4. Throw   → 逐字符 encode 定位，报出第一个失败的码点与它在文本中的位置
   Replace → 自己逐字符 encode，失败处写 '?'（不能直接采用编码器结果——
             如果它是"跳过"，结果里会少字符，长度和内容都不对）
```

三条约定：

1. **替换字符用 `?`（0x3F），不用 U+FFFD。** 目标字符集可能连 U+FFFD 都表示不了
   （GBK 没有这个字符），`?` 是唯一能保证可编码的兜底。
2. **`Replace` 是有损且不可逆的**，只用于"导出给人看"。写出去还要读回来的数据必须用 `Throw`。
3. **UTF-8 / UTF-16 / UTF-32 恒可编码**，这条校验可以整段跳过——不要每次写出都往返一次。

> 这条与 7.4 的"输出缓冲"是两件事：缓冲解决的是"别一个 token 一次 write"，
> 这里解决的是"目标字符集装不下时怎么办"。

---

## 3. 事件模型

```cangjie
package fountain::f_xml

// 事件类型只有一处定义：3.2 的 XmlEvent。不另设 kind 枚举——
// 两套定义迟早会漂移，需要标签时 match 一下即可。

/// 回调的返回值：控制解析器下一步做什么
public enum XmlAction {
    | Continue        // 继续
    | SkipSubtree     // 跳过当前元素的子树（匹配的 EndElement 仍会回调，见 3.3）
    | Stop            // 终止整个解析
}

/// 事件处理器：每个语法元素触发一次
///
/// **所有方法都有默认实现（返回 Continue）**，实现方只覆盖自己关心的方法。
/// 这样"只处理一种事件"的 handler 不必写十个空方法——见 3.4 的取舍论证。
public interface XmlEventHandler {
    func onStartDocument(): XmlAction { XmlAction.Continue }
    func onXmlDeclaration(version: String, encoding: ?String, standalone: ?Bool): XmlAction {
        XmlAction.Continue
    }
    func onDocType(name: String, publicId: ?String, systemId: ?String): XmlAction {
        XmlAction.Continue
    }
    func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction {
        XmlAction.Continue
    }
    func onEndElement(name: QName): XmlAction { XmlAction.Continue }
    func onText(text: String): XmlAction { XmlAction.Continue }
    func onCData(text: String): XmlAction { XmlAction.Continue }
    func onComment(text: String): XmlAction { XmlAction.Continue }
    func onProcessingInstruction(target: String, data: String): XmlAction { XmlAction.Continue }
    func onEndDocument(): XmlAction { XmlAction.Continue }
}

/// 解析选项
public struct XmlParserOptions {
    /// 传给 charset4cj TextReader 的缓冲大小；影响 readln 次数与 rotateLeft 搬运量，见 2.2
    public let bufSize!: Int64 = 8192
    /// 是否丢弃"元素之间纯空白"产生的文本节点
    public let trimWhitespaceOnly!: Bool = false
    /// 实体展开上限，见 5.4
    public let entityLimits!: EntityLimits = EntityLimits()
    /// 字节序列不符合声明字符集时的策略，见 2.7
    public let onInvalidByte!: InvalidByteMode = InvalidByteMode.Strict
}
```

### 3.1 几个设计约定

**① 自闭合标签既发 Start 也发 End**

`<a/>` 触发 `onStartElement(a, [], selfClosing: true)` 然后**立刻** `onEndElement(a)`。这样 handler 只需要一套"进出"逻辑，不用为自闭合单独分支——建树时这一点非常关键，否则栈会失衡。

**② 相邻文本可能分成多次回调**

词法层遇到 `&amp;`、CDATA 边界、缓冲区边界时，可能把一段连续文本拆成多个 `onText`。**handler 必须自己拼接**，不能假设"一个 `onText` = 一个完整文本节点"。

`DomBuilder` 里做合并：如果上一个子节点也是文本节点，直接追加，不再新建。

**③ 空白不丢弃**

XML 里空白可能是内容（`<t> hello </t>` 的前后空格有意义）。解析器**原样回调**，是否忽略由 handler 决定：

- `DomBuilder` 默认保留，提供 `trimWhitespaceOnly` 选项丢弃"纯空白文本节点"（元素之间换行缩进产生的那些）
- `xml:space="preserve"` 出现时强制保留

**④ 事件顺序固定**

```
onStartDocument
onXmlDeclaration?          （最多一次，必须在最前）
onDocType?                 （最多一次，必须在前导区）
(onComment | onProcessingInstruction)*
onStartElement(root)
  ... 递归 ...
onEndElement(root)
(onComment | onProcessingInstruction)*
onEndDocument
```

### 3.2 拉模式：同一词法器，两个前端

```cangjie
public class XmlPullParser {
    public init(input: InputStream, options!: XmlParserOptions = XmlParserOptions())

    /// 下一个事件；None = 文档结束
    public func nextEvent(): ?XmlEvent

    /// 跳过当前元素的整棵子树。只能在 StartElement 之后立即调用（见 3.3）
    public func skipElement(): Unit

    public func close(): Unit
}

public enum XmlEvent {
    | StartDocument
    | XmlDeclaration(version: String, encoding: ?String, standalone: ?Bool)
    | DocType(name: String, publicId: ?String, systemId: ?String)
    | StartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool)
    | EndElement(name: QName)
    | Text(String)
    | CData(String)
    | Comment(String)
    | ProcessingInstruction(target: String, data: String)
    | EndDocument
}
```

**推模式建立在拉模式之上，不是反过来。**

```cangjie
// XmlParser 的实现就是一层转译
while (let Some(e) <- pull.nextEvent()) {
    let action = dispatch(e)              // 调 handler 的对应回调
    if (action == XmlAction.Stop) { break }
    if (action == XmlAction.SkipSubtree) { pull.skipElement() }
}
```

反过来做不到：回调式一进到底，没有"暂停 / 恢复"的接口。**所以词法器只有一套、事件序列只有一种**——
否则推 / 拉两种模式会出现行为差异，最典型的就是自闭合标签的 End 事件。

两条与推模式对齐的约定：

1. **自闭合标签同样产出 `StartElement(selfClosing: true)` + `EndElement` 两条事件。**
   不要为"省一条"只发 Start，否则拉模式的消费方得写两套栈逻辑。
2. **文本仍可能分成多次 `Text`。** 合并责任在消费方，与推模式一致。

拉模式适合"边解析边决策"：读前 N 条就 `break`，不需要 Stop 信号；
某个分支不关心就直接 `skipElement()`。

### 3.3 `skipElement()`：跳过整棵子树

**语义**：从当前 `StartElement` 之后开始，跳到与它匹配的 `EndElement` 之后；
中间的（子元素、文本、注释、PI）**不产生任何事件**。

**但匹配的那个 `EndElement` 仍然发出。** 这条是刻意定的：

- 推模式下 `Start` 已经回调过了，`End` 不回调的话 handler 的栈必然失衡
- 拉模式下消费方也要靠它维护自己的深度

所以统一规则是：**跳过的是"子节点"，不是"当前元素"。**

| 模式 | 用法 |
|---|---|
| 推 | `onStartElement` 返回 `XmlAction.SkipSubtree` |
| 拉 | `nextEvent()` 拿到 `StartElement` 后调 `skipElement()` |

**前提**：必须在 `StartElement` 处理期间或之后立即调用。其他位置调用抛
`XmlException("skipElement 必须在 StartElement 之后调用")`——否则"跳到哪里"没有定义。

**实现要点**：不能"跳到下一个同名 End"，必须**按深度配对**（同名元素会嵌套）。
跳过期间只做**标签级扫描**：不解析属性值、不解码实体、不建节点；
但必须正确处理引号内的 `>` 与注释 / CDATA——否则会被 `<!-- a > b -->` 骗过去。

### 3.4 为什么保留 `XmlAction` 返回值（兼论 lambda 是否啰嗦）

**问题**：回调返回枚举会让"用 lambda 写 handler"也要返回枚举。
备选方案是给解析器加 `stop()` / `skipCurrentElement()`，handler 持有 parser 引用去调。

**结论：保留返回值，新增单回调 lambda 重载；明确不采纳 `stop()` 方案。**

#### 3.4.1 先把"啰嗦"量化

三个版本写同一个需求——"遇到 `<row>` 结束时，把当前行交出去"：

**版本 A：接口 + 无默认实现**（v0.4 的写法，最啰嗦，已废弃）

```cangjie
class RowHandler <: XmlEventHandler {
    public func onStartDocument(): XmlAction { XmlAction.Continue }
    public func onXmlDeclaration(v: String, e: ?String, s: ?Bool): XmlAction { XmlAction.Continue }
    public func onDocType(n: String, p: ?String, s: ?String): XmlAction { XmlAction.Continue }
    public func onStartElement(n: QName, a: Array<XmlAttribute>, sc: Bool): XmlAction {
        XmlAction.Continue
    }
    public func onEndElement(n: QName): XmlAction {
        if (n.local == "row") { sink.write(currentRow) }
        return XmlAction.Continue
    }
    public func onText(t: String): XmlAction { XmlAction.Continue }
    public func onCData(t: String): XmlAction { XmlAction.Continue }
    public func onComment(t: String): XmlAction { XmlAction.Continue }
    public func onProcessingInstruction(t: String, d: String): XmlAction { XmlAction.Continue }
    public func onEndDocument(): XmlAction { XmlAction.Continue }
}
```

九个空方法。**这才是真正的问题所在**，不是那个 `return`。

**版本 B：接口 + 默认实现**（v0.6 起，推荐写法）

```cangjie
class RowHandler <: XmlEventHandler {
    public func onEndElement(n: QName): XmlAction {
        if (n.local == "row") { sink.write(currentRow) }
        return XmlAction.Continue
    }
}
```

只剩一个 `return`。**默认实现消掉了 90% 的啰嗦。**

**版本 C：单回调 lambda**（v0.6 新增的控制流重载）

```cangjie
XmlParser.parse(input) { e =>
    if (let EndElement(n) <- e) { if (n.local == "row") { sink.write(currentRow) } }
    XmlAction.Continue
}
```

一行 `XmlAction.Continue` 收尾。这已经比"捕获 parser 再调 `stop()`"更短——

```cangjie
// 假想的 stop() 版本，并不会更短
var parser: ?XmlParser = None
XmlParser.parse(input, object <: XmlEventHandler {
    public func onEndElement(n: QName): Unit {
        if (n.local == "row") { sink.write(currentRow); parser?.stop() }
    }
}, ref parser)          // 还得想法子把 parser 塞进去
```

#### 3.4.2 为什么不采纳 `stop()` / `skipCurrentElement()`

五条理由，按严重程度排：

**① 循环依赖，只能靠可变的"后置注入"破解**

`XmlParser` 构造时需要 handler，handler 需要 parser 才能调 `stop()`。仓颉没有"先构造再补依赖"的干净语法，只能：

```cangjie
var parser: ?XmlParser = None
let handler = MyHandler { parser }      // 捕获一个还未赋值的变量
parser = XmlParser(input, handler)      // 后置赋值
```

这个 `var` 是**打破类型系统的逃生门**：编译器无法保证它在回调发生时已经赋值，只能靠运行期 `?` 解包。返回值版本没有这个洞——控制流是纯函数式传递的。

**② 重入语义无法定义**

handler 在 `onStartElement` 里调 `parser.stop()`，此刻 parser 正处在"分发事件"的栈帧内。`stop()` 只能置一个标志位，真正的停止必须等回调返回。于是：

- 回调在 `stop()` 之后继续做耗时 3 秒的操作，解析器是停还是不停？
- 回调在 `stop()` 之后又调了 `nextEvent()`（拉模式混用），会发生什么？
- `stop()` 在 `onStartDocument` 里调用，语义是"一个字都不读"还是"读完序言再停"？

返回值版本**没有这些问题**：`return Stop` 就是"这个回调结束后不再有下一个回调"，语义是闭合的、可静态推理的。

**③ 多个 handler 串联时会失控**

```cangjie
// 组合两个 handler：任一返回 Stop 就停
let action = h1.onStartElement(n, a, sc)
if (action == Stop) { return }
let action2 = h2.onStartElement(n, a, sc)
```

返回值天然可组合（`||` 合并即可）。`stop()` 版本下，h1 调了 `stop()`，h2 **仍然会被调用**——它不知道已经停了，可能继续往一个已关闭的 sink 里写数据。

**④ 与拉模式分叉**

拉模式没有 handler，只有 `nextEvent()`。如果推模式的控制流靠 `stop()`，两种模式就有了两套不同的终止机制，违反 3.2 定下的"同一套词法器、同一种事件序列"。而现在推模式是**建立在拉模式之上的一层转译**（3.2 的代码），`Stop` 只是 `break` 循环，零成本：

```cangjie
while (let Some(e) <- pull.nextEvent()) {
    let action = dispatch(e)
    if (action == XmlAction.Stop) { break }
    if (action == XmlAction.SkipSubtree) { pull.skipElement() }
}
```

**⑤ `skipCurrentElement()` 的能力已经有了**

拉模式的 `skipElement()` 就是它，而且位置约束更明确（必须在 `StartElement` 之后）。推模式里用 `return SkipSubtree` 表达同一件事，转译层直接调 `pull.skipElement()`。再加一个 `skipCurrentElement()` 是同一能力的第三个入口。

#### 3.4.3 最终形态：三层，按场景选

| 场景 | 用哪个 | 代码量 |
|---|---|---|
| 关心多个事件、有状态（如 `DomBuilder`） | **接口 + 默认实现** | 只写关心的方法 |
| 关心一个事件、无状态（日志、过滤、计数） | **单回调重载** | 一个 lambda |
| 要"读几条就停"、要自己控节奏 | **拉模式 + `skipElement()`** | 显式循环 |

三者的关系是**同一套内核的三个前端**，不是三套实现：

```
词法器（唯一）
   ↓
XmlEvent 序列（唯一）
   ├── XmlPullParser.nextEvent()       拉模式
   ├── 单回调 parse(input, onEvent)     拉模式 + 一层 match 转译
   └── 多回调 parse(input, handler)     单回调 + 按事件类型分派到 handler 的方法
```

单回调重载的签名：

```cangjie
public static func parse(input: InputStream,
                         onEvent: (XmlEvent) -> XmlAction,
                         options!: XmlParserOptions = XmlParserOptions()): Unit
```

> 注意它与 `parse(input, handler)` 的区别：前者**不产生 DOM**（纯流式消费），后者也不产生 DOM
> （只跑回调）。要 DOM 就用 `XmlParser.parse(input): XmlDocument`。

**代价**：多一个重载、多一层 `match` 转译（约 20 行）。收益是"写一行 lambda 就能解析"。
这个代价是值的。

---

## 4. DOM 模型

```cangjie
public struct QName {
    public let prefix: ?String     // "x" in <x:row>
    public let local: String       // "row"
    public let uri: ?String        // 解析后的命名空间 URI

    public func toString(): String // 还原成 "x:row" 或 "row"
}

public struct XmlAttribute {
    public let name: QName
    public let value: String
}

public class XmlElement {
    public prop name: QName
    public prop attributes: ArrayList<XmlAttribute>
    public prop children: ArrayList<XmlNode>

    public init(name: QName)
    public init(name: String)                       // 无命名空间的便捷构造

    public func attr(name: String): ?String          // 按 local name 取属性
    public func attr(ns: String, local: String): ?String
    public func setAttr(name: String, value: String): Unit

    public func child(name: String): ?XmlElement     // 第一个匹配的子元素
    public func childrenOf(name: String): ArrayList<XmlElement>
    public func text(): String                       // 所有后代文本拼接
}

public enum XmlNode {
    | ElementNode(XmlElement)
    | TextNode(String)
    | CDataNode(String)
    | CommentNode(String)
    | PiNode(String, String)                         // target, data
    | EntityRefNode(String)                         // 显式实体引用（写侧输出 &name;）
}

public class XmlDocument {
    public prop root: ?XmlElement
    public prop declaration: ?XmlDeclaration
    public prop doctype: ?DocTypeInfo
    public prop prolog: ArrayList<XmlNode>           // 前导区的注释/PI
    public prop epilog: ArrayList<XmlNode>           // 结束后的注释/PI
}
```

> **`builder` 不外露**（M1 落地时的差异）：`DomBuilder` 在文档建成后栈已空，公开字段只会诱导
> 「继续往文档里追加节点」这种没有语义的操作，所以它是 `internal`。需要构造文档请用
> `XmlElement` / `XmlEntityRef` 这些公开类型。

### 4.1 为什么用 `QName` 而不是裸字符串

`<item>` 和 `<x:item>` 是同一个元素（只要 `xmlns:x` 指向同一 URI）。**用裸字符串比较会在遇到带前缀的文档时全部匹配失败**——不少生成器（LibreOffice、部分 Java 库）默认就是带前缀的风格。

`QName` 在解析时就完成前缀解析，`child("row")` / `attr("r")` 这类便捷方法按 **local name** 匹配，调用方不用关心前缀。

---

## 5. 解析器设计

### 5.1 状态机

```
PROLOG ──┬─ <?xml ...?> ──▶ PROLOG
         ├─ <!DOCTYPE>  ──▶ PROLOG
         ├─ <!-- -->    ──▶ PROLOG
         ├─ <?pi ?>     ──▶ PROLOG
         └─ <name ...>  ──▶ CONTENT

CONTENT ─┬─ <name ...>   ──▶ CONTENT（入栈）
         ├─ </name>      ──▶ CONTENT（出栈；栈空则转 EPILOG）
         ├─ text         ──▶ CONTENT
         ├─ <![CDATA[ ]]>──▶ CONTENT
         ├─ <!-- -->     ──▶ CONTENT
         └─ <?pi ?>      ──▶ CONTENT

EPILOG ─┬─ <!-- --> / <?pi ?> ──▶ EPILOG
        └─ EOF                ──▶ 结束
```

状态机只做"当前允许出现什么"，元素配对校验靠一个**名称栈**。

### 5.2 词法的几个硬点

| 场景 | 处理 |
|---|---|
| `<` 出现在属性值里 | **非法**，必须转义为 `&lt;`；遇到要报错 |
| `<` 出现在文本里 | 非法，必须是标签开始 |
| 标签名后的空白 | 必须有（`<a b="1">` 里 `a` 与 `b` 之间） |
| 属性值引号 | 单双引号都支持，但同一个值里必须配对 |
| 同一元素重复属性 | **非法**（well-formedness 错误） |
| `<a/>` 与 `<a />` | 都合法，`/` 前允许空白 |
| 注释内出现 `--` | 非法 |
| PI 的 target 为 `xml`（任意大小写） | 非法（保留字） |

### 5.3 必须做但容易漏的三件事

**① 行尾归一化**

XML 规范要求解析前把 `\r\n` 和单独的 `\r` 都归一成 `\n`。不做的话，Windows 生成的 XML 里文本节点会带 `\r`，导致字符串比较失败、哈希不一致。

**② BOM 处理**

UTF-8 BOM（`EF BB BF`）要跳过；UTF-16 靠 BOM 判定字节序。这条与 f_io 的 BOM 逻辑一致，不要各写一套。

**③ 实体解码**

五个预定义实体 + 数字字符引用：

| 写法 | 结果 |
|---|---|
| `&lt;` `&gt;` `&amp;` `&quot;` `&apos;` | `<` `>` `&` `"` `'` |
| `&#65;` | `A`（十进制） |
| `&#x41;` | `A`（十六进制） |
| `&nbsp;` 等 HTML 实体 | **不认识，报错** |

XML 只有那五个预定义实体。`&nbsp;` 是 HTML 的，出现说明文档本身不合法——**报错而不是猜**。

---

### 5.4 DTD 内部子集与实体展开

**支持范围：`<!DOCTYPE ... [ 内部子集 ]>` 里声明的实体。外部子集（`SYSTEM` 指向的 `.dtd`）不加载。**

#### 支持什么

| 语法 | 支持 | 说明 |
|---|---|---|
| `<!ENTITY name "值">` | ✅ | 普通实体，值里可以嵌套引用别的实体 |
| `<!ENTITY name '值'>` | ✅ | 单双引号都认 |
| `<!ENTITY % name "值">` | ✅ | 参数实体，只能在 DTD 内部以 `%name;` 使用 |
| `<!ENTITY name SYSTEM "uri">` | ❌ **不加载** | 声明可识别，**引用即报错**，绝不读文件 |
| `<!ENTITY % name SYSTEM "uri">` | ❌ 同上 | |
| `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` | ✅ 只校验**声明语法** | 良构性校验：产生式合法才通过，非法声明报错；不做有效性校验（不比对内容模型与文档结构、不注入默认值）；必须能正确处理内部的 `>` 与引号 |
| `<!ATTLIST>` 的属性类型 | ✅ 只服务**属性值规范化** | 建「元素字面名 → 属性名 → `AttType`」映射，非 `CDATA` 类型去首尾并折叠空白；不检查 `ID` 唯一性、不检查 `IDREF` 指向、不检查枚举取值、不注入默认值 / `#FIXED` 值 |
| 条件段 `<![INCLUDE[ ]]>` / `<![IGNORE[ ]]>` | ❌ **报错** | `intSubset` 产生式里没有 `conditionalSect`，条件段只属于外部子集；外部子集永不加载，M1 不存在「按标志位选分支」的路径 |
| 同一实体重复声明 | 第一个生效 | 规范如此，不报错 |

#### 展开规则

| 位置 | 是否展开 | 说明 |
|---|---|---|
| 元素内容 | ✅ | `&name;` → 递归展开 |
| 属性值 | ✅ | **先展开字符引用与实体引用，再做空白规范化**（顺序不能反） |
| CDATA | ❌ | 原样，`&name;` 就是字面量 |
| 注释 / PI | ❌ | 同上 |
| 实体值内部 | ✅ | **延迟展开**：声明时只存原文，等实体被使用时才展开；此时仍未声明才报错（WFC: Entity Declared） |

**顺序细节（很容易做反）**：属性值处理是

```
字符引用 + 实体引用展开  →  空白字符归一（#x9/#xA/#xD → #x20）  →  （非 CDATA 类型时）去首尾 + 折叠
```

先规范化再展开，会让实体值里的换行逃过归一化，属性值里就会留下本不该存在的 `\n`。
第三步只对 `#x20` 生效（规范措辞就是 space），所以直接写在属性里的 `&#10;` 不会被折叠；
而实体值里的 `&#10;` 在**声明时**就变成了真正的换行字符，使用时先归一成空格、再被折叠。

**单实体替换文本必须自身良构**（WFC: Parsed Entity）：内容位置使用的内部一般实体，其替换文本
必须匹配 `content` 产生式——标签要在**实体内部**配平，不能「实体里开、实体外关」，也不能有
孤立结束标签。M1 的实现是在展开前用词法器在独立输入上把替换文本重扫一遍（实体表为空，
嵌套引用只当引用、不展开），校验失败报 `XmlException`，消息带实体名与展开点行列号。
属性值位置另有更严的规则：替换文本不得含裸 `<`。

#### 三层膨胀上限

实体展开是 Billion Laughs 的唯一入口，所以三层同时限：

```cangjie
public struct EntityLimits {
    /// 单个实体展开后的最大字符数（软阈值：超过转为溢出模式）
    public let maxExpandedPerEntity!: Int64 = 64 * 1024
    /// 整个文档由实体展开产生的总字符数（软阈值：超过转为溢出模式）
    public let maxExpandedTotal!: Int64 = 8 * 1024 * 1024
    /// 递归深度上限（含嵌套引用）。**硬限制，超了直接报错**
    public let maxDepth!: Int64 = 16
    /// 实体声明数量上限。**硬限制，超了直接报错**
    public let maxDeclarations!: Int64 = 1024
    /// 溢出模式的绝对上限。超过它无论如何都报错
    public let maxExpandedHardLimit!: Int64 = 2 * 1024 * 1024 * 1024   // 2 GB
    /// 阈值超限时的处置方式
    public let overflowPolicy!: EntityOverflowPolicy = EntityOverflowPolicy.Spill
    /// 溢出文件目录。None = 按 5.4.2 的顺序解析
    public let spillDir!: ?Path = None
}

public enum EntityOverflowPolicy {
    | Spill      // 默认：超过软阈值转溢出模式，继续解析（内存恒定）
    | Strict     // v0.5 及以前的行为：超过软阈值直接抛异常
}
```

- **深度**挡住 `a → b → c → …` 的线性嵌套
- **单实体上限**挡住"一个实体特别长"
- **总增量上限**挡住 `a = "x"×10; b = a×10; c = b×10` 这类指数膨胀

**关键实现点：边展开边计数，不能"先展开成字符串再量长度"。** 展开 10 层、每层 10 倍就是 10¹⁰ 字符，
先拼再检查的话内存早就爆了。所以计数器要挂在"往输出缓冲追加字符"的那一刻。

#### 5.4.1 超限不再直接失败：溢出到临时文件

**原设计的问题**：8 MB 总增量对 DocBook 这类"合法但重度使用实体"的文档可能不够。
一超限就整份文档失败，等于把"结构复杂"误判成"恶意"。

**新策略：软阈值触发溢出，硬限制仍然拦截。**

| 阈值 | 性质 | 超限行为（`Spill` 模式） |
|---|---|---|
| `maxExpandedPerEntity` (64 KB) | 软 | 该实体的展开结果**转写临时文件**，此后按流提供 |
| `maxExpandedTotal` (8 MB) | 软 | 整个文档转入溢出模式，后续所有实体展开都走文件 |
| `maxDepth` (16) | **硬** | 抛 `XmlException("实体递归深度超过 16")` |
| `maxDeclarations` (1024) | **硬** | 抛 `XmlException("实体声明超过 1024 条")` |
| `maxExpandedHardLimit` (2 GB) | **硬** | 抛 `XmlException("实体展开总量超过 2 GB")` |

**为什么深度和声明数不溢出**：它们是**结构性**指标，不是数量指标。深度 16 已经远超任何真实文档
（DocBook 最深约 5~6 层）；声明 1024 条已经超过绝大多数 DTD。这两条超了就是恶意，没有"合法但很深"的情况。

**为什么必须保留硬上限**：溢出模式把"内存爆炸"换成了"磁盘爆炸"。
没有 `maxExpandedHardLimit` 的话，一个精心构造的实体炸弹能把磁盘写满——这比 OOM 更难恢复。

#### 5.4.2 溢出的实现

展开器持有一个 `ExpandSink`：

```cangjie
interface ExpandSink {
    func write(text: String): Unit
}
class MemorySink <: ExpandSink { let buf = StringGenerator() }   // f_base.StringGenerator，见 10.2
class FileSink   <: ExpandSink { let file: File; ... }
```

切换时机（**单向，不回头**）：

```
每追加一段展开文本前：
  if (currentSink is Memory && totalExpanded + seg.len > maxExpandedTotal):
      把 MemorySink 里已有的内容倒进 FileSink（一次性）
      currentSink = FileSink
  if (totalExpanded > maxExpandedHardLimit):
      throw XmlException(...)
  currentSink.write(seg)
```

一旦切到 `FileSink`，本实体及后续所有实体的展开都直接进文件（不再逐实体判断）。
理由是反复切换会产生大量小文件，且磁盘 IO 已经是瓶颈，省那点写入没意义。

**读回**：`FileSink` 关闭后，词法器从该文件按 `bufSize` 分块读，像读普通 `InputStream`。
所以溢出模式对下游**完全透明**——`onText` 回调看到的仍是连续的文本，只是中间经过了磁盘。

**临时目录的解析顺序**（**OHOS 上没有 `/tmp`**，这是必须写清的一条）：

```
1. EntityLimits.spillDir（显式指定）
2. 环境变量 TMPDIR
3. 系统临时目录（std.fs 提供）
4. 当前工作目录下的 .fountain_tmp/（兜底，自动创建）
```

四个都失败 → 抛 `XmlException("无法创建实体溢出文件，请显式指定 spillDir")`。

> 这段临时目录解析逻辑与 `f_zip` 的 3.4.1 是同一套规则，但两个模块互不依赖，
> 各自持有约 20 行私有实现。**不提到 `f_util`**：为一个 20 行的路径探测引入一个
> 跨两个底层模块的公用依赖，收益不值。

**属性值里的实体不溢出**。属性值必须在解析完整个开始标签后**整体在内存**（后续要参与
namespace 解析、DTD 默认值合并、`xml:space` 判定）。所以属性值里单个实体展开超
`maxExpandedPerEntity` 时**直接报错**，即使 `overflowPolicy = Spill`：

```
XmlException("属性 'r' 的值中实体展开超过 64 KB，属性值不支持溢出（第 3 行第 17 列）")
```

这条边界要说清楚，否则调用方会疑惑"为什么元素内容能溢出、属性值不能"。

#### 5.4.3 溢出模式的代价

| 项 | 影响 |
|---|---|
| 磁盘 IO | 展开量 × 1 次写 + 1 次读 |
| 延迟 | 从"纯内存"变成"写盘再读回"，大文档可能慢 10~50 倍 |
| 磁盘占用 | 峰值 = 总展开量（用完即删） |
| 语义 | **完全不变**：DOM 里的文本、事件序列、错误位置都不受影响 |

**所以默认 `Spill`、但真实文档极少触发**：8 MB 展开量相当于一份 800 页的纯文本。
超过它的文档本来就是"用实体当模板引擎"的极端写法，给它一条活路比直接拒绝好。

#### 与 `standalone` 的关系（一个必须说明的边界）

引用**未声明**的实体时（外部子集永不加载，所以「只在外部子集里声明」的实体也落在这一类），
判定分两步——**先看有没有可能从本文件以外声明，再看 `standalone`**：

| 前提 | `standalone` | 行为 |
|---|---|---|
| — | `"yes"` | 报错——文档自称自包含，却引用了未声明的东西 |
| 无外部子集（`DOCTYPE` 没有 `SYSTEM`/`PUBLIC`）**且**全文无参数实体引用 | `"no"` 或省略 | **报错**（WFC: Entity Declared）——连「可能声明在别处」的通道都没有 |
| 有外部子集，**或**有参数实体引用 | `"no"` 或省略 | **不报错**：内容位置为空、属性值里去掉该引用，记一条告警 |

`standalone="no"` 并不自动等于「未声明实体可以跳过」：必须有「外部子集或参数实体引用」这个前提。
不区分的话，`xmlconf` 里 `not-sa03` / `rmt-e3e-13` 这类带外部 DTD 的**合法**文档会被误判成错误；
反过来无条件放过，`<a>&nbsp;</a>` 这种笔误就会被静默吞成空文本。

---

## 6. 命名空间

### 6.1 解析

进入元素时，先把 `xmlns` / `xmlns:prefix` 属性收集到一个**作用域栈**（子元素继承父元素的作用域）：

```
每次 onStartElement:
  1. 从属性里挑出所有 xmlns* → 压入作用域栈
  2. 元素名和普通属性名按当前作用域解析出 uri
  3. onEndElement 时弹栈
```

两个特殊前缀：

| 前缀 | 绑定 |
|---|---|
| `xml` | 固定 `http://www.w3.org/XML/1998/namespace`，不需要声明 |
| `xmlns` | 保留，不能作为元素前缀 |

**未声明的前缀是 well-formedness 错误**，必须报错——静默当成"无命名空间"会让后续匹配全错。

### 6.2 生成

序列化时**不要**在每个元素上都写 `xmlns`，只在**首次引入或改变绑定**时输出：

```
父元素已声明 xmlns="A"，子元素仍是 A → 子元素不重复声明
子元素改用 xmlns="B" → 子元素声明 xmlns="B"
子元素想回到"无命名空间" → 必须写 xmlns=""
```

第三条最容易漏：`xmlns=""` 是重置默认命名空间的唯一方式，漏了会导致子元素被错误归入父命名空间。

---

## 7. 生成器

```cangjie
public struct XmlWriterOptions {
    /// 缩进串；None = 紧凑输出（默认）
    public let indent!: ?String = None
    /// 输出编码，默认 UTF-8（见 7.4）
    public let charset!: Charset = Charsets.UTF8
    /// CDATA 策略（见 7.5）
    public let cdata!: CdataMode = CdataMode.Auto
    /// 输出 DOCTYPE，含实体声明（见 7.6）
    public let doctype!: ?Doctype = None
    /// 引用未声明实体时是否报错（默认 true，见 7.6）
    public let strictEntities!: Bool = true
    /// 目标字符集表示不了某个字符时的策略，见 2.7
    public let onInvalidChar!: InvalidCharMode = InvalidCharMode.Throw
}

public class XmlWriter {
    public init(output: OutputStream, options!: XmlWriterOptions = XmlWriterOptions())

    public func write(doc: XmlDocument): Unit
    public func write(element: XmlElement): Unit
    public func flush(): Unit
}
```

### 7.1 紧凑 vs 缩进

| 模式 | 用途 |
|---|---|
| **紧凑（默认）** | 程序消费的 XML 一律用它。缩进空白会变成文本内容——例如 `<t> 值 </t>` 里多了前后空格，往返一次数据就脏了 |
| 缩进 | 人看的输出、调试、导出给用户检查 |

**程序消费的 XML 必须用紧凑模式**，这不是审美问题——`indent` 注入的空白会成为文本内容的一部分，往返一次数据就脏了。

### 7.2 转义规则

| 字符 | 文本节点 | 属性值 |
|---|---|---|
| `&` | `&amp;` | `&amp;` |
| `<` | `&lt;` | `&lt;` |
| `>` | `&gt;`（推荐） | `&gt;` |
| `"` | 可不转 | `&quot;`（双引号包裹时） |
| `'` | 可不转 | `&apos;`（单引号包裹时） |
| `\r` | `&#13;` | `&#13;` |

**`\r` 必须转义**：否则写出去再读回来会被行尾归一化成 `\n`，往返不一致。

### 7.3 非法字符

XML 1.0 不允许的字符：`0x00`–`0x08`、`0x0B`、`0x0C`、`0x0E`–`0x1F`。

生成时遇到这些字符：**拒绝并报明确错误**（指出是哪个元素/属性），不要静默剔除——剔除会让"写进去的和读出来的不一样"，且很难排查。

---

### 7.4 字符层：输出到哪去

写出侧同样分两套，与读入侧对称：

| 编码 | 用哪个 | 可用能力 |
|---|---|---|
| UTF-8 | `std.io.StringWriter<T> where T <: OutputStream` | `write(String)` / `writeln(String)` / `flush()` / `close()`；`T` 可 seek 时还有 `length` / `position` |
| 其他 | `charset4cj.TextWriter` | 只有 `write(String)` |

编码是 `XmlWriterOptions.charset` 的一个字段（见第 7 章的构造签名），默认 `Charsets.UTF8`。

**内部必须做输出缓冲，不能一个 token 一次 write。** 原因在 `TextWriter.write`：

```cangjie
public func write(s: String) {
    let bytes = this.encoder.encode(s)   // 每次调用都分配一个新数组
    this.output.write(bytes)
}
```

一个中小型文档有几万个 token，逐次 write 就是几万次编码 + 几万次数组分配 + 几万次底层写。做法是先在 `String` 缓冲里拼，攒到 8~64 KB 再一次性交给 writer。

三个必须注意的点：

1. **`TextWriter` 没有 `flush`**，最终数据可能停在底层流。`XmlWriter.flush()` 里除了冲刷自己的缓冲，还要对 `output` 做 flush；若调用方自己持有 `output`，文档里要明确写「必须由持有者 flush」。
2. **UTF-16/32 要自己写 BOM**。`Encoder.encode` 只编码内容、不产 BOM；而外部工具判断字节序基本都靠 BOM。默认策略：写 UTF-16/32 时先写 BOM，写 UTF-8 时**不写**（XML 默认编码是 UTF-8，多一个 BOM 反而会让某些解析器把 `U+FEFF` 当内容）。
3. **编码失败按 `onInvalidChar` 处理**（见 2.7）：默认 `Throw`，因为写出一个"字符被悄悄替换"的 XML，
   比直接失败更难发现——下游拿到的是语法正确、内容错误的数据。设成 `Replace` 只适合"导出给人看"。
4. **不要用 `writeln()` 生成 XML 内容**。`StringWriter.writeln` 写的是 `\n`，而 XML 的换行属于「可被规范化的空白」——紧凑模式下不应该主动产生换行；缩进模式下换行由 `indent` 统一控制，不能混用两套换行来源。

### 7.5 CDATA 输出模式

```cangjie
public enum CdataMode {
    | Auto      // 默认：只在必要时转义，不产 CDATA
    | Always    // 所有文本节点用 CDATA 包裹
    | Never     // 永远转义，不使用 CDATA
}
```

| 模式 | 行为 | 适用 |
|---|---|---|
| `Auto` | 常规转义 | 绝大多数场景，输出最小 |
| `Always` | `<![CDATA[ … ]]>` 包裹文本 | 文本里有大量 `<` `&`：内嵌 HTML、正则、SQL |
| `Never` | 强制转义，即使内容适合 CDATA | 目标解析器对 CDATA 支持不佳时 |

**`Always` 有两个必须处理的边界：**

1. **文本里出现 `]]>`** → 必须拆成 `]]]]><![CDATA[>`。不拆的话 CDATA 提前闭合，
   后面的内容就变成普通文本，语义直接坏掉——这是 CDATA 输出最经典的一个 bug。
2. **属性值不能用 CDATA。** CDATA 只存在于元素内容。`Always` 只影响文本节点，
   属性值仍然走 7.2 的转义规则。文档里要写明，否则会有人以为"开了 CDATA 就不用转义了"。

还有一个副作用值得提前说明：`Always` 会让空白变得更"硬"。
`<t><![CDATA[  x  ]]></t>` 里的空格是实打实的内容，不会被任何 `trimWhitespaceOnly` 逻辑清掉。
这符合预期，但输出体积会比 `Auto` 大。

### 7.6 自定义实体引用

有些文档需要输出 `&nbsp;`、`&company;` 这类自定义实体。这里要区分两种做法，**只做第二种**：

| 做法 | 评价 |
|---|---|
| 把文本里出现的 `&company;` 当作实体引用直接输出（隐式） | ❌ 不可做：普通文本里出现 `&company;` 会被误当实体，调用方无法控制 |
| **显式节点 `XmlEntityRef(name)`** | ✅ 只有显式构造才输出 |

```cangjie
// 仓颉不允许类继承 enum，所以这里是**工厂函数**，返回 XmlNode.EntityRefNode
public func XmlEntityRef(name: String): XmlNode

public class EntityDecl {
    public let name: String
    public let value: ?String        // 外部实体为 None
    public let publicId: ?String
    public let systemId: ?String
    public let parameter: Bool
}

public class Doctype {
    public let name: String
    public let publicId: ?String = None
    public let systemId: ?String = None
    /// 内部子集里的实体声明，按声明顺序写出
    public let entities: Array<EntityDecl> = []
}
```

生成时：

- `XmlEntityRef` 直接输出 `&name;`，**不做转义**
- 若 `options.doctype` 里声明了该实体，`write()` 开头先把 `<!DOCTYPE … [ … ]>` 写出去
- 否则按 `strictEntities` 处理：`true`（默认）在 `write()` 时报错；`false` 只告警

**一条硬规则：写了 `XmlEntityRef` 却没在 `doctype` 里声明它，默认报错，不静默输出。**
理由和 7.3 的非法字符一样——产出一个"自己都读不回来"的文档，比直接失败更糟。

---

## 8. 安全

XML 的三类经典攻击，防线随"支持内部实体"而变化：

| 攻击 | 机制 | 防御 |
|---|---|---|
| **实体膨胀（Billion Laughs）** | 内部子集里嵌套实体，指数级膨胀 | **软阈值溢出 + 硬限制拦截**（5.4.1）：深度 16 / 声明 1024 / 总量 2 GB 一旦超限立即中断；单实体 64 KB 与总量 8 MB 是软阈值，超了转临时文件续跑 |
| **XXE（外部实体）** | `<!ENTITY x SYSTEM "file:///etc/passwd">` | **不加载任何外部实体**：声明可识别，**引用即报错**，绝不读文件 |
| **SSRF via DTD** | 通过外部 DTD 拉远程 URL | **不加载外部子集**：任何 `SYSTEM` / `PUBLIC` 都不发起请求 |
| **参数实体炸弹** | 用 `%p;` 在 DTD 内部递归膨胀 | 参数实体同样计入三层上限与总量统计 |

**"支持内部实体"不等于"打开攻击面"。** 膨胀类攻击的防线是**上限**，不是"不支持"。
反过来，"完全不展开"的代价是把一整类合法文档判死——`xmlconf` 里 228 条用例正属于这一类，
更别说现实世界里的 DocBook、SOAP 老文档大量依赖内部实体。

三条实现要求：

1. **计数器是解析器实例级的，不是全局的**——否则并发解析互相干扰，还会让限流变成"谁先跑谁占额度"
2. 超限抛 `XmlException`，消息里带**实体名与已展开量**，否则用户无法判断是哪个实体的问题
3. `maxExpandedTotal` 只计"由实体展开产生的字符"，**原文本身不计**——否则一个 20 MB 的文档
   什么都没展开就撞上限

**仍不做的事**（明确写出来，避免误以为"支持 DTD"就是"什么都能读"）：
DTD **有效性**校验（内容模型与文档匹配、属性类型语义、默认属性注入）、外部子集加载、
NOTATION 语义处理。声明语法良构校验要做（非法声明报错），它属于良构性、不属于有效性。

---

## 9. 错误处理

```cangjie
public class XmlException <: Exception {
    public init(message: String, line: Int64, column: Int64)
    public init(message: String, line: Int64, column: Int64, kind: ?EntityLimitKind)
    public prop line: Int64
    public prop column: Int64
    /// 仅实体上限相关的异常有值；其余错误为 None
    public prop entityLimitKind: ?EntityLimitKind
}

/// 实体上限的分类。调用方据此决定"能不能降级重试"
public enum EntityLimitKind {
    | PerEntity       // 单实体展开超过 maxExpandedPerEntity（软）
    | Total           // 总展开量超过 maxExpandedTotal（软）
    | Depth           // 递归深度超过 maxDepth（硬）
    | Declarations    // 声明数超过 maxDeclarations（硬）
    | HardLimit       // 超过 maxExpandedHardLimit（硬）
    | AttributeValue  // 属性值中的实体超限（不支持溢出）
}
```

**为什么要分类**：软阈值（`PerEntity` / `Total`）在 `Spill` 模式下不会抛异常，
只在 `Strict` 模式下抛。调用方拿到这类异常时，可以**降级到 `Spill` 重试一次**——
而不是认定"这份文档坏了"。硬限制（`Depth` / `Declarations` / `HardLimit`）重试必然失败，
不该重试。

```cangjie
// 典型用法：严格模式解析失败，若只是软阈值超限，则降级重试
try {
    XmlParser.parse(input, XmlParserOptions(entityLimits: EntityLimits(overflowPolicy: Strict)))
} catch (e: XmlException) {
    match (e.entityLimitKind) {
        case Some(PerEntity) | Some(Total) =>
            XmlParser.parse(input, XmlParserOptions(entityLimits: EntityLimits(overflowPolicy: Spill)))
        case _ => throw e
    }
}
```

`AttributeValue` 单独一类：属性值**永远不支持溢出**（5.4.2），所以即使 `Spill` 模式也会抛。
调用方看到它就说明"这份文档的某个属性值太大"，无法通过改策略解决。

**必须带行列号。** XML 报错没有位置信息基本无法排查——机器生成的 XML 常常整份只有一行、长几十万字符，只说"解析失败"等于没说。

| 错误 | 检测 |
|---|---|
| 标签不配对 | 结束标签名与栈顶不符 |
| 多个根元素 | 根元素结束后又出现开始标签 |
| 无根元素 | 到达 EOF 时栈空但没建过根 |
| 属性重复 | 同名属性出现两次 |
| 非法字符引用 | `&#xZZ;`、超出 Unicode 范围、代理区码点 |
| 未声明前缀 | QName 解析时作用域里找不到 |
| 注释含 `--` | 词法扫描 |
| 提前 EOF | 标签未闭合 |

**原则：XML 是严格格式，解析要严格。** 不像某些业务格式可以"尽量读"，XML 不合法就是文件坏了，硬猜只会产生更难查的错。

---

## 10. 性能与内存

### 10.1 两条路径的开销

| 模式 | 内存 | 1 MB XML 耗时（A53 估算） |
|---|---|---|
| 事件流（不建树） | O(嵌套深度)，常数级 | 20~50 ms |
| DOM 模式 | O(节点数)，约 XML 体积的 5~10 倍 | 50~120 ms |

**10 MB 的 XML 文档，DOM 模式峰值可能到 100 MB**——这就是为什么大文件必须走事件模式。

### 10.2 优化要点

| 要点 | 说明 |
|---|---|
| 在**行缓冲**上扫描，不要在字节流上扫描 | 行已经是解码后的 `String`，窗口内判断字符零解码成本 |
| 不要用正则 | 正则回溯在 XML 上会灾难性变慢 |
| 用 **`f_base.StringGenerator`** 累积文本 | 内部是 `ArrayList<Byte>`，`append` 摊销 O(1)；避免 `String +` 的 O(n²)。**不用 `std.core.StringBuilder`**，理由见下 |
| 文本按段回调，不在词法层拼接 | 拼接成本交给 handler，事件模式下可以零拷贝 |
| 属性数组复用 | 小对象分配是主要开销之一 |

**为什么用 `f_base.StringGenerator` 而不是 `std.core.StringBuilder`**：

| | `StringGenerator` | `std.core.StringBuilder` |
|---|---|---|
| 内部存储 | `ArrayList<Byte>`（UTF-8） | 实现私有 |
| `append` 复杂度 | 摊销 O(1)（`ArrayList` 扩容翻倍） | 未承诺 |
| 拿字节 | `unsafeBytes(): Array<Byte>` | 需要 `toString()` 再转 |
| 拿去写 OutputStream | 直接给字节，零转码 | 要经过 String |
| 附加能力 | `indexOf` / `replace` / `trim` / `appendFromUtf8` | 少 |

对 f_xml 来说最关键的是**最后两行**：生成侧最终要把 UTF-8 字节写进 `OutputStream`，
`StringGenerator.unsafeBytes()` 直接给出字节数组，省掉"String → 再编码"的一趟。
而 `StringBuilder.toString()` 会新建一个 `String`，再 `encode` 一次，等于两次拷贝。

**它确实是同一个对象，所以没有 O(n²)**：1280 次 `append` 只是 1280 次 `ArrayList.add`，
扩容按翻倍走，总拷贝量 O(n)。这正是"同一个 StringBuilder 就没问题"的准确含义——
问题从来不在 append 次数，而在"每次 append 都产生新字符串"。

**注意 `size` 是字节数**：`StringGenerator.size` 返回 `utf8.size`（字节），
不是字符数。做"单块长度上限"判断时要用它，不要用 `toString().size`（后者要多一次全量转码）。

**`unsafeBytes()` 返回原始内部字节数组，不复制，零成本。**（已确认）

上一版按"每次调用都 O(n) 拷贝"推断是**错的**。真实语义是：

| 属性 | 值 |
|---|---|
| 是否拷贝 | **否**。返回内部数据，调用成本与内容长度无关 |
| 返回数组的长度 | **等于 `size`**（`ArrayList` 的冗余容量已被剪除） |
| 能否直接喂 `OutputStream.write` | 能，长度正好 |
| 会不会随 `append` 变化 | **不要依赖**，见下 |

**为什么"不要依赖"**：`StringGenerator` 内部是 `ArrayList<Byte>`，`append` 触发扩容时
会对底层数组做一次"新建更大的 + 拷贝"。所以同一个 `unsafeBytes()` 返回值：

- **扩容没发生**：可能看到后续 `append` 写入的字节（取决于返回的是不是同一块内存）
- **扩容发生了**：内部换了新数组，旧引用完全看不到新内容

两种情况的行为不一致，所以**不要把它当"活视图"用**。

```cangjie
let gen = StringGenerator("abc")
let snap = gen.unsafeBytes()       // 零拷贝，长度 3
gen.append("def")
// snap 会不会变成 [a,b,c,d,e,f]？—— 不确定，取决于是否扩容
// 想要最新内容就重新调一次，反正是零成本
let fresh = gen.unsafeBytes()      // 长度 6
```

**正确用法**：**要用就重新取，不要缓存**。之所以这样建议，不是因为"取一次很贵"，
而是因为"缓存了语义不确定"。重新取一次是零成本的，没有任何理由去缓存。

**`XmlWriter` 的惯例用法**完全不受影响：`close()` 时取一次、写出去、丢弃。

**`close()` 之后调 `unsafeBytes()` 是未定义行为**（已确认）。实现上不保证返回什么——
可能是最后一次的数据，可能是空数组，可能抛。文档与类注释都要明说
"`close()` 后不得再调用任何方法"。
| 前瞻由 `CharWindow` 提供 | **不要依赖 Reader 的 peek——它没有**；也别指望 `read()`，那个是逐字符 O(bufSize) |

### 10.3 字符层带来的固定开销

| 层 | 每单位成本 | 1 MB / 2 万行文档 |
|---|---|---|
| `readln()` | 一次 `newDecoder()` + 一次 `rotateLeft`（≤8 KB 搬运） | 2 万次解码器创建 + 约 160 MB 搬运 |
| `CharWindow` 填充 | 一次 `String` 拼接 + 一次指针推进 | 与行数线性，可忽略 |
| 词法扫描 | 每字符一次比较分支 | 100 万次分支 |

对比一下「直接用 `read()`」的代价：100 万次 `newDecoder()` + 100 万次 8 KB 搬运 ≈ **8 GB 搬运**。差 50 倍，这就是选行不选字符的全部理由。

> 这些是量级估算，不是实测。P6 阶段要在真实文档上量出 `readln` 的耗时占比；如果它超过总耗时的 30%，再考虑把 `bufSize` 调大或改用固定块解码。

---

## 11. 应用示例

四类典型场景，覆盖绝大多数用法。**它们是"能用这些原语拼出来什么"的示范，不是模块内置的专用逻辑**——f_xml 本身不认识 row、item、entry 这些业务标签。

### 11.1 示例 A：大文档流式消费（不建树）

适用于任何"记录式"XML——日志条目、交易流水、清单数据。

```cangjie
// 以 RSS 的 <item> 为例；换成 <entry>、<record>、<row> 结构完全一样
class ItemStreamHandler <: XmlEventHandler {
    public func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction {
        if (name.local == "item")    { current = ItemBuilder(attrs) }
        else if (name.local == "title") { inTitle = true }
        else if (name.local == "description") {
            return XmlAction.SkipSubtree        // 不关心的分支，整棵跳过（见 3.3）
        }
        XmlAction.Continue
    }
    public func onText(text: String): XmlAction {
        if (inTitle) { current.title.append(text) }
        XmlAction.Continue
    }
    public func onEndElement(name: QName): XmlAction {
        if (name.local == "item")       { sink.write(current); current = null }   // 立刻交出去，不保留
        else if (name.local == "title") { inTitle = false }
        XmlAction.Continue
    }
    // 其余事件返回 XmlAction.Continue
}
```

**关键点：`onEndElement` 里立刻把已完成的一条记录交出去，然后丢弃。** 内存与文档规模无关，只与单条记录的复杂度有关。

### 11.2 示例 B：小文档建 DOM 后取值

配置文件、SOAP 响应、RSS feed 这类几 KB 到几 MB 的文档，直接建树最省事：

```cangjie
let doc = XmlParser.parse(input)              // 内部用 DomBuilder
let root = doc.root ?? throw XmlException("无根元素", 0, 0)

// 按 local name 取值，不关心命名空间前缀
let title = root.child("channel")?.child("title")?.text()
for (item <- root.child("channel")?.childrenOf("item") ?? []) {
    println(item.child("link")?.text())
}
```

`child()` / `childrenOf()` 按 **local name** 匹配，所以 `<item>`、`<x:item>` 都能命中——调用方不用管前缀。

### 11.3 示例 C：构造并生成

```cangjie
let root = XmlElement(QName(None, "rss", Some("http://purl.org/rss/1.0/")))
root.setAttr("version", "2.0")

let channel = XmlElement("channel")
channel.appendChild(XmlElement("title").withText("我的订阅"))

root.appendChild(channel)

let writer = XmlWriter(output)         // 默认紧凑
writer.write(root)
writer.flush()
```

需要人看的输出才传 `indent: Some("  ")`。**程序消费的 XML 一律紧凑**——缩进空白会变成文本内容（见 7.1）。

### 11.4 示例 D：提前终止

只想要前 N 条时，不必读完整个文档：

```cangjie
class FirstNHandler <: XmlEventHandler {
    public func onEndElement(name: QName): XmlAction {
        if (name.local == "item") {
            count += 1
            if (count >= n) { return XmlAction.Stop }   // 解析器立即返回，不再读后续字节
        }
        XmlAction.Continue
    }
}
```

拉模式下更直接——`break` 跳出循环即可，不需要返回信号：

```cangjie
let pull = XmlPullParser(input)
while (let Some(e) <- pull.nextEvent()) {
    if (let XmlEvent.EndElement(n) <- e && n.local == "item") {
        if (++count >= n) { break }
    }
}
```

这对"探测大文件格式是否匹配"或"只看开头几条"的场景很实用——避免为了 10 条数据解析 500 MB。

---

## 12. 测试策略：证明通用性，而不是证明"能读五个格式"

### 12.1 先把测试目标摆正

**反模式**：拿 SOAP / OOXML / RSS / SVG / POM 各跑一遍，全过就宣布"通用"。

**为什么不够**：这五个格式只用到 XML 1.0 的一个子集，而且它们都是"生成器风格收敛"的文档——UTF-8、无 DTD 内部实体、结构规整。用它们做验收，测的是"这五个格式"，不是"XML"。

**正确的目标**：

> **XML 1.0 规范的每一条产生式都要有用例。五个格式只作为真实世界样本，用来验证"风格变体"能不能吃下。**

一个简单的自检：**如果明天来了一个从没见过的格式（比如 XBRL、DrawIO、AndroidManifest），它挂不挂？** 挂了说明测的是格式，不是 XML。

### 12.2 语法覆盖矩阵（核心）

按 XML 1.0 的结构分类。**"五格式覆盖"列标 ❌ 的，就是必须自己构造用例的盲区。**

#### A. 文档结构

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| XML 声明可省略 | 无声明也要能解析 | ⚠️ 生成器基本都写声明，**盲区** |
| 声明里 `encoding` / `standalone` 可省略 | 缺省按 UTF-8、standalone 视为 no | ⚠️ 少见 |
| 前导区多个注释 / PI | prolog 里可以交替出现任意多个 | ⚠️ 少见 |
| 尾部（epilog）注释 / PI | 根元素之后还允许注释和 PI | ❌ **盲区** |
| 根元素唯一 | 两个根元素必须报错 | ❌ 需自造（错误用例） |
| 空文档 / 纯空白文档 | 必须报错"无根元素" | ❌ 需自造 |

#### B. 元素与属性

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| 自闭合 `<a/>` 与 `<a />` | 都合法，`/` 前可有空白 | ✅ |
| 空元素 `<a></a>` | 与自闭合等价 | ✅ |
| 属性单 / 双引号 | 都要支持 | ✅ |
| **属性值规范化** | 换行、制表 → 空格；字符引用不参与规范化 | ❌ **盲区**（生成器不写带换行的属性） |
| 重复属性 | 必须报错 | ❌ 需自造 |
| 属性值含裸 `<` | 必须报错 | ❌ 需自造 |
| 元素名大小写敏感 | `<A>` ≠ `<a>` | ⚠️ 需自造 |
| 名字里的非 ASCII | XML 1.0 允许大量 Unicode 字母 | ❌ 已自造（`NameSyntax_test.nonAsciiNames`） |
| 名字不能以数字开头 | 必须报错 | ❌ 已自造（`NameSyntax_test.nameMayNotStartWithDigit`） |

#### C. 字符数据与实体

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| 五个预定义实体 | `&lt; &gt; &amp; &quot; &apos;` | ✅（`&apos;` 少见，⚠️） |
| 十进制 `&#65;` | 支持 | ⚠️ 少见 |
| 十六进制 `&#x41;` | 支持 | ⚠️ 少见 |
| **高位码点** `&#x1F600;` | > U+FFFF 也要能解（正确产出代理对外的码点） | ❌ **盲区** |
| 非法码点 | `&#0;`、代理区、> U+10FFFF → 报错 | ❌ 需自造 |
| `&` 后跟非法引用 | `&nbsp;`、`&foo`、裸 `&` → 报错 | ❌ 需自造 |

#### D. CDATA

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| CDATA 内含 `<` `&` | 原样保留，不解析 | ✅（SVG `<style>`、RSS `<description>` 常见） |
| 空 CDATA `<![CDATA[]]>` | 合法，产出空文本 | ❌ 需自造 |
| CDATA 内含 `]]` | 只有 `]]>` 才结束 | ❌ **盲区** |
| 相邻多个 CDATA | 各自触发一次 `onCData` | ⚠️ 少见 |
| CDATA 与普通文本混合 | 顺序不能乱 | ⚠️ 少见 |

#### E. 注释与处理指令

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| 注释含 `<` `&` | 原样保留，不解析 | ⚠️ |
| 注释含 `--` | 必须报错 | ❌ 需自造 |
| 注释以 `-` 结尾 | 必须报错 | ❌ 需自造 |
| PI 的 target 不是 `xml` | `<?xml-stylesheet?>` 之类要能处理 | ✅ |
| PI target 为 `xml` | 保留字，必须报错 | ❌ 需自造 |
| PI data 含 `?` | 只有 `?>` 才结束 | ❌ **盲区** |

#### F. DOCTYPE

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| 简单 `<!DOCTYPE name>` | 识别并跳过 | ⚠️ |
| `SYSTEM` / `PUBLIC` id | 识别但不加载 | ⚠️ |
| **内部子集 `[...]`** | 内含 `>` 和引号，不能误判结束 | ❌ **盲区** |
| 内部子集里定义普通实体 | 声明 + 展开，允许嵌套 | ✅ 228 条用例覆盖，但边界（递归、跨实体引用）**仍需自造** |
| 参数实体 `<!ENTITY % p "v">` | 只在 DTD 内部可用 | ⚠️ 部分覆盖 |
| 实体递归 / 指数膨胀 | 深度/声明数硬限制立即报错；软阈值按 5.4.1 溢出 | ❌ **必须自造**（Billion Laughs）。注意 `Spill` 模式下炸弹会先写到 2 GB 才停，恶意样本测试固定用 `Strict` |
| 外部实体 / 外部子集 | **不加载**，引用即报错 | ⚠️ XXE 类有覆盖 |
| 条件段 `<![INCLUDE[` / `IGNORE[` | 内部子集里**必须报错**（`intSubset` 不含 `conditionalSect`，条件段只属于外部子集） | ❌ 已自造（`DtdIgnoreSection_test` / `DoctypeParser_test`） |
| 实体引用出现在属性值 | 先展开再做空白规范化 | ❌ **盲区**（顺序极易做反） |

#### G. 命名空间

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| 默认命名空间 | 元素继承 | ✅ |
| 前缀声明与使用 | `xmlns:x` + `<x:a>` | ✅ |
| **`xmlns=""` 重置** | 子元素回到无命名空间 | ❌ **盲区** |
| 嵌套重定义同一前缀 | 内层覆盖外层，出栈后恢复 | ❌ **盲区** |
| 多个前缀指向同一 URI | 视为同一命名空间 | ⚠️ |
| **属性不受默认命名空间影响** | `<a xmlns="X" b="1">` 里 `b` 无命名空间 | ❌ **盲区**（极易做错） |
| `xml:` 保留前缀 | 不需声明即可用 | ⚠️ OOXML 用到 |
| 未声明前缀 | 必须报错 | ❌ 需自造 |
| `xmlns` 作元素前缀 | 必须报错 | ❌ 需自造 |

> **"属性不受默认命名空间影响"这条必须单独测。** 它违反直觉：元素会被默认命名空间收进去，属性不会。做错了在 OOXML 里看不出来（那里的属性本来就没前缀），换个格式立刻暴露。

#### H. 字符集与编码

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| UTF-8 无 BOM | 基础 | ✅ |
| UTF-8 带 BOM | 跳过 BOM | ⚠️ |
| **UTF-16LE / BE 带 BOM** | 按 BOM 判字节序 | ❌ **盲区**（这五个格式几乎都是 UTF-8） |
| 声明与实际编码冲突 | **必须报致命错误**，消息带两个编码名与行列号 | ❌ 已自造（`ByteSniffer_test.bomConflictsWithDeclaration`） |
| 非 ASCII 内容 | 中文、日文、阿拉伯文 | ✅ |
| 4 字节 UTF-8（emoji） | 正确解出 1 个码点 | ❌ **盲区** |

#### I. 空白

| 语法点 | 要求 | 五格式覆盖 |
|---|---|---|
| 元素间空白 | 原样回调，是否忽略交给 handler | ✅ |
| 文本首尾空格 | 保留 | ⚠️ |
| `xml:space="preserve"` | 强制保留空白 | ⚠️ OOXML 的 `<t>` 用到 |
| `xml:space="default"` | 恢复默认行为 | ❌ 需自造 |

### 12.3 组合测试

上面的矩阵是"单个语法点"。真实文档里语法点是**叠加**的，而叠加容易暴露状态机缺陷：

- CDATA 出现在带命名空间的元素里
- 注释夹在两个属性之间（非法）vs 夹在元素之间（合法）
- PI 紧邻 CDATA 前后
- 自闭合元素里带命名空间声明（`<x:a xmlns:x="A"/>`）
- 深层嵌套中某层重置命名空间

建议做法：把"语法元素 × 语法元素"做成抽样矩阵，每个组合至少一份样本。格式样本通常是正交的，覆盖不到这些交叉。

### 12.4 xmlconf 一致性套件（验收项，已确定）

**版本锁定**：W3C XML Conformance Test Suite **20130923**（`xmlts20130923.tar.gz`，626 KB，官方最新发布版）

```
SHA-256  9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f
```

锁定版本和校验和，是因为这个套件本身也在修订——同一份代码在不同版本上跑出不同通过率，会让"回归"失去意义。

#### 规模与构成（实测，不是估算）

解压后 `xmlconf/` 下 **31 个 catalog 文件**，共 **2586 条 `<TEST>`**：

| `TYPE` | 数量 | 含义 | 我们的期望 |
|---|---|---|---|
| `valid` | 812 | 合法文档 | 解析成功 |
| `not-wf` | 1499 | 非良构（not well-formed） | 报 fatal error |
| `invalid` | 242 | **良构**但不符合 DTD | **解析成功**（只校验声明语法，不做 DTD 有效性校验） |
| `error` | 33 | 规范里的 "error"（处理器**可选**检出） | **不判定**，单列观察 |

`invalid` 必须解析成功这条最容易搞反：这类文件是**良构**的，只是违反了 DTD 约束。把 `invalid` 当"应该报错"去断言，会一次性错 242 条。

#### 可跑集与 unsupported

按**五条**规则（按此顺序去重）过滤后剩下的才是断言集：

1. **`EDITION` 含 1/2/3/4 的排除**（313 条）。第 5 版改了 `Char` 产生式，旧版用例的期望与之冲突。
2. **依赖外部实体的排除**（95 条）。`ENTITIES` 为 `parameter` / `general` / `both` 的共 323 条，
   实测其中 **228 条只用内部实体**（纳入可跑集），**95 条声明了 `SYSTEM` / `PUBLIC` 外部实体**（仍排除，
   因为外部实体永远不加载）。
3. **XML 1.1 用例的排除**（59 条）。M1 明确拒绝 `version="1.1"`（M3 才支持），这些用例留在
   可跑集只会制造必然失败；按原因 `xml-1.1` 写进 `unsupported`。
4. **外部子集用例的排除**（实测 47 条）。`TYPE=not-wf`、`DOCTYPE` 指向外部 DTD、且测试文件自身
   良构（用 `xml.parsers.expat` 以不加载外部子集的方式试解析可判定）——不良构只写在永不加载的
   `.dtd` 里，M1 不可能检出；按原因 `external-subset` 排除。
5. **命名空间名冲突的排除**（实测 10 条）。名字违反 Namespaces 1.0 的 `QName` 约束
   （多冒号 / 冒号在首尾 / 前缀未声明）——XML 1.0 合法但与命名空间感知处理器互斥；
   按原因 `namespace-name` 排除。

| 项 | 数量 |
|---|---|
| 套件总计 | 2586 |
| `unsupported`（313 + 95 + 59 + 47 + 10） | **524** |
| **可跑** | **2062** |
| ├ `not-wf` | 1106 |
| ├ `valid` | 705 |
| ├ `invalid` | 227 |
| └ `error`（不判定） | 24 |
| **实际断言数** | **2038** |
| 实测结果 | **2038 通过 / 0 失败**（Gate A 达成） |

> 前三轮口径的演进：两规则（2178 可跑 / 458 fail）→ 三规则（2119 / 2095 断言）→
> 五规则（2062 / 2038 断言）。第四、五条规则的条数是脚本实测值（47 / 10），不是估算：
> 早先按 48 / 9 估算，互补后总额相同（467 + 47 + 10 = 524）。
> 判定脚本 `f_xml/tools/xmlconf_gen.py` 与判定口径一起进仓库，否则以后没人能复核这个数字。

`unsupported` 必须单列清单并写入本模块文档，**不能混进通过率**——否则一个"支持 75% XML"的数字既看不出是真缺陷还是设计边界。

#### 五个落地坑（都踩过一遍才知道）

**① 聚合 catalog 解析不了——因为我们不展开外部实体**

`xmlconf/xmlconf.xml` 只是聚合器，本身不含 `<TEST>`：

```xml
<!DOCTYPE TESTSUITE SYSTEM "testcases.dtd" [
    <!ENTITY sun-valid   SYSTEM "sun/sun-valid.xml">
    <!ENTITY jclark-xmltest SYSTEM "xmltest/xmltest.xml">
    ...
]>
<TESTSUITE>
  &sun-valid;
  &jclark-xmltest;
  ...
</TESTSUITE>
```

31 个子 catalog 全靠 `SYSTEM` 外部实体引入。**用 f_xml 自己解析这个文件会得到一棵空树**——这不是 bug，正是"不加载外部实体"的必然结果。

**做法：一次性把 catalog 编译成扁平清单。** 用一个离线脚本（Python / `xmllint --noent`）展开实体，把所有 `<TEST>` 抽成 `cases.json`，随仓库提交：

```json
{"id":"o-p01pass2","type":"valid","uri":"oasis/p01pass2.xml","edition":null,"entities":"none","sections":"2.2 [1]"}
```

测试运行时只读这份 JSON，不再解析 catalog。好处有三：避开实体展开、跑得快、清单可 review、版本可锁。

**② `TYPE` 单双引号混用**

348 条用例的 `TYPE` 用单引号（`TYPE='valid'`），其余用双引号。harness 的正则/解析要两种都认；顺带这也是 f_xml 的属性解析必须支持两种引号的一个现成理由。

**③ `EDITION` 不是只有一个值**

取值有 `"5"`、`"1 2 3 4"`、以及缺省。缺省的不是"适用于所有版本"，而是"这条用例不区分版本"。判定规则按集合运算：`EDITION` 里包含 `1`~`4` 就排除。

**④ `OUTPUT` 指向规范化输出，首版不比对**

432 条用例带 `OUTPUT="out/xxx.xml"`，那是**规范化（canonical）后的期望输出**。要拿它做断言必须实现 C14N——属性排序、命名空间声明位置、空元素写法、字符引用展开，每一条都是独立的规范工作。

**首版只断言 well-formedness，不比对输出。** C14N 单列为后续可选能力；把它塞进首版验收会让整个计划被一个非核心特性拖住。

**⑤ 目录里不只有 `.xml`**

| 文件 | 用途 |
|---|---|
| `*.xml` | 用例本体 |
| `*.ent` | 外部实体，由 `ENTITIES` 属性指向 |
| `*.out` | 规范化期望输出，由 `OUTPUT` 指向 |
| `*.dtd` | 部分用例的外部 DTD |

判 harness 是否正确遍历，看的是 catalog 里的 `<TEST URI=...>`，不是"目录里有多少个 xml"。

#### 验收门槛

| Gate | 标准 |
|---|---|
| **A（必过）** | 2038 条断言全部符合期望：`valid`/`invalid` 解析成功，`not-wf` 报 fatal error |
| **B（例外管理）** | 允许一份 `known-issues.json`，每条必须写明理由 + 规范章节；上限 5 条，超出即视为不通过 |
| **C（可追溯）** | 每次跑测试输出三个数字：`pass / fail / unsupported`，并把 `unsupported` 的 ID 清单存档 |

`known-issues` 存在的理由是套件本身有已知争议用例（W3C 邮件列表里有讨论），不是给我们留后门。**任何新增例外都要走 review**，否则这个清单会变成掩盖缺陷的垃圾桶。

> **一句话**：`xmlconf` 的期望结果是规范给的，不是某个程序给的——这正是它能替代差分测试的原因。

### 12.5 五个格式样本：作用与局限

**作用（真实的、不可替代的）**：

| 格式 | 能验证什么 |
|---|---|
| RSS / Atom | CDATA 包裹 HTML、大量可选元素、`<item>` 记录式结构 |
| SVG | 命名空间前缀风格、CDATA（`<style>`）、大量属性、深层嵌套 |
| SOAP | 多层命名空间混用、前缀与默认命名空间交替 |
| POM | 注释密度、元素顺序敏感、嵌套层级 |
| OOXML | `xml:space="preserve"`、单行超长 XML、不同生成器的前缀风格差异 |

**局限（必须承认）**：

它们几乎都是 UTF-8、无 DTD 内部实体、无 `xmlns=""`、无高位码点、无属性值换行。**只靠这五个格式，12.2 里标 ❌ 的盲区一个都发现不了。**

所以定位是：

```
12.2 语法矩阵 + 12.4 xmlconf（2038 条断言）  →  保证"通用"
12.5 五个格式样本              →  验收"真实文档能跑通"
```

**两者都要，但不能用后者替代前者。**

### 12.6 详细用例表（补充 12.2 的具体断言）

#### 词法

| 用例 | 验证点 |
|---|---|
| `<a/>` | 收到 Start(selfClosing=true) + End 两个事件 |
| `<a></a>` | 收到 Start(selfClosing=false) + End |
| 连续文本被拆成多个 `onText` | DOM 里合并成一个文本节点 |
| `\r\n` 与单独 `\r` | 归一成 `\n` |
| UTF-8 BOM | 被跳过，不生成文本节点 |

#### 命名空间

| 用例 | 验证点 |
|---|---|
| 带前缀与不带前缀的同名元素 | `child("item")` 两者都能匹配 |
| `xmlns=""` 重置 | 子元素 uri = None |
| 属性与默认命名空间 | 未加前缀的属性 uri = None |

#### 往返

```
DOM → 序列化 → 解析 → DOM
```

两次 DOM 逐节点比对：元素名、属性、文本内容必须一致。

**注意**：属性顺序、命名空间声明位置、空白可能在往返中规范化，这些**不算失败**——只比语义，不比字符串。

### 12.7 反模式清单

| 反模式 | 后果 |
|---|---|
| 只测五个格式 | 来个新格式就挂，且不知道挂在哪 |
| 只测自己生成的 XML | 自己写自己读会互相容忍同一个错误 |
| 只测 happy path | 畸形输入直接崩溃或返回垃圾 |
| 用格式样本代替语法矩阵 | 覆盖率看起来很高，实际漏掉整类语法 |

### 12.8 恶意样本

- Billion Laughs（嵌套实体，应在**硬限制**内及时中断，且中断时内存不爆；测试用 `Strict` 模式，避免 `Spill` 写盘 2 GB）
- 参数实体版 Billion Laughs（`%p;` 递归）
- 单实体超长（> `maxExpandedPerEntity`）
- 深度刚好在上限内 / 刚好超限（边界两条）
- XXE（`SYSTEM "file:///etc/passwd"`，应报错且**不打开文件**）
- 外部子集 `<!DOCTYPE x SYSTEM "http://…">`（应**不发请求**）
- 超深嵌套（1 万层，应报错而不是栈溢出；上限是 `maxElementDepth`，默认 4096）
- 超长属性（单属性 100 MB，应有上限；上限是 `maxAttributeValueLength`，默认 1 MiB）

这两个上限是 M1 新增的选项（原设计只写「要有上限」没给配置项），超限抛 `XmlException` 并带元素名
/ 属性名与行列号。

---

## 13. 实施顺序

### 13.1 里程碑

| 里程碑 | 范围 | 出口标准 |
|---|---|---|
| **M1** | 解析（推 + 拉 + 单回调）、DOM、生成（紧凑/缩进、CDATA、自定义实体）、DTD 内部子集（实体 + 声明语法校验，含溢出策略）、安全上限 | xmlconf **Gate A：2038 条断言全过**（`known` ≤ 5）；`unsupported` 524 条清单存档；20 MB 展开量文档在 `Spill` 下 `retainedBytes` 恒定；性能不是出口条件 |
| **M2** | **XPath 1.0 子集（含命名空间前缀）** | 13.3 的范围表内全部可用；超范围表达式**报错**而不是返回空集；`ns:item` / `@ns:attr` / `defaultNamespace` 三类用例全过 |
| **M3** | **XML 1.1** + **C14N（inclusive 1.0/1.1 + exclusive 1.0）** | XML 1.1 用例进可跑集；inclusive 使 xmlconf 的 432 条 `OUTPUT` 可断言；exclusive 的命名空间裁剪用例对照 W3C 测试集 |

### 13.2 M1 阶段拆解

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P-1** | 字符层前置：验证 charset4cj 可编译；字节嗅探 + `PrefixStream` + `CharWindow`（**全部 f_xml 自实现**）；**实测 `Encoder.encode` 对不可映射字符的行为** | UTF-8 / GBK 各一份逐字符读出，行列号正确，BOM 被跳过；`bufSize` 实测出最优值；"GBK 写 emoji"到底抛/替换/跳过有定论，据此定 2.7 的往返校验是否需要 |
| **P0** | Lexer：标签、属性、文本、字符引用、五个预定义实体 | 能正确切分最小 XML |
| **P1** | 状态机 + 名称栈 + 配对校验 | 畸形 XML 报错且带行列号 |
| **P1.5** | 事件接口（推）+ `XmlAction` + `DomBuilder` | 简单 XML 能建出正确的树；`Stop` / `SkipSubtree` 生效 |
| **P2** | 拉模式 `XmlPullParser`（**推建立在它之上**） | 与推模式事件序列逐条一致（同一输入，两份事件日志比对） |
| **P2.5** | 接入 xmlconf：离线编译 `cases.json` + harness | 输出 `pass / fail / unsupported` 基线；此时**允许 fail**，基线入档 |
| **P3** | 命名空间作用域栈 | 带前缀的文档样本能正确解析 |
| **P3.5** | **DTD 内部子集**：实体表、参数实体、四类声明的语法校验、三层上限 + 溢出策略、属性值展开顺序 | 228 条实体用例通过；非法声明报错且带行列号；Billion Laughs 在 1 MB 内被中断（`Strict`）；`Spill` 模式下 20 MB 展开量的文档能读完且 `retainedBytes` 恒定 |
| **P4** | `XmlWriter`：紧凑/缩进、转义、输出缓冲、**CDATA 模式**、**自定义实体** | 往返语义一致；`]]>` 拆分正确；未声明实体报错 |
| **P5** | 安全收尾 + **Gate A** | 恶意样本被拒绝；2038 条断言全过；`known-issues` ≤ 5 |
| ~~P6~~ | 性能：**已由 `complete-f-xml-m1-followups` 达成**（Gate P） | 10 MB 1102 ms（`-O2`；同轮 `-O0` 旧代码 16.3 s，−93%）；见 §15.1 |

**为什么 P2.5 排在 P3.5 之前**：先拿到"能跑、能分类、有基线"，再补实体。
实体是本轮最大的新增变量——先做它再第一次跑套件，失败会混在一起，分不清是实体实现错了还是基础解析错了。

**P-1 是硬门槛。** 它只依赖 charset4cj 和标准库，一天能验完；不通就重选字符层，此时推翻成本最低。

**P2 的验收方式值得单独说**：同一份输入分别用推 / 拉跑一遍，把事件序列打成文本逐行 diff。
这是唯一能证明"两个前端行为一致"的办法——否则自闭合标签、文本拆分这类差异会藏很久。

### 13.3 M2：XPath 1.0 子集（含命名空间）

```cangjie
/// XPath 求值上下文。前缀 → 命名空间 URI
public struct XPathContext {
    /// prefix → uri。用于表达式里的 `ns:item`
    public let namespaces!: HashMap<String, String> = HashMap()
    /// 无前缀名字测试所用的默认命名空间（**不是** XML 的默认命名空间，见 13.3.1）
    public let defaultNamespace!: ?String = None
    /// 变量绑定（`$x`），M2 只支持外部注入，不支持 `<xsl:variable>` 那种定义
    public let variables!: HashMap<String, XPathValue> = HashMap()
}

public func selectNodes(node: XmlNode, xpath: String,
                        context!: XPathContext = XPathContext()): Array<XmlNode>
public func selectOne(node: XmlNode, xpath: String,
                      context!: XPathContext = XPathContext()): ?XmlNode
public func evaluate(node: XmlNode, xpath: String,
                     context!: XPathContext = XPathContext()): XPathValue
```

| 支持 | 不支持（**报错**，不静默返回空） |
|---|---|
| 绝对 / 相对路径 `/` `//`，`.` `..` | XPath 2.0+ 语法（`for`、`if`、序列） |
| 轴：`child` `descendant` `descendant-or-self` `parent` `self` `attribute` | 其余轴（`following-sibling` 等，M2 后按需） |
| 谓词 `[n]` `[@attr]` `[@attr='v']` `[child]` | 谓词里的函数嵌套 |
| **命名空间前缀 `ns:item`、`@ns:attr`**（13.3.1） | 前缀通配 `*:item`（XPath 2.0） |
| 函数：`name` `local-name` `namespace-uri` `string` `count` `position` `last` `contains` `starts-with` `not`，节点测试 `text()` `node()` | 扩展函数、正则函数 |
| 变量 `$x`（由 `XPathContext.variables` 注入） | 变量定义、XSLT 上下文 |

**关键约定：超范围表达式必须抛异常，不能返回空集。** 返回空集会让调用方以为"查过了，没有"，
这种沉默失败比报错难查得多——同一个原则在 12.2 也用过（未知关键字 fail-closed）。

#### 13.3.1 命名空间：三个必须说清的规则

**① 无前缀的名字测试匹配"无命名空间"的节点，不匹配默认命名空间**

这是 XPath 1.0 与 XML 命名空间**最反直觉的一处**，几乎所有人第一次都会踩：

```xml
<root xmlns="urn:example">
  <item id="1"/>
</root>
```

```cangjie
// 匹配不到任何节点！
selectNodes(doc, "//item")                    // → []

// 正确写法一：显式指定默认命名空间（本模块的扩展，非 XPath 标准）
selectNodes(doc, "//item", context: XPathContext(defaultNamespace: Some("urn:example")))

// 正确写法二：用前缀
selectNodes(doc, "//e:item",
            context: XPathContext(namespaces: {"e": "urn:example"}))
```

标准 XPath 1.0 只有"写法二"——它把"无前缀"固定解释为"无命名空间"，
没有任何语法能表达"默认命名空间"。`defaultNamespace` 是本模块的扩展。

**语义（严格标准兼容，v0.7 修正）**：

| `defaultNamespace` | 无前缀名字测试（如 `item`）匹配什么 |
|---|---|
| `None`（默认） | **只匹配无命名空间的节点**——与 XPath 1.0 标准完全一致 |
| `Some(uri)` | **只匹配 `uri` 命名空间的节点**，**不再匹配无命名空间的节点** |

**关键：`Some(uri)` 是"替换"默认解释，不是"额外尝试"。**

上一版设计成"先在无命名空间里找，找不到再按 `defaultNamespace` 找"。这有两个问题：

1. **同一表达式在不同文档上语义不同。** `count(//item)` 对一份"全是 `urn:x`"的文档
   返回 N，对一份"混合了无命名空间 item"的文档返回 N+M——调用方无法从表达式本身推断含义。
2. **与标准实现不可比。** 用标准 XPath 引擎跑同一个表达式会得到不同结果，
   这让"用我们的 XPath 校验一下"这件事失去意义，也无法拿外部工具做交叉验证。

改成"替换"后，行为是**封闭可预测**的：要么标准语义（`None`），要么明确覆盖（`Some`）。
代价是一份文档里同时有无命名空间和带命名空间的两类同名元素时，一个表达式只能匹配其中一类——
但那本来就该写两个表达式，而不是靠实现去猜。

```cangjie
// 一份文档里同时有 <item> 和 <e:item>（urn:example）
selectNodes(doc, "//item")                                  // 只拿到无命名空间的
selectNodes(doc, "//item", context: XPathContext(defaultNamespace: Some("urn:example")))
                                                            // 只拿到 urn:example 的
// 想要两类都要：写两个表达式，合并结果
```

**`defaultNamespace` 与 `namespaces` 的分工（必须写清，否则容易误解）**：

| 字段 | 管哪种名字测试 | 例 |
|---|---|---|
| `namespaces` | **带前缀**的 | `//e:item`、`@e:id` |
| `defaultNamespace` | **不带前缀**的 | `//item`、`@id`（属性见下） |

两者**互不影响、各管各的**，可以同时使用：

```cangjie
let ctx = XPathContext(
    namespaces: {"e": "urn:example", "m": "urn:meta"},
    defaultNamespace: Some("urn:doc")
)
// item  → urn:doc 命名空间
// e:item → urn:example 命名空间
// m:item → urn:meta 命名空间
selectNodes(doc, "//item | //e:item | //m:item", context: ctx)
```

**四个容易踩的组合**：

| 表达式 | `defaultNamespace` | 匹配 |
|---|---|---|
| `//item` | `None` | 无命名空间的 `<item>` |
| `//item` | `Some("urn:doc")` | `urn:doc` 的 `<item>`（**不含**无命名空间的） |
| `//e:item` | 任意（与本项无关） | `namespaces["e"]` 指定的 URI 的 `<item>` |
| `@id` | `Some("urn:doc")` | **无命名空间的 `id` 属性**（属性永远没有默认命名空间，见 ③） |

**如果 `namespaces` 里没有的某个前缀被用到** → 报错（13.3.1 ③ 下方），不返回空集。

**`defaultNamespace` 与 `namespaces` 指向同一个 URI 是合法的**，此时 `//item` 和 `//e:item`
匹配同一批节点——这常用于"调用方不确定文档用的是无前缀还是带前缀写法"的兼容场景。

**② `xml` 前缀恒可用，不需声明**

`xml` 前缀永远绑定 `http://www.w3.org/XML/1998/namespace`（XPath 规范要求）。
`@xml:lang`、`@xml:space` 可以直接写。若调用方在 `namespaces` 里给 `xml`
绑了别的 URI，**报错**（不允许覆盖）。

**③ 属性没有默认命名空间**

`@id` 永远匹配"无命名空间的属性"，与 `defaultNamespace` 无关。要匹配 `x:id` 必须写 `@x:id`
并在 context 里声明 `x`。这符合 XML 规范——`xmlns="..."` 只作用于元素，不作用于属性。

**未声明的前缀 → 报错**：

```
XmlException("XPath 使用了未声明的前缀 'ns'（第 1 个字符附近）")
```

不返回空集。理由同上：静默失败最难查。

#### 13.3.2 三个"名字"函数的区别

| 函数 | `<x:item xmlns:x="urn:e">` 的返回值 |
|---|---|
| `name()` | `"x:item"`（原始 QName，带前缀） |
| `local-name()` | `"item"` |
| `namespace-uri()` | `"urn:e"` |

**M2 必须三个都实现**：只做 `local-name()` 会让带命名空间的文档无法区分同名不同命名空间的元素。

### 13.4 M3：XML 1.1 与 C14N（inclusive + exclusive）

| 项 | 差异点 |
|---|---|
| XML 1.1 | 字符范围放宽（`#x1`–`#x1F` 允许**以字符引用形式**出现）；`#x85` / `#x2028` 也算行分隔符；名字按 1.1 产生式；`xml:base` |
| C14N 1.0 (inclusive) | 属性排序、命名空间声明位置与去重、空元素写法、字符引用展开、`xml:` 属性处理 |
| C14N 1.1 (inclusive) | 在 1.0 基础上修正 `xml:id`、`xml:base` 的处理 |
| **Exclusive C14N 1.0** | 只输出**实际被使用**的命名空间声明，可配 `InclusiveNamespaces` |

```cangjie
public enum C14nMode {
    | Inclusive10        // http://www.w3.org/TR/2001/REC-xml-c14n-20010315
    | Inclusive11        // http://www.w3.org/2006/12/xml-c14n11
    | Exclusive10        // http://www.w3.org/2001/10/xml-exc-c14n#
}

public class C14nOptions {
    public var mode: C14nMode = C14nMode.Inclusive10
    /// 仅 Exclusive 有效：这些前缀即使"没用到"也强制输出
    public var inclusivePrefixes: Array<String> = []
    /// 仅 Exclusive 有效：把属性值里所有形如 "p:local" 的串都当成 QName，
    /// 从而输出 p 对应的命名空间声明。宁多勿漏的开关，默认 false
    public var assumeQNameInValues: Bool = false
    /// 是否输出注释。默认 false（签名场景不用注释）
    public var withComments: Bool = false
}

public func canonicalize(node: XmlNode, options!: C14nOptions = C14nOptions()): String
public func canonicalize(output: OutputStream, node: XmlNode,
                         options!: C14nOptions = C14nOptions()): Unit
```

#### 13.4.1 inclusive 与 exclusive 的差别，以及为什么两个都要

**差别只有一条，但影响巨大**：命名空间声明输出多少。

```xml
<s:Envelope xmlns:s="urn:soap" xmlns:xs="urn:xsi">
  <s:Body>
    <Payload>data</Payload>
  </s:Body>
</s:Envelope>
```

对 `<s:Body>` 单独做规范化：

| 模式 | 输出 |
|---|---|
| **Inclusive** | `<s:Body xmlns:s="urn:soap" xmlns:xs="urn:xsi">…</s:Body>` |
| **Exclusive** | `<s:Body xmlns:s="urn:soap">…</s:Body>` |

inclusive 把祖先的 `xmlns:xs` 也照搬下来，虽然 `s:Body` 完全没用到它。

**为什么这很要命**：XML 签名（XMLDSig）的场景是"把某个子树摘出来单独签名/验签"。
用 inclusive 时，外层多加一个 `xmlns:xs` 就会改变子树的规范化结果，**签名立刻失效**。
exclusive 让子树的规范化结果与外部上下文无关，这正是签名需要的。

**为什么两个都要**：

| 模式 | 谁在用 |
|---|---|
| Inclusive 1.0 | `xmlconf` 的 432 条 `OUTPUT` 就是这个（12.4 的验收依赖它） |
| Inclusive 1.1 | Office Open XML 的数字签名（OPC 规范指定） |
| Exclusive 1.0 | XMLDSig 的常见选择、SOAP 消息签名 |

只做 inclusive 就用不了 SOAP 签名；只做 exclusive 就吃不下 xmlconf 的 `OUTPUT` 断言。
所以两个都做，`C14nMode` 三值。

#### 13.4.2 exclusive 的"实际使用"判定

判定范围**不止元素名和属性名的前缀**，还包括：

1. 元素名的前缀（`s:Body` 用到 `s`）
2. 属性名的前缀（`@xsi:type` 用到 `xsi`）
3. **属性值里出现的 QName**（`xsi:type="tns:MyType"` 用到 `tns`）—— 见下

第 3 条是 exclusive C14N 的规范要求（§2.2 "visibly utilizes"）。实现上不能简单扫前缀，
必须对**已知的 QName 类型属性**做解析。实际做法：

```
对每个属性：
  若属性名 ∈ { xsi:type, xsi:nil, xsi:schemaLocation, ... } 或属性值形如 "prefix:local"
  且 prefix 在命名空间作用域里存在 → 视为使用了该 prefix
```

**更稳妥的做法**：调用方通过 `inclusivePrefixes` 显式声明。规范本身也提供了
`InclusiveNamespaces PrefixList` 机制来兜住这类"值里带 QName"的情况：

```cangjie
canonicalize(body, options: C14nOptions(
    mode: C14nMode.Exclusive10,
    inclusivePrefixes: ["tns"]        // 即使判定器没识别出来，也强制输出
))
```

#### 13.4.2.1 三个位置都要跳过 `xml` / `xmlns`

判定器要从**三个位置**收集"已使用的前缀"，每一处都要排除两个保留前缀：

| 位置 | 例 | 是否计入 |
|---|---|---|
| 元素名 | `<xml:foo>`（不合法，但解析器可能见过） | ❌ `xml` 恒绑定，不需要声明 |
| 属性名 | `xml:lang`、`xml:space`、`xml:base` | ❌ 同上 |
| 属性值（由 `assumeQNameInValues` 处理） | `xsi:type="tns:T"` | 命中 `tns` ✅，命中 `xml` ❌ |
| `xmlns` / `xmlns:foo` 属性本身 | `xmlns:foo="urn:x"` | ❌ 它是**声明**，不是**使用** |

**为什么 `xmlns` 也要排除**：`xmlns:foo="urn:x"` 这条属性是在"声明 foo"，
不是在"使用 foo"。如果把它算成"已使用"，会导致"自己声明自己"的循环逻辑——
声明本来就会输出，重复计算没有意义，还可能让 `stopIfTrue` 之类的规则误判。

**输出时也不能给 `xml` 发声明**：`xmlns:xml="http://www.w3.org/XML/1998/namespace"`
在 XML 1.0 里是**非法**的（这个前缀被保留，绑定不可更改）。任何情况下都不能输出它。

```cangjie
func isReservedPrefix(p: String): Bool {
    p == "xml" || p == "xmlns"
}

// 三个位置统一用这一个判断
if (!isReservedPrefix(prefix)) { usedPrefixes.add(prefix) }
```

**实现策略**：判定器做保守估计（识别 `xsi:type` 这类常见 QName 属性），
`inclusivePrefixes` 作为兜底。

#### 13.4.3 `assumeQNameInValues`：宁多勿漏的开关

保守估计会漏：如果某个业务的属性值是自定义的 QName 形式（比如 `data-type="ns1:Report"`），
而 `data-type` 不在已知的 QName 属性列表里，判定器不会输出 `ns1` 的声明——签名就可能对不上。

```cangjie
canonicalize(body, options: C14nOptions(
    mode: C14nMode.Exclusive10,
    assumeQNameInValues: true          // 把属性值里所有 "p:local" 都当 QName
))
```

**它做什么**：扫描每个属性值，凡匹配 `^[A-Za-z_][\w.-]*:[A-Za-z_][\w.-]*$` 的形状，
就把冒号前的前缀记为"已使用"。

**必须跳过 `xml` 前缀**：`xml` 是硬绑定的（`http://www.w3.org/XML/1998/namespace`），
永远不能被重新声明。如果属性值是 `xml:lang` 这类，把它当成"已使用"并输出一条
`xmlns:xml="..."` 是**非法**的，C14N 结果本身就坏了。

```cangjie
func scanQNameInValues(attrs: Array<XmlAttribute>): Set<String> {
    let used = HashSet<String>()
    for (a in attrs) {
        if (let Some(prefix) = qnamePrefixOf(a.value)) {
            if (prefix != "xml" && prefix != "xmlns") {   // 两个保留前缀都跳过
                used.add(prefix)
            }
        }
    }
    used
}
```

`xmlns` 前缀也要跳过——它只在 `xmlns:foo="..."` 这种声明位置出现，不是值里的 QName。

**代价**：

| 项 | 影响 |
|---|---|
| 输出体积 | 偏大（多输出几条 `xmlns:` 声明） |
| 合法性 | **完全合法**——多声明命名空间不违反 C14N |
| 签名一致性 | 与"另一侧的验证器"必须用同一个开关，否则两边输出的声明集不同，签名对不上 |
| 误判风险 | `"http://x"` 这类值含 `:` 但前缀部分含 `//`，正则天然排除；`"a:b"` 这种普通文本会被误当 QName，多输出一条 `xmlns:a`（若 `a` 在作用域里） |

**默认 `false`**：绝大多数文档的 QName 都在 `xsi:` 系列里，保守估计够用。
只有"自有属性里带 QName"的场景才需要开。

**与 `inclusivePrefixes` 的分工**：

| | 粒度 | 适用 |
|---|---|---|
| `inclusivePrefixes` | 指定**哪几个前缀**无条件输出 | 你明确知道会漏哪几个 |
| `assumeQNameInValues` | **自动**扫描所有属性值 | 你不知道会漏，宁可多输出 |

**两者可以同时用**，结果取并集。

#### 13.4.4 实现顺序

```
1. Inclusive 1.0（先做，xmlconf 验收依赖它）
2. Exclusive 1.0（判定器复用 inclusive 的作用域栈）
3. Inclusive 1.1（与 1.0 的差异只有 xml:id / xml:base 两处）
```

C14N 的收益很具体：`xmlconf` 里 **432 条带 `OUTPUT`** 的用例可升级为"序列化等价"断言，
验收从"良构性"提升到"结构等价"。代价也不小（属性排序 + 命名空间规范化是独立一块），所以放 M3。

---

## 14. 已定事项与剩余问题

### 14.1 已定（不再讨论）

| # | 事项 | 结论 | 里程碑 |
|---|---|---|---|
| 1 | DTD 内部子集实体 | **支持**（普通 + 参数实体）；外部实体 / 外部子集仍不加载；三层膨胀上限 | M1 |
| 2 | XPath | **做**，XPath 1.0 子集 | **M2** |
| 3 | XML 1.1 | **做** | **M3** |
| 4 | 自定义实体 / CDATA 输出 | **都做**：`CdataMode` + `XmlEntityRef` + `Doctype` | M1 |
| 5 | pull parser | **做**，且推模式建立在它之上 | M1 |
| 6 | `skipElement()` | **做**：推返回 `XmlAction.SkipSubtree`，拉调 `skipElement()` | M1 |
| 7 | `PrefixStream` | **f_xml 自实现**（`f_io` 保持现状、不再增补） | M1 前置 |
| 8 | `TextReader.bufSize` | **可配**（`XmlParserOptions.bufSize`），默认 8192，P-1 实测最优值 | M1 |
| 9 | C14N | **做**，排 M3；届时 432 条 `OUTPUT` 进断言集 | **M3** |
| 10 | 数据源抽象 | 只认 `std.io.InputStream`；`ByteBuffer` 能传进来但**不 import** | M1 |
| 11 | 编解码失败策略 | 读 `InvalidByteMode`、写 `InvalidCharMode`，默认都严格 | M1 / 2.7 |
| 12 | `EntityLimits` 超限 | **软阈值溢出到临时文件续跑**，硬限制（深度/声明数/2 GB）仍拦截 | M1 |
| 13 | 回调签名 | **保留 `XmlAction` 返回值**；接口全部带默认实现；新增单回调 lambda 重载；**不加 `stop()`** | M1 |
| 14 | XPath 命名空间 | **M2 支持前缀**：`XPathContext{namespaces, defaultNamespace, variables}` | **M2** |
| 15 | C14N 模式 | **inclusive 1.0 / 1.1 + exclusive 1.0 全做**；exclusive 支持 `InclusiveNamespaces` | **M3** |
| 16 | 溢出策略的测试分工 | **正常文档用 `Spill`，恶意样本固定用 `Strict`** | M1 |
| 17 | `defaultNamespace` 语义 | **严格标准兼容**：`Some(uri)` 是"替换"而非"额外尝试"；与 `namespaces` 各管各的（13.3.1） | **M2** |
| 18 | `C14nOptions.withComments` | 默认 **`false`** | **M3** |
| 19 | 实体异常分类 | **`XmlException.entityLimitKind`**，六值枚举；软阈值可降级重试 | M1 |
| 20 | 文本累积 | 用 **`f_base.StringGenerator`**（`ArrayList<Byte>`，`unsafeBytes()` 零转码），不用 `StringBuilder` | M1 |
| 21 | `assumeQNameInValues` | **提供**，默认 `false`；与 `inclusivePrefixes` 取并集 | **M3** |
| 22 | `@When` 平台分支 | 只两个分支：`os == "Linux"` 与 `os != "Linux"`，后者兜底所有其他平台 | — |
| 23 | `unsafeBytes()` 语义 | **零拷贝原始数据**，长度 == `size`（冗余已剪除）；不保证是"活视图"，要用就重新取 | M1 |
| 24 | `close()` 之后 | **未定义行为**；类注释与文档都要写"close 后不得再调用" | M1 |
| 25 | 保留前缀 | `xml` / `xmlns` 在**元素名 / 属性名 / 属性值 / xmlns 属性本身**四处都跳过 | **M3** |
| 26 | `AttributeValue` 消息 | **带属性名**（`属性 'r' 的值中实体展开超过 64 KB`） | M1 |

### 14.2 需要确认

**暂无阻塞项。** 二十六项决策已全部落地，可以进入实施。

实施中唯一需要实测的性能点：

1. **`StringGenerator` 的 `ArrayList<Byte>` 扩容策略是否翻倍？**
   `append` 摊销 O(1) 依赖"扩容翻倍"。如果是固定增量（如每次 +1024），
   大文档会退化成 O(n²)。实施第一步用 10 万次小 `append` 测耗时曲线，
   确认是线性还是二次。**这条无法从文档推断，必须实测。**

> `unsafeBytes()` 的性能问题已排除：它是零拷贝，不存在"调用一次付一次 O(n)"。
> 上一版把它当快照拷贝，是错的。

### 14.3 实施前必须实测的三条

| 项 | 怎么验 | 期望 |
|---|---|---|
| `StringGenerator` append 复杂度 | 10 万次 `append("x")`，看耗时是否线性 | 线性（总耗时 ~ 1e5 × 常数） |
| `ArrayList<Byte>` 的扩容倍数 | 连续 append，记录底层数组的换新时机 | 约 ×2 增长 |
| `unsafeBytes()` 是否零拷贝 | 同一 gen 连续取两次，比 `a === b` | 大概率 **true**（同一数组）；若 false 则说明每次做了裁剪拷贝，性能结论要修正 |

---

## 15. 实施回填（M1，`implement-f-xml-m1`）

本节记录设计与最终实现之间的**事实差异**，避免后来者按旧描述改代码。完整理由见
[`doc/spec/implement-f-xml-m1/design.md`](spec/implement-f-xml-m1/design.md) §8 与 §10.1。

| # | 设计原文 | 实施结果 | 原因 |
|---|---|---|---|
| 1 | §1.3 依赖 `charset4cj = "1.0.6"` | **保持 `1.0.5`** | 仓库 9 个模块统一；1.0.5 的包路径已是 `charset4cj.charset.*`。 |
| 2 | §7.6 `class XmlEntityRef <: XmlNode` | `XmlNode.EntityRefNode(String)` + 工厂函数 `XmlEntityRef(name)` | 仓颉不允许类继承 enum。 |
| 3 | §4 `XmlDocument.builder` 公开 | `internal`，公开 API 不含 `builder` | 建成后 builder 栈已空，外露只会诱导误用。 |
| 4 | §12.8 要求超深嵌套 / 超长属性有上限但未给配置 | 新增 `maxElementDepth`（4096）与 `maxAttributeValueLength`（1 MiB） | 补上缺失的配置项与两类错误。 |
| 5 | §2.6 只有两个 `RuneSource` 实现 | **三个**：新增 `BlockRuneSource`（UTF-16/32 固定块）与共享 `ByteDecoder` | `readln()` 按字节找 `0x0A`，UTF-16 的 U+0A00 会被误判为换行。 |
| 6 | §2.7 读方向 `Strict` 走 `std.io.StringReader` | 改走自研 `Utf8Strict` 字节解码（**不复用** `Replace` 的 maximal-subpart 逻辑） | `StringReader.read()` 每个字符一次 `Option` 堆分配（实测 ~400 ns/字符）；`readln()` 又无法区分「行尾换行」与「文件结束」。 |
| 7 | §9 `class XmlException <: Exception` | `XmlException <: f_base.BaseException` | 仓库统一异常基类。 |
| 8 | §5.4 `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>`「识别并跳过，不校验」 | 四类声明都做**声明语法良构校验**，非法声明报错 | 声明语法属良构性（WFC），有效性（VC）另说；不校验会让 xmlconf 385 条 `not-wf` 永远失败。 |
| 9 | §5.4「实体值内部只能引用已声明实体，前向引用 fatal」 | **延迟展开**：声明时只存原文，实体被使用时才展开；此时仍未声明才报错 | 声明时展开会把 `sa02` / `sa03` / `sa04` / `not-sa04` / `valid-sa-115` 这批合法文档判死。 |
| 10 | §5.4.3 `standalone` 只对「外部子集声明的实体」生效 | 扩展到所有**未声明实体**，分三档：`yes` 报错；**无外部子集且无参数实体引用时报错**；有外部子集或参数实体引用且非 `yes` 时跳过并告警 | 只看 `standalone` 会把 `<a>&nbsp;</a>` 这类笔误吞成空文本；反过来无条件放过会让 `not-sa03` / `rmt-e3e-13` 被误判成错误。 |
| 11 | §12.4 / §13 的「2154 断言、408 unsupported」 | **2038 断言 / 524 unsupported**：新增 `xml-1.1`（59）、`external-subset`（实测 47）、`namespace-name`（实测 10）三条排除规则 | 前两条：外部子集永不加载、XML 1.1 明确拒绝，留在可跑集必然失败；第三条：M1 一律做命名空间解析。 |
| 12 | §12.2 H「BOM 与声明冲突：以 BOM 为准，或按规范报错」 | **报 fatal error**，消息带两个编码名与行列号；`UTF-16` / `UTF-32` 不指定字节序，与两种 BOM 都相容 | 猜编码会让「声明与实际不符」的错误文档静默通过，而这类文档本该被拒（XML 1.0 §4.3.3）。 |
| 13 | §5.4「条件段按标志位选分支」 | 内部子集出现 `<![INCLUDE[` / `<![IGNORE[` **一律报错** | `intSubset` 产生式里没有 `conditionalSect`，外部子集又永不加载，M1 不存在合法入口能到达条件段。 |
| 14 | §5.4 只要求「非法声明报错」 | 追加 **单实体替换文本良构校验**（WFC: Parsed Entity）：标签必须在实体内部配平，孤立结束标签 / 未闭合标签报错并带实体名 | 否则 `<a>&e;</a>` 配 `<!ENTITY e "<b>">` 会静默接受，`sa-104` / `sa-116` 这批 `not-wf` 永远失败。 |
| 15 | §5.4 属性值「非 CDATA 去首尾」但未说类型从哪来 | 建「元素**字面名** → 属性名 → `AttType`」映射，未声明属性按 `CDATA`；映射**只**服务规范化，不做有效性 | 不做映射就只能一律按 `CDATA`，`rmt-ns10-012` 这类「规范化后命名空间绑定相同」的用例检不出。 |
| 16 | — | `known-issues.json` **清空为 0 条** | 原 5 条「命名空间 vs XML 1.0 多冒号名」已由 `namespace-name` 排除规则整体移出可跑集，不再占用例外额度。 |
| 17 | §13.2 P6「10 MB < 1 s」 | 性能移出 M1 出口，只记录 1 MB ≈ 1.5 s / 10 MB ≈ 15.8 s | 瓶颈在字符层逐字符 `Option` 分配与三层缓冲，需整体重写，另开 `optimize-f-xml-char-layer`。 |

### 15.1 性能现状（Gate P 已达成）

实测口径：合成 `InputStream`（不落地大文件）、事件模式、`bufSize = 8192`、3 次取 `min`、
`-O2` 交付构建（`f_xml/cjpm.toml` 已加 `-O2`）。

| 场景 | 实测 | 出口要求 |
|---|---|---|
| 事件模式 1 MB | **80 ms**（80311 events） | 只记录 |
| 事件模式 10 MB | **1102 ms**（764857 events） | **Gate P：< 7200 ms** ✓ |
| 事件模式 50 MB | **5.42 s**（3726208 events） | 只记录 |
| 峰值 RSS | `VmHWM(10 MB) = 294 956 kB`、`VmHWM(50 MB) = 294 988 kB`（差值 32 kB） | **差值 ≤ 24 MB 且 ≤ 320 MB** ✓ |
| DOM 模式 10 MB | 与事件模式同量级（DOM 本身另占内存） | 只记录 |

10 MB 相对同轮 `-O0` 旧代码 16 346 ms 提升 **93.3%**；相对 M1 记录 9649 ms（`-O0`）快 88.6%。
`bufSize` 实测曲线（R5）：

| bufSize | 1 MB min | 10 MB min |
|---|---|---|
| 4096 | 81 ms | 1111 ms |
| 8192（默认） | 80 ms | 1104 ms |
| 16384 | 74 ms | 1001 ms |
| 65536 | 82 ms | 1099 ms |

16K 在本机有约 9% 的边际收益但不构成拐点（< 15% 的改默认门槛）；**默认值维持 8192**。

实现路径：字符层从「逐字符解码 + 两级环形缓冲」改为「按块解码 + 单一活动缓冲」——
`BufferedRuneSource` 按块产出码点（UTF-8 连续 ASCII 段一次搬运），`LineWindow` 成为唯一的
活动码点块，词法器扫描循环全部改 `Int64` 码点入口并去掉每次 `startsWith` 的数组分配。
按 `complete-f-xml-m1-followups` 实施，详见
[`doc/spec/complete-f-xml-m1-followups/`](spec/complete-f-xml-m1-followups/)。

> 本模块交付口径为 `-O2`，RSS 绝对阈值相应校准为 320 MB。10 MB 已到 1.1 s，距原始绝对目标
> 1 s 仅差约 10%；剩余每事件语义分配移交 `optimize-f-xml-semantic-layer`。


### 15.2 一致性验收

xmlconf 20130923 的可跑集与断言数（2586 / 524 / 2062 / 2038）与 §12.4 一致，**Gate A 已达成**：
实测 `pass=2038 fail=0 unsupported=524 known=0`。旧口径（可跑 2178）的 458 条 fail 的收口路径是
385（声明语法校验）+ 59（XML 1.1 移出可跑集）+ 47（外部子集）+ 10（命名空间名）+
19（前向引用 / `standalone` / 单实体替换文本 / 属性值规范化 / BOM 冲突 / 条件段）。详见
[`doc/spec/implement-f-xml-m1/baseline.md`](spec/implement-f-xml-m1/baseline.md)。
