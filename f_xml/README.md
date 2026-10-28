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
| M1 | 推 / 拉 / 单回调三种解析前端、DOM、生成器、DTD 内部实体与溢出策略、安全上限 |
| M2 | XPath 1.0 子集（含命名空间前缀） |
| M3 | XML 1.1、C14N（inclusive 1.0/1.1 + exclusive 1.0） |

## 状态

模块骨架已建立，实现按 OpenSpec 变更推进，规格与实施记录见 `doc/spec/`。
