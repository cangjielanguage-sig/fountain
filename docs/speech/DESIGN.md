# DESIGN.md — fountain 讲稿幻灯片

## 0. 项目定位

- 主题：fountain（仓颉生态一站式服务器应用开发工具库）全链路讲稿
- 场景：技术分享 / 录屏讲课（低-中密度、单页一个知识点）
- 受众：仓颉开发者、服务端工程师（具备后端框架经验，不需要解释 Spring 是什么）
- 忠实度：文本与代码严格取自 `docs/speech.md`，不新增未在讲稿出现的能力描述
- 硬约束：幻灯片正文「简明扼要」，讲稿的【口播】原文按页写入演讲者备注（notes）

## 1. 画布与母版（A / B / C 三区）

| 母版区 | 垂直位置 | 高度 | 内容规则 |
| :--- | :--- | :--- | :--- |
| **A · 标题块** | 0–120px | 120px（含上 padding 20px） | 主标题 34px bold；左侧 4px 主色竖条（x=64，y=44，w=4，h=38）；右上可放章节号 13px |
| **B · 内容区** | 120–660px | 540px 可用 | 正文、卡片组、表格、流程图、代码块 |
| **C · 页脚条** | 660–720px | 60px（含下 padding 20px） | 左：`fountain · 一站式服务器应用开发工具库`（13px 弱色）；右：`NN / 116`（13px 弱色）；页脚上方 1px 分隔线 |
| 页面 padding | 上下 20px、左右 64px | — | 内容可用宽 1152px |

封面 / Chapter 分隔页 / 结束页使用自定义版式，省略 A 区。

## 2. 颜色系统

### 2.1 色彩池（4 hex）

| 角色 | hex | 用途 |
| :--- | :--- | :--- |
| 背景（主色） | `#0B1220` | 全篇页面底色 |
| 主色 | `#38BDF8` | 竖条、标题强调、结构图主线、表头 |
| 辅色 | `#22D3EE` | 次级结构、渐变终点、第二系列 |
| 强调色 | `#F59E0B` | 巨型数字、关键警示、命令提示符 |

### 2.2 中性色（画布基础，不计入色彩池）

| 角色 | hex | 用途 |
| :--- | :--- | :--- |
| 卡片面 | `#111C2E` | 卡片/容器背景（纯色） |
| 卡片面叠加 | `#16233A` | 嵌套卡片、表头底 |
| 边框 | `#1E293B` | 卡片描边、表格网格 |
| 文本主色 | `#E2E8F0` | 标题、正文 |
| 文本次色 | `#94A3B8` | 说明、表头文字、注释 |
| 文本弱色 | `#64748B` | 页脚、编号、单位 |

### 2.3 色彩面积分配（全篇统一后微调）

| 色彩角色 | 常规页 | Hero 页 | 说明 |
| :--- | :--- | :--- | :--- |
| 背景 `#0B1220` | ≥ 55% | ≥ 50% | 画布底色 |
| 中性卡片面 | ≤ 30% | ≤ 25% | 分区容器 |
| 主色 `#38BDF8` | ≤ 12% | ≤ 18% | 仅出现在焦点元素：竖条、锚点数字、结构线 |
| 辅色 `#22D3EE` | ≤ 8% | ≤ 10% | 第二层级 |
| 强调色 `#F59E0B` | ≤ 5% | ≤ 8% | 一页最多 1 处（关键结论 / 巨型数字 / 命令） |

规则：强调色只出现在焦点元素上；同一页面不得出现第二套主色板。

### 2.4 渐变与半透明

- 渐变唯一方案：`linear-gradient(135deg, #38BDF8 0%, #22D3EE 100%)`。仅用于 Chapter 分隔页大字下划线、卡片顶部 3px 条、封面右侧色带。
- 半透明方案：卡片底 `rgba(56,189,248,0.06)`；结构图底衬 `rgba(34,211,238,0.05)`；背景装饰大圆 `opacity: 0.06`。
- 阴影：全篇不使用 boxShadow（深底上无意义）。

## 3. 字体系统

字体家族（2 套）：

- 正文/标题：`"Source Han Sans SC", "Microsoft YaHei", "PingFang SC", sans-serif`
- 代码/命令/数字：`"JetBrains Mono", "Cascadia Mono", Consolas, monospace`

