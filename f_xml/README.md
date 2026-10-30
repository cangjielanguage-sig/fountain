# f_xml

通用 **XML 1.0** 解析与生成模块。**不绑定任何业务格式**：RSS / Atom、SVG、SOAP、POM、
Android 布局、OOXML 或任意配置文件，只要符合 XML 1.0，都走这一套能力。模块不认识任何
业务标签，只负责把 XML 讲清楚。

> 设计与取舍见 [`doc/f_xml模块设计.md`](doc/f_xml模块设计.md)。

## 依赖

```
f_xml
├── f_base               StringGenerator（UTF-8 字节累积，unsafeBytes 零转码）
├── charset4cj           UTF-8 之外的编码（GBK / UTF-16 / UTF-32 …）
└── std.io / std.fs      字符串与字节流
```

- **不依赖 `f_io`**：数据源只认 `std.io.InputStream`，任何实现了该接口的缓冲区都能传进来。
- 完全自研，不参考任何现有 XML 实现；行为依据是 XML 1.0 规范与 Namespaces in XML 1.0。

## 能力（按里程碑）

| 里程碑 | 范围 |
|---|---|
| M1 | 推 / 拉 / 单回调三种解析前端、DOM、生成器、DTD 内部子集（含声明语法校验）与溢出策略、安全上限 |
| M2 | XPath 1.0 子集（含命名空间前缀） |
| M3 | XML 1.1、C14N（inclusive 1.0/1.1 + exclusive 1.0） |

## 能力表（M1）

| 能力 | 入口 | 说明 |
|---|---|---|
| 拉模式 | `XmlPullParser.nextEvent()` / `skipElement()` | 唯一内核，`None` 表示文档结束 |
| 多回调 | `XmlParser.parse(input, handler)` | 只覆盖关心的方法，其余默认 `Continue` |
| 单回调 | `XmlParser.parse(input) { e => … }` | 不建 DOM |
| DOM | `XmlParser.parse(input / bytes / text / path)` | 4 个重载，`parse(text)` 跳过字节嗅探 |
| 命名空间 | 内建 | 默认命名空间继承、`xmlns=""` 重置、属性不受默认命名空间影响 |
| DTD 内部子集 | `<!ENTITY>`（普通 + 参数）+ 四类声明的语法良构校验 | 外部实体与外部子集**永不加载**；不做 DTD 有效性校验 |
| 生成 | `XmlWriter` | 紧凑 / 缩进、CDATA 三模式、自定义实体引用、输出编码 |

## 用法示例

### 1. 流式解析大文档（不建树）

```cangjie
let parser = XmlPullParser(File("rss.xml", OpenMode.Read))
while (let Some(event) <- parser.nextEvent()) {
    match (event) {
        case XmlEvent.StartElement(name, _, _) => if (name.local == "item") {
            // 只关心 item，其余整棵子树跳过
            parser.skipElement()
        }
        case _ => ()
    }
}
```

### 2. 建 DOM 后取值

```cangjie
let doc = XmlParser.parse(File("pom.xml", OpenMode.Read))
let root = doc.root.getOrThrow()
let groupId = root.child("groupId").getOrThrow().text()
```

### 3. 生成

```cangjie
let element = XmlElement("rss")
element.setAttr("version", "2.0")
element.appendChild(XmlNode.ElementNode(XmlElement("channel").withText("我的订阅")))
let output = ByteBuffer()
XmlWriter(output, options: XmlWriterOptions(indent: Some("  "))).write(element)
```

## 安全边界

- **外部实体不加载**：`<!ENTITY x SYSTEM "…">` 声明可识别，**引用即报错**；外部子集
  （`SYSTEM` / `PUBLIC` 指向的 `.dtd`）永不打开，也不会发起任何网络请求。
- **三层上限**：单实体 64 KB / 总量 8 MB（软，可 `Spill` 到临时文件续跑）、
  深度 16 / 声明数 1024 / 展开总量 2 GB（硬，直接抛）。
  异常带 `entityLimitKind`，软阈值可判断后**降级重试**。
- **属性值不溢出**：属性值必须在内存里参与命名空间解析，超限抛
  `entityLimitKind = AttributeValue`。
- **元素深度与属性长度**：`maxElementDepth`（默认 4096）与 `maxAttributeValueLength`
  （默认 1 MiB）防超深嵌套与超长属性。

## 已声明的契约

- `XmlWriter.close()` 之后**不得再调用任何方法**（未定义行为）。
- `indent` 只用于人看：缩进会在元素之间插入空白文本节点，往返解析后多出空白节点。
- 文本事件**可能被拆成多条**（实体边界 / CDATA 边界 / 缓冲边界），消费方自行拼接；
  `DomBuilder` 已经做了合并。
- `parse(text)` 拿到的是字符，不做字节嗅探，也不因声明里的 `encoding` 与内容不符报错。

## 状态

已实现并通过 **376** 条单元测试（其中 `complete-f-xml-m1-followups` 新增 34 条、
`optimize-f-xml-semantic-layer` 新增 39 条）。
xmlconf 20130923 的口径：可跑集 **2062** 条
（`unsupported` **524** = `edition` 313 + 外部实体 95 + XML 1.1 59 + 外部子集 47 +
命名空间名 10），断言 **2038** 条，实测 **2038 通过 / 0 失败**（Gate A 达成）。
五条排除规则是 `edition` / 外部实体 / XML 1.1 / 外部子集 / 命名空间名；配套的三项规范修正
（DTD 声明语法良构校验、`standalone` 与单实体替换文本良构、`<!ATTLIST>` 属性类型映射与
属性值规范化）已落地。`known-issues` 已清空。

性能（事件模式，合成流，`bufSize = 8192`，`-O2`，5 次取 `min`，**默认运行时**）：
**1 MB ≈ 58 ms、10 MB ≈ 497 ms、50 MB ≈ 2.47 s**；`VmHWM(50 MB) = 104 MB`。
同轮同机对照（同一份零分配基准）：旧代码 10 MB **1026 ms**、`VmHWM(50 MB)` **295 MB**，
即 **−51.6%** 与 **−64.7%**。门禁：10 MB `min(5) < 1000 ms`、`VmHWM(50 MB) < 256 MB`
均达成，且**未设置任何 GC 环境变量**。

字符层已改为按块解码 + 单一活动缓冲（详见
[`doc/spec/complete-f-xml-m1-followups/`](doc/spec/complete-f-xml-m1-followups/)）；
语义层（名字驻留、三缓冲复用、文本 / 属性值批量扫描、事件侧容器复用）由
[`doc/spec/optimize-f-xml-semantic-layer/`](doc/spec/optimize-f-xml-semantic-layer/)
落地，公开 API 零变更。