字号阶梯：

| 层级 | 字号 | 字重 | 行高 | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| 封面主标 | 68 | bold | 1.15 | 仅封面 |
| Chapter 大字 | 56 | bold | 1.1 | 分隔页 |
| 巨型锚点 / 数字 | 64–88 | bold | 1.0 | 每页至少 1 个视觉锚点 |
| 页面主标题（A 区） | 34 | bold | 1.3 | 每页固定 |
| 卡片小标题 | 22 | bold | 1.4 | 卡片头 |
| 正文 | 17 | regular | 1.6 | 段落、列表 |
| 小字 / 注释 | 14 | regular | 1.5 | 补充说明 |
| 代码 / 命令 | 15 | regular | 1.7 | 等宽 |
| 页脚 | 13 | regular | 1.4 | C 区 |

规则：巨型数字使用等宽字体 + 主色或强调色；标题与正文同族但字号/字重拉开 ≥ 2 级。

## 4. 信息密度门禁

| 页面类型 | 正文下限 | 主视觉占 B 区 | 留白上限 |
| :--- | :--- | :--- | :--- |
| 封面 | 20 字 | ≥ 35% | 45% |
| 目录 | 80 字合计 | — | 40% |
| 内容页（单主题/卡片组） | 180 字 | ≥ 30% | 35% |
| 表格页 | 表格本身即主视觉 | ≥ 50% | 30% |
| Chapter 分隔页 | 30 字 | ≥ 40% | 50% |
| 结束页 | 20 字 | — | 50% |

容器填充率 ≥ 85%；卡片尾部元素用 `marginTop: 'auto'` 钉底。

## 5. 配图系统

**全篇不使用摄影 / 插画 / 3D 生图**（技术讲稿，实景配图与内容无关，会稀释信息密度）。L1 主视觉统一由「结构图 / 流程图 / 调用链 / 大表格 / 巨型代码块 / 巨型数字」承担，全部用 `Box` + `SVG` 绘制 —— 属于设计原则允许的「流程图、架构图、矩阵、关系网络、图表底图、巨型数字」范畴。

| 等级 | 形态 | 最小尺寸 |
| :--- | :--- | :--- |
| L1 主视觉 | 调用链图 / 结构图 / 全宽表格 | 占 B 区 ≥ 30%，常见 1152×320 |
| L2 支撑图 | 卡片内小结构图 / 序号环 | ≥ 280×180 |
| L3 母版徽标 | 页脚左侧 24×24 菱形（四个小三角组成的「喷泉」标记），全篇位置固定 | 24×24 |

L3 徽标位置：C 区左侧 x=64 起，24×24，紧邻项目名文字。

## 6. 版式库（8 种，按页轮换，禁止连续 2 页同版式）

| 代号 | 名称 | 结构 |
| :--- | :--- | :--- |
| L-A | 左文右图 | 左 45% 要点列 + 右 55% 结构图 |
| L-B | 三卡横排 | 顶部一句引导 + 3 张等高卡 |
| L-C | 全宽表格 | A 区标题 + B 区通栏表格 |
| L-D | 巨型锚点 | 左侧 88px 巨型数字/符号 + 右侧说明 |
| L-E | 上下双带 | 上 60% 结构图 + 下 40% 要点条 |
| L-F | 左序号流 | 左侧竖向编号流（1→N）贯穿 B 区 |
| L-G | 代码主视觉 | 左侧 40% 说明 + 右侧 60% 等宽代码块 |
| L-H | 四象限 | 2×2 等分卡片 |

## 7. 页面映射表

> 全篇 116 页。类型：cover/part/catalog/content/closing。角色：hero/supporting/transition。
> L1 一律为自绘结构图或表格（见 §5），表中「版式」列即 §6 代号。

| # | 页 | 类型 | 角色 | 版式 | 关键约束 |
| :- | :--- | :--- | :--- | :--- | :--- |
| 01 | 封面 | cover | hero | 自定义 | 68px 主标 + 渐变竖带 + 三行副信息 |
| 02 | 目录 · 四大板块 | catalog | supporting | L-B | 4 卡，每卡 ≥ 30 字 |
| 03 | 课程地图 | catalog | supporting | L-C | 18 章表 + 时长建议 |
| 04 | 讲稿怎么用 / 录制前准备 | content | supporting | L-E | 上标记说明表 + 下命令块 |
| 05 | Part I 分隔 | part | transition | 自定义 | 大字 56px + 渐变下划线 |
| 06 | 1.1 痛点 | content | hero | L-D | 巨型「5」锚点 |
| 07 | 1.2 fountain 是什么 | content | supporting | L-C | 核心能力表 15 行 |
| 08 | 1.2b 外围模块与引用 | content | supporting | L-B | 3 卡 + 引用代码 |
| 09 | 1.3 决策一 没有 main | content | supporting | L-A | 左要点右加载链图 |
| 10 | 1.3 决策二 宏为主 | content | supporting | L-A | 左注解/宏对照右编译期时序 |
| 11 | 1.3 决策三 配置即环境变量 | content | supporting | L-E | 上四级来源带 + 下覆盖链 |
| 12 | 1.4 什么时候不该用 | content | supporting | L-H | 4 象限：语言/类型/依赖/约定 |
| 13 | 2 上台准备 | content | supporting | L-G | 左环境变量清单右验证命令 |
| 14 | 3.1 fboot help | content | supporting | L-G | 左说明右命令清单 |
| 15 | 3.2 workspace | content | supporting | L-A | 左三用法右 cjpm.toml 改写项 |
| 16 | 3.3 module | content | supporting | L-A | 左三件事右目录树 |
| 17 | 3.4 fboot build | content | supporting | L-A | 左语法分类右两个隐藏动作 |
| 18 | 3.4b 编译期注入配置 | content | supporting | L-G | 左说明右真实 build 命令 |
| 19 | 3.5+3.6 randhex / cleanUpdate | content | supporting | L-B | 3 卡 |
| 20 | 3.7 fboot run 启动流程 | content | hero | L-F | 8 步序号流 |
| 21 | 3.7b --dylibPattern | content | supporting | L-C | 正则片段含义表 |
| 22 | 3.8 其余命令 + 自定义子命令 | content | supporting | L-C | 命令表 + 一行说明 |
| 23 | 4.1 没有配置文件 | content | supporting | L-E | 上四级来源表 + 下结论条 |
| 24 | 4.2 命令行参数四种写法 | content | supporting | L-C | 写法表 + 规则条 |
| 25 | 4.2b 两个舞台 | content | supporting | L-A | 左编译期右运行期对照 |
| 26 | 4.3 读取优先级 | content | supporting | L-D | 巨型「4 级」+ 优先级表 |
| 27 | 4.4 Config API | content | supporting | L-G | Config API 节选代码 |
| 28 | 4.5 敏感配置与 SM4 | content | supporting | L-A | 左流程右 SM4 配置表 |
| 29 | 4.6 @EmbedSensitive | content | supporting | L-G | 左规则右展开结果 |
| 30 | 4.7+4.8 时间格式 + 已知问题 | content | supporting | L-B | 3 卡 |
| 31 | 4.9 现场演示 | content | supporting | L-F | 三步序号流 |
| 32 | 5.1 fdemo 目录结构 | content | supporting | L-A | 左目录树右分包启示 |
| 33 | 5.2+5.3 建表与启动 | content | supporting | L-E | 上 SQL 下启动命令 |
| 34 | 5.4 接口清单 1–6 | content | supporting | L-C | 6 行验证表 |
| 35 | 5.4b 接口清单 7–12 + 压测 | content | supporting | L-C | 6 行验证表 + 压测条 |
| 36 | Part II 分隔 | part | transition | 自定义 | 大字 + 章节范围 |
| 37 | 6.1 f_bean 最小可用 | content | supporting | L-G | BeanMeta 注释代码 |
| 38 | 6.2 lookup 家族 | content | supporting | L-C | 三索引 + 函数表 |
| 39 | 6.3 生命周期与注入 | content | supporting | L-G | @Value/@BeanParam 代码 |
| 40 | 6.4 条件装配 | content | supporting | L-A | 左接口右内置实现 |
| 41 | 6.5+6.6 fdemo 里的 IOC | content | supporting | L-G | lookup 代码 + prototype 说明 |
| 42 | 7.1 切面与执行顺序 | content | supporting | L-E | 上 try 流程 + 下顺序条 |
| 43 | 7.2 织入规则 | content | supporting | L-C | 规则表 14 行 |
| 44 | 7.3+7.4 织入宏与 ControllerAspect | content | supporting | L-G | 宏列表 + 切面代码 |
| 45 | 7.5 两个杀手级用法 | content | supporting | L-B | 2 大卡 + 1 说明卡 |
| 46 | 8.1+8.2 @DataAssist | content | supporting | L-E | 三件事 + 属性表 |
| 47 | 8.2b props 展开 | content | supporting | L-G | 左写右展开对照 |
| 48 | 8.3 Data 统一模型 | content | supporting | L-E | 上类型表 + 下转换箭头 |
| 49 | 8.4 populate 实例复制 | content | supporting | L-G | 四种复制代码 |
| 50 | 8.4b DataConversionFlag | content | supporting | L-C | flag 表 |
| 51 | 8.5 数据校验 | content | supporting | L-A | 左示例右校验器表 |
| 52 | 8.6+8.7 转换扩展与 JSON Schema | content | supporting | L-B | 3 卡 |
| 53 | 8.8 JSONPath | content | supporting | L-A | 左语法表右示例 |
| 54 | 8.9+8.10 BreakingCommand + 演示 | content | supporting | L-G | 代码 + 输出清单 |
| 55 | 9.1+9.2 f_util 全景与 UUID | content | supporting | L-A | 左分类表右 UUID 工厂表 |
| 56 | 9.3+9.4 IsUUID 与 IdMaker | content | supporting | L-E | 上位图下代码 |
| 57 | 9.5+9.6 CaseFormat 与 TextTemplate | content | supporting | L-G | 两段代码 |
| 58 | 9.7 PathPattern | content | supporting | L-A | 左 API 右优先级表 |
| 59 | 9.8 TreeTransformer | content | supporting | L-E | 上平铺下树 |
| 60 | 9.9 三个设计模式骨架 | content | supporting | L-B | 3 卡 |
| 61 | 9.10+9.11 其余工具与演示 | content | supporting | L-C | 工具表 + 演示条 |
| 62 | 10.1 Controller + Mapping | content | supporting | L-G | 代码 + Mapping 家族 |
| 63 | 10.1b params/headers DSL | content | supporting | L-A | 左 DSL 规则右示例 |
| 64 | 10.2 参数绑定注解 | content | supporting | L-C | 5 注解表 + 代码条 |
| 65 | 10.3+10.4 校验与安全注解 | content | supporting | L-B | 3 卡 |
| 66 | 10.5 MVC 配置 | content | supporting | L-G | 配置清单代码块 |
| 67 | 10.6 统一异常响应 | content | supporting | L-G | 左说明右 Handler 代码 |
| 68 | 10.7+10.8 重定向与上下文 | content | supporting | L-B | 3 卡 |
| 69 | 10.9 自定义 MediaType | content | supporting | L-G | MediaType 实现代码 |
| 70 | 11.1+11.2 f_http 与 MediaType | content | supporting | L-E | 上定位下数据流向 |
| 71 | 11.3+11.4 内置实现与注册表 | content | supporting | L-A | 左类图右注册来源 |
| 72 | 11.5 自定义格式完整清单 | content | supporting | L-F | 6 步序号流 |
| 73 | 11.6 文件上传 | content | supporting | L-G | 接收/发送代码 |
| 74 | 11.7 异常排错 | content | supporting | L-C | 异常表 + 排错条 |
| 75 | Part III 分隔 | part | transition | 自定义 | 大字 + 章节范围 |
| 76 | 12.1 PO | content | supporting | L-G | PO 代码 + 生成物表 |
| 77 | 12.1b DAO | content | supporting | L-G | DAO 接口 + 约束 |
| 78 | 12.1c Service | content | supporting | L-E | 上代码下两条铁律 |
| 79 | 12.2 ORM 配置 | content | supporting | L-G | 配置清单 |
| 80 | 12.3 构 SQL 方式一/二 | content | supporting | L-G | 模板 SQL + DSL 代码 |
| 81 | 12.3b 条件构造器 | content | supporting | L-G | meet/choose/WHERE/SET |
| 82 | 12.4 查询结果与分页 | content | supporting | L-E | 上结果 API 下分页字段 |
| 83 | 12.5 事务三种开启 | content | supporting | L-F | 3 路序号流 |
| 84 | 12.5b 传播行为 | content | supporting | L-C | 7 种传播表 |
| 85 | 12.5c 事务钩子 | content | supporting | L-C | 钩子顺序表 |
| 86 | 12.5d 线程连接 + 12.6 常见坑 | content | supporting | L-A | 左原理右坑清单 |
| 87 | 13.1 登录状态检查 | content | supporting | L-G | AuthCheckerImpl 代码 |
| 88 | 13.1b AuthHandler 挑选顺序 | content | supporting | L-F | 5 步判断流 |
| 89 | 13.2 JWT 会话 | content | supporting | L-G | UserSessionCache 代码 |
| 90 | 13.3 f_jwt API | content | supporting | L-A | 左编码右解码 |
| 91 | 13.4 端到端演示 | content | supporting | L-F | 4 步 + 调用链 |
| 92 | 14 f_ticktock | content | supporting | L-E | 上代码下 cron 语法 |
| 93 | Part IV 分隔 | part | transition | 自定义 | 大字 + 章节范围 |
| 94 | 15.1 为什么自己写日志 | content | supporting | L-B | 3 理由卡 |
| 95 | 15.2 三条纪律 | content | supporting | L-F | 3 条纪律流 |
| 96 | 15.3 配置项全表 | content | supporting | L-C | 配置表 16 行 |
| 97 | 15.4 三种写法与占位符 | content | supporting | L-A | 左写法右占位符表 |
| 98 | 15.5 一条日志的旅程 | content | hero | L-E | 三级流水线图 |
| 99 | 15.6 切割与压缩 | content | supporting | L-A | 左流程右注意项 |
| 100 | 15.7 现场演示 | content | supporting | L-G | 命令 + 日志样例 |
| 101 | 15.8+15.9 refresh 与八个坑 | content | supporting | L-C | 生效表 + 坑表 |
| 102 | 15.10 速查卡 | content | supporting | L-G | 代码 + 配置双块 |
| 103 | 16 串讲 | content | hero | L-F | 6 段调用链 |
| 104 | 17.1 九模块总览 | content | supporting | L-C | 9 行模块表 |
| 105 | 17.2+17.3 f_base 与 f_io | content | supporting | L-A | 左 f_base 右 f_io |
| 106 | 17.4+17.5 f_cache 与 f_pool | content | supporting | L-A | 左缓存右池 |
| 107 | 17.6+17.7 f_collection 与 f_time | content | supporting | L-A | 左集合右时间 DSL |
| 108 | 17.8–17.10 f_regex / f_rx / f_random | content | supporting | L-B | 3 卡 |
| 109 | 18.1 高频坑 1–11 | content | supporting | L-C | 11 行表 |
| 110 | 18.1 高频坑 12–22 | content | supporting | L-C | 11 行表 |
| 111 | 18.2 Q&A 一 | content | supporting | L-B | 3 卡问答 |
| 112 | 18.2 Q&A 二 | content | supporting | L-B | 3 卡问答 |
| 113 | 附录 · 命令速查 | content | supporting | L-G | 命令代码块 |
| 114 | 附录 · 配置速查 | content | supporting | L-G | 配置代码块 |
| 115 | 附录 · 关键 API 速查 | content | supporting | L-A | 左 f_bean/f_orm 右 f_data/f_log |
| 116 | 结束页 | closing | hero | 自定义 | 收束金句 + 落款 |

## 8. 自检清单（每页提交前逐项确认）

1. A/B/C 三区齐全，标题位置全篇一致
2. A 区右侧无装饰小图
3. B 区有 ≥ 1 个视觉锚点（≥ 44px 元素，或 ≥ 30% B 区的结构图/表格）
4. 仅使用 §2 声明的 4 色 + 6 中性色；强调色 ≤ 1 处
5. 与上一页版式不同；留白 ≤ 35%（hero 页 ≤ 50%）
6. 页脚含 `NN / 116`
7. notes 为第一人称口播，≥ 150 字，无「这一页/本页/接下来」等元描述
8. 总高 ≤ 720px（上 20 + A 区 100 + B 区 540 + C 区 40 + 下 20）
