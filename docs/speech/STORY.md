# STORY.md — fountain 讲稿幻灯片

## ① 用户意图对齐

- **目标受众**：仓颉开发者 / 服务端工程师；具备后端框架（Spring 等）经验，不需要普及 IOC、AOP、ORM 的基本概念。场合为技术分享与录屏讲课（讲师边讲边敲命令）。
- **核心目标**：讲完后，观众要相信三件事 —— ① fountain 把服务端「非业务复杂度」整体收进工具库，业务代码只剩业务；② `fboot` + 动态链接库的插件化启动方式可落地、可操作；③ IOC / AOP / f_data / MVC / ORM / 安全 / 定时 / 日志各自的「最小可用写法」可以直接照抄。行动目标：能照 `fdemo` 从空目录跑出一个可服务的 HTTP 应用。
- **PPT 长度**：116 页（详尽版）。Hero 页配额 20–30% → 24–35 页，实际安排 26 页。
- **视觉调性**：深空克制 · 工程感 · 高对比 · 命令行气质 · 无装饰噪音。
- **内容边界**：
  - 必讲：为什么用 fountain、fboot 命令行、f_config、fdemo 跑通、f_bean、f_aspect、f_data、f_util、f_mvc、f_http、f_orm、f_security+f_jwt、f_ticktock、f_log、串讲、运行时基础设施、常见坑与 Q&A、速查表。
  - 不讲：`f_llm` / `f_egraph` / `fleet` / `f_rpc` / `f_protocol` 等讲稿未展开的模块细节（仅在模块总览页点到名）。
  - 禁碰：编造讲稿中不存在的 API、参数、配置项；不得改变 API 签名与默认值。
- **备注（notes）策略**：讲稿中的【口播】按页归位，改写为第一人称现场讲话，≤ 300 字，分点换段；页面正文只保留结论、表格、代码骨架。

---

## ② 页面布局骨架

**目录 ↔ 章节扉页契约**：目录页（02）声明 **4 个板块**；全篇有且仅有 **4 个 `type: section` 分隔页**，编号连续 01–04，标题与目录逐字一致：

| 目录第 k 章 | 标题 | section 扉页页码 | 覆盖章节 |
| :--- | :--- | :--- | :--- |
| 01 | 总览与启动 | 第 05 页 | 第 0–5 章（p06–p35） |
| 02 | 框架核心 | 第 36 页 | 第 6–11 章（p37–p74） |
| 03 | 数据与安全 | 第 75 页 | 第 12–14 章（p76–p92） |
| 04 | 日志、串讲与底座 | 第 93 页 | 第 15–18 章与附录（p94–p115） |

**Hero 页定位**（26 页，占 22.4%）：01 封面、05/36/75/93 四个分隔页、06 痛点、20 fboot run、48 Data 模型、64 参数绑定、72 自定义格式清单、86 事务与坑、95 三条纪律、98 一条日志的旅程、103 串讲、116 结束页。任意两个 Hero 页之间至少间隔 1 个 Supporting 页。

**rhythm 曲线**：cover（01 peak）→ catalog（02–03 valley）→ 04 valley → transition（05）→ 06 peak → 07–19 交替 valley/peak（每 3 页内必有一个 peak 或 transition）→ 20 peak → 21–35 valley（以 31 的序号流小高潮打断）→ transition（36）→ …… 每块结束处均以 transition 收束。全篇无「连续 ≥ 3 页 supporting + valley」。

**版式预算**：
- 非对称版式占比 **78%**（≥ 40% 要求）。
- 对称版式仅用于 02 目录、03 课程地图（`N卡片横排` 仅 02、111、112 三页中的 02 与 111 计为卡片排布；实际控制 `N卡片横排` 出现 ≤ 2 次）。
- `左大图+右侧文字`（L-A）与 `非对称双栏` 合计 33 页 / 116 = 28%（≤ 40%）。
- 相邻页版式一律不同；同一版式连续出现时插入 `过渡条` 变体。

---

## ③ 页面大纲

> 字段说明：`type` / `role` / `rhythm` / `layout`（见 DESIGN.md §6 版式库）/ `visual` / `visual_role` / `density` / `anti_pattern`。

| # | 页 | type | role | rhythm | layout | visual | visual_role | density | anti_pattern |
| :- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 01 | 封面 | cover | hero | peak | 自定义 | L1: 渐变竖带 + 巨型字 | anchor | 40 字 / 留白 45% | 禁止堆叠 3+ 装饰几何；禁止纯色矩形+单行文字占位 |
| 02 | 目录 · 四大板块 | catalog | supporting | valley | L-B | L3: 页脚徽标 | evidence | 140 字 / 留白 40% | 禁止每项 < 30 字；禁止 4 卡等高却字号相同 |
| 03 | 课程地图 | catalog | supporting | valley | L-C | 表格 | evidence | 420 字 / 留白 26% | 禁止把 18 章塞进 4 卡；禁止无时长列 |
| 04 | 讲稿怎么用 / 录制前准备 | content | supporting | valley | L-E | 上标记表 + 下命令块 | evidence | 300 字 / 留白 32% | 禁止只列清单不给「预期输出」 |
| 05 | Part I 分隔 | section | hero | transition | 自定义 | L1: 56px 大字 + 渐变下划线 | anchor | 40 字 / 留白 50% | 禁止四卡片预览；禁止铺满正文段落 |
| 06 | 1.1 痛点：我们在重复什么 | content | hero | peak | L-D | 巨型「5」+ 五条清单 | anchor | 230 字 / 留白 38% | 禁止等宽卡片横排；禁止把 5 条拆成 5 卡 |
| 07 | 1.2 fountain 是什么 | content | supporting | valley | L-C | 15 行能力表 | evidence | 520 字 / 留白 22% | 禁止 4 卡横排装 15 个模块 |
| 08 | 1.2b 外围模块与引用方式 | content | supporting | valley | L-B | 3 卡 + 代码条 | evidence | 260 字 / 留白 30% | 禁止把 toml 与包名路径写成裸文本 |
| 09 | 1.3 决策一 · 应用没有 main | content | supporting | valley | L-A | 左要点 / 右加载链 | evidence | 240 字 / 留白 32% | 禁止把「没有 main」写成标题党而不给机制 |
| 10 | 1.3 决策二 · 宏为主，注解为辅 | content | supporting | peak | L-A | 左注解-宏对照 / 右编译期时序 | evidence | 300 字 / 留白 30% | 禁止把注解与宏混为一谈 |
| 11 | 1.3 决策三 · 一切都是环境变量 | content | supporting | valley | L-E | 上四级来源 / 下覆盖链 | evidence | 260 字 / 留白 32% | 禁止只画箭头不给优先级 |
| 12 | 1.4 什么时候不该用 fountain | content | supporting | valley | L-H | 2×2 象限 | evidence | 220 字 / 留白 30% | 禁止写成推销页；禁止省略「不适用」 |
| 13 | 2 上台准备：环境 | content | supporting | valley | L-G | 环境变量块 + 验证命令 | evidence | 220 字 / 留白 28% | 禁止把 export 与 cjpm install 混行 |
| 14 | 3.1 fboot help | content | supporting | valley | L-G | 左「第一公理」/ 右命令清单 | evidence | 380 字 / 留白 25% | 禁止把 15 条 help 全文铺满整页无注释 |
| 15 | 3.2 fboot workspace | content | supporting | valley | L-A | 左三用法 / 右 cjpm.toml 改写项 | evidence | 220 字 / 留白 32% | 禁止不说明「它替你写了 60 行」 |
| 16 | 3.3 fboot module | content | supporting | valley | L-A | 左三件事 / 右目录树 | evidence | 240 字 / 留白 30% | 禁止漏掉「必须在 workspace 根执行」 |
| 17 | 3.4 fboot build 与两个隐藏动作 | content | supporting | valley | L-A | 左语法分类 / 右隐藏动作 | evidence | 280 字 / 留白 28% | 禁止把 target-dir 规则一句带过 |
| 18 | 3.4b 编译期注入配置 | content | supporting | peak | L-G | 真实 build 命令块 | anchor | 200 字 / 留白 30% | 禁止把敏感项写成明文示例值 |
| 19 | 3.5 + 3.6 randhex / cleanUpdate | content | supporting | valley | L-B | 3 卡 | evidence | 240 字 / 留白 30% | 禁止把两个命令合成一卡 |
| 20 | 3.7 fboot run 启动流程 | content | hero | peak | L-F | 8 步序号流 | anchor | 200 字 / 留白 35% | 禁止把 8 步压成一段话；禁止漏「不会返回」 |
| 21 | 3.7b --dylibPattern | content | supporting | valley | L-C | 正则片段含义表 | evidence | 300 字 / 留白 26% | 禁止只贴正则不做逐段拆解 |
| 22 | 3.8 其余命令与自定义子命令 | content | supporting | valley | L-C | 命令表 + 注册说明 | evidence | 320 字 / 留白 26% | 禁止把 version 命令写成可随意演示 |
| 23 | 4.1 fountain 没有配置文件 | content | supporting | valley | L-E | 上四来源表 / 下结论 | evidence | 240 字 / 留白 30% | 禁止画「配置文件被划掉」这类无信息装饰 |
| 24 | 4.2 命令行参数的四种写法 | content | supporting | peak | L-C | 4 行写法表 + 规则 | anchor | 220 字 / 留白 28% | 禁止漏「单横线不支持 =」 |
| 25 | 4.2b 同一个写法，两个舞台 | content | supporting | valley | L-A | 左编译期 / 右运行期 | evidence | 260 字 / 留白 30% | 禁止把两边写成同一张表 |
| 26 | 4.3 读取优先级 | content | supporting | valley | L-D | 巨型「4 级」+ 优先序表 | anchor | 200 字 / 留白 34% | 禁止把优先级画成并列而非有序 |
| 27 | 4.4 Config API | content | supporting | valley | L-G | Config API 节选 | evidence | 300 字 / 留白 26% | 禁止把 20 个函数全贴上不做标注 |
| 28 | 4.5 敏感配置与 SM4 | content | supporting | peak | L-A | 左流程 / 右 SM4 配置表 | evidence | 260 字 / 留白 30% | 禁止回避「密钥也在产物里」 |
| 29 | 4.6 @EmbedSensitive | content | supporting | valley | L-G | 左规则 / 右展开结果 | evidence | 240 字 / 留白 28% | 禁止把展开结果写成一句话 |
| 30 | 4.7 + 4.8 时间格式与已知问题 | content | supporting | valley | L-B | 3 卡 | evidence | 220 字 / 留白 30% | 禁止把已知问题藏起来 |
| 31 | 4.9 现场演示 | content | supporting | peak | L-F | 3 步序号流 | anchor | 180 字 / 留白 34% | 禁止只给命令不给预期 |
| 32 | 5.1 fdemo 目录结构 | content | supporting | valley | L-A | 左目录树 / 右分包启示 | evidence | 320 字 / 留白 26% | 禁止漏「分包决定 dylib 粒度」 |
| 33 | 5.2 + 5.3 建表与启动 | content | supporting | valley | L-E | 上 SQL / 下启动命令 | evidence | 240 字 / 留白 30% | 禁止贴表结构却不加主键约束 |
| 34 | 5.4 接口验证清单 1–6 | content | supporting | valley | L-C | 6 行验证表 | evidence | 380 字 / 留白 24% | 禁止省略「预期」列 |
| 35 | 5.4b 接口验证清单 7–12 | content | supporting | peak | L-C | 6 行验证表 + 压测条 | anchor | 360 字 / 留白 24% | 禁止把 401 演示压缩成一行 |
| 36 | Part II 分隔 | section | hero | transition | 自定义 | 56px 大字 + 渐变下划线 | anchor | 40 字 / 留白 50% | 禁止四卡片预览 |
| 37 | 6.1 f_bean 最小可用 | content | supporting | valley | L-G | BeanMeta 注释代码 | evidence | 240 字 / 留白 28% | 禁止把宏展开结果写成散文 |
| 38 | 6.2 lookup 家族 | content | supporting | peak | L-C | 三索引 + 函数表 | anchor | 340 字 / 留白 24% | 禁止漏「可以用名字/类型/注解三种方式取」 |
| 39 | 6.3 生命周期与注入 | content | supporting | valley | L-G | @Constructor/@Value 代码 | evidence | 220 字 / 留白 28% | 禁止漏「只能修饰 @Constructor 形参」 |
| 40 | 6.4 条件装配 | content | supporting | valley | L-A | 左接口 / 右内置实现 | evidence | 240 字 / 留白 30% | 禁止把 & \| ! 组合说成字符串拼接 |
| 41 | 6.5 + 6.6 fdemo 里的 IOC | content | supporting | valley | L-G | lookup 代码 + prototype 说明 | evidence | 220 字 / 留白 30% | 禁止把 @Configuration 说成 bean |
| 42 | 7.1 切面与执行顺序 | content | supporting | peak | L-E | 上 try 流程 / 下顺序条 | anchor | 230 字 / 留白 32% | 禁止不画顺序只贴接口 |
| 43 | 7.2 织入规则 | content | supporting | valley | L-C | 14 行规则表 | evidence | 420 字 / 留白 22% | 禁止只列类名不写匹配依据 |
| 44 | 7.3 + 7.4 织入宏与 ControllerAspect | content | supporting | valley | L-G | 宏列表 + 切面代码 | evidence | 240 字 / 留白 28% | 禁止漏「首次调用才织入」 |
| 45 | 7.5 两个杀手级用法 | content | supporting | valley | L-B | 2 大卡 + 1 说明卡 | evidence | 220 字 / 留白 30% | 禁止把事务与日志写成并列功能清单 |
| 46 | 8.1 + 8.2 @DataAssist | content | supporting | valley | L-E | 三件事 + 属性表 | evidence | 300 字 / 留白 28% | 禁止不说明它是 mvc/orm/jwt 的共同底座 |
| 47 | 8.2b props 展开前后 | content | supporting | peak | L-G | 左写 / 右展开 | anchor | 220 字 / 留白 28% | 禁止漏「顺序约束：@DataAssist 在前」 |
| 48 | 8.3 统一数据模型 Data | content | hero | peak | L-E | 上类型表 + 下转换箭头 | anchor | 280 字 / 留白 32% | 禁止把 Data 画成普通 JSON 对象 |
| 49 | 8.4 实例复制 populate | content | supporting | valley | L-G | 四种复制代码 | evidence | 280 字 / 留白 26% | 禁止漏「只复制同名字段」 |
| 50 | 8.4b DataConversionFlag | content | supporting | valley | L-C | flag 表 | evidence | 340 字 / 留白 24% | 禁止把 SILENCE 说成严格模式 |
| 51 | 8.5 数据校验 | content | supporting | valley | L-A | 左示例 / 右校验器表 | evidence | 380 字 / 留白 24% | 禁止漏「可修饰成员变量/属性/参数」 |
| 52 | 8.6 + 8.7 转换扩展与 JSON Schema | content | supporting | valley | L-B | 3 卡 | evidence | 240 字 / 留白 30% | 禁止把 Schema 注解写进正文示例 |
| 53 | 8.8 JSONPath | content | supporting | peak | L-A | 左语法表 / 右示例 | anchor | 320 字 / 留白 26% | 禁止漏 RFC 9535 与自定义扩展边界 |
| 54 | 8.9 + 8.10 BreakingCommand 与演示 | content | supporting | valley | L-G | 代码 + 输出清单 | evidence | 260 字 / 留白 28% | 禁止把 8 行字母标号删掉 |
| 55 | 9.1 + 9.2 f_util 全景与 UUID | content | supporting | valley | L-A | 左分类表 / 右 UUID 工厂表 | evidence | 340 字 / 留白 24% | 禁止把 UUID 说成 v4 only |
| 56 | 9.3 + 9.4 IsUUID 与 IdMaker | content | supporting | peak | L-E | 上位图 / 下代码 | anchor | 260 字 / 留白 30% | 禁止漏 IdMaker 三个注意点 |
| 57 | 9.5 + 9.6 CaseFormat 与 TextTemplate | content | supporting | valley | L-G | 两段代码 | evidence | 260 字 / 留白 26% | 禁止漏 ThreadLocalStringBuilder 警告 |
| 58 | 9.7 PathPattern | content | supporting | valley | L-A | 左 API / 右优先级表 | evidence | 320 字 / 留白 26% | 禁止把优先级画成并列 |
| 59 | 9.8 TreeTransformer | content | supporting | valley | L-E | 上平铺 / 下树 | evidence | 220 字 / 留白 30% | 禁止漏 emptyId 与 ignoreDuplicate |
| 60 | 9.9 三个设计模式骨架 | content | supporting | valley | L-B | 3 卡 | evidence | 260 字 / 留白 30% | 禁止漏 Responsibility 拼写 |
| 61 | 9.10 + 9.11 其余工具与演示 | content | supporting | valley | L-C | 工具表 + 演示条 | evidence | 300 字 / 留白 26% | 禁止把哈希家族写成长注解 |
| 62 | 10.1 Controller 与 Mapping | content | supporting | valley | L-G | 代码 + Mapping 家族 | evidence | 240 字 / 留白 28% | 禁止漏「只有 *Mapping 修饰的公共实例函数才注册」 |
| 63 | 10.1b params / headers DSL | content | supporting | peak | L-A | 左规则 / 右示例 | anchor | 200 字 / 留白 32% | 禁止把 DSL 写成普通字符串描述 |
| 64 | 10.2 参数绑定注解 | content | hero | peak | L-C | 5 注解表 + 代码条 | anchor | 320 字 / 留白 26% | 禁止漏 @RequestParamObject |
| 65 | 10.3 + 10.4 校验与安全注解 | content | supporting | valley | L-B | 3 卡 | evidence | 240 字 / 留白 30% | 禁止把 @IgnoreSecurity 拆成两卡 |
| 66 | 10.5 MVC 配置项 | content | supporting | valley | L-G | 配置清单块 | evidence | 300 字 / 留白 26% | 禁止漏 mvc_maxRequestBodySize 上传提示 |
| 67 | 10.6 统一异常响应 | content | supporting | valley | L-G | 左说明 / 右 Handler | evidence | 260 字 / 留白 28% | 禁止漏三种 ErrorMessageKind |
| 68 | 10.7 + 10.8 重定向与请求上下文 | content | supporting | valley | L-B | 3 卡 | evidence | 220 字 / 留白 30% | 禁止把 CurrentHttpContext 写成全局变量 |
| 69 | 10.9 自定义 MediaType | content | supporting | peak | L-G | MediaType 实现代码 | anchor | 200 字 / 留白 30% | 禁止漏「加 @Bean 是唯一被发现途径」 |
| 70 | 11.1 + 11.2 f_http 与 MediaType | content | supporting | valley | L-E | 上定位 / 下数据流向 | evidence | 240 字 / 留白 30% | 禁止把 f_mvc.MediaType 说成第二套类型 |
| 71 | 11.3 + 11.4 内置实现与注册表 | content | supporting | valley | L-A | 左类图 / 右注册来源 | evidence | 240 字 / 留白 30% | 禁止漏 multipart 不支持 fromData(Data) |
| 72 | 11.5 自定义格式完整清单 | content | hero | peak | L-F | 6 步序号流 | anchor | 240 字 / 留白 32% | 禁止把 6 步写成一段话 |
| 73 | 11.6 文件上传 | content | supporting | valley | L-G | 接收/发送代码 | evidence | 260 字 / 留白 26% | 禁止漏「MultipartFile 是 Resource，必须 close」 |
| 74 | 11.7 异常与排错 | content | supporting | valley | L-C | 异常表 + 排错条 | evidence | 220 字 / 留白 28% | 禁止把 99% 的根因写成「框架 bug」 |
| 75 | Part III 分隔 | section | hero | transition | 自定义 | 56px 大字 + 渐变下划线 | anchor | 40 字 / 留白 50% | 禁止四卡片预览 |
| 76 | 12.1 PO | content | supporting | valley | L-G | PO 代码 + 生成物表 | evidence | 320 字 / 留白 24% | 禁止漏 @ORMField 只能修饰 public var / mut prop |
| 77 | 12.1b DAO | content | supporting | peak | L-G | DAO 接口 + 约束 | anchor | 280 字 / 留白 26% | 禁止把 DAO 写成「接口 + 实现类」 |
| 78 | 12.1c Service | content | supporting | valley | L-E | 上代码 / 下两条铁律 | evidence | 240 字 / 留白 30% | 禁止漏「每次调用 DAO 都必须从 executor() 开始」 |
| 79 | 12.2 ORM 配置 | content | supporting | valley | L-G | 配置清单块 | evidence | 300 字 / 留白 26% | 禁止漏「按驱动覆盖优先级更高」 |
| 80 | 12.3 构 SQL 方式一 / 二 | content | supporting | valley | L-G | 模板 SQL + DSL 代码 | evidence | 260 字 / 留白 26% | 禁止把 arg() 说成字符串拼接 |
| 81 | 12.3b 条件构造器 | content | supporting | peak | L-G | meet/choose/WHERE/SET | anchor | 240 字 / 留白 28% | 禁止漏「内容为空自动省略关键字」 |
| 82 | 12.4 查询结果与分页 | content | supporting | valley | L-E | 上结果 API / 下分页字段 | evidence | 240 字 / 留白 30% | 禁止漏「limit/offset 由方言生成」 |
| 83 | 12.5 事务三种开启 | content | supporting | peak | L-F | 3 路序号流 | anchor | 240 字 / 留白 32% | 禁止把注解与配置写成互斥 |
| 84 | 12.5b 传播行为 | content | supporting | valley | L-C | 7 种传播表 | evidence | 260 字 / 留白 26% | 禁止把 Required 之外的写成可选装饰 |
| 85 | 12.5c 事务钩子 | content | supporting | valley | L-C | 钩子顺序表 | evidence | 340 字 / 留白 24% | 禁止只列钩子名不给顺序 |
| 86 | 12.5d 线程连接 + 12.6 常见坑 | content | hero | peak | L-A | 左原理 / 右 8 条坑 | anchor | 320 字 / 留白 26% | 禁止把 8 条坑压缩成 3 条 |
| 87 | 13.1 登录状态检查 | content | supporting | valley | L-G | AuthCheckerImpl 代码 | evidence | 240 字 / 留白 28% | 禁止漏 AuthStatus 六个枚举值 |
| 88 | 13.1b AuthHandler 挑选顺序 | content | supporting | peak | L-F | 5 步判断流 | anchor | 220 字 / 留白 32% | 禁止漏「第 3 步通过后第 4 步不执行」 |
| 89 | 13.2 用 JWT 维持登录状态 | content | supporting | valley | L-G | UserSessionCache 代码 | evidence | 260 字 / 留白 26% | 禁止漏「每个会话一把 HMAC 密钥」 |
| 90 | 13.3 f_jwt API | content | supporting | valley | L-A | 左编码 / 右解码 | evidence | 340 字 / 留白 24% | 禁止只列 encode 不列 verify |
| 91 | 13.4 端到端演示 | content | supporting | peak | L-F | 4 步 + 调用链 | anchor | 220 字 / 留白 32% | 禁止漏 401 与 200 的对照 |
| 92 | 14 f_ticktock 定时任务 | content | supporting | valley | L-E | 上代码 / 下 cron 语法 | evidence | 260 字 / 留白 30% | 禁止漏「静默失效」坑 |
| 93 | Part IV 分隔 | section | hero | transition | 自定义 | 56px 大字 + 渐变下划线 | anchor | 40 字 / 留白 50% | 禁止四卡片预览 |
| 94 | 15.1 为什么还要写一个日志模块 | content | supporting | peak | L-B | 3 理由卡 | anchor | 260 字 / 留白 30% | 禁止把 f_log 说成 stdx.log 的替代品 |
| 95 | 15.2 三条纪律 | content | hero | peak | L-F | 3 条纪律流 | anchor | 240 字 / 留白 32% | 禁止把三条纪律写成并列卡片 |
| 96 | 15.3 配置项全表 | content | supporting | valley | L-C | 16 行配置表 | evidence | 520 字 / 留白 20% | 禁止省略默认值列 |
| 97 | 15.4 三种写法与占位符 | content | supporting | valley | L-A | 左写法 / 右占位符表 | evidence | 380 字 / 留白 24% | 禁止漏「级别判断在后台线程」 |
| 98 | 15.5 一条日志的旅程 | content | hero | peak | L-E | 三级流水线图 | anchor | 300 字 / 留白 32% | 禁止把三级异步画成一条直线 |
| 99 | 15.6 切割与压缩 | content | supporting | valley | L-A | 左流程 / 右注意项 | evidence | 280 字 / 留白 28% | 禁止漏「压缩失败也会删原文件」 |
| 100 | 15.7 现场演示 | content | supporting | peak | L-G | 命令 + 日志样例 | anchor | 280 字 / 留白 26% | 禁止把框架日志样例删成一行 |
| 101 | 15.8 + 15.9 refresh 与八个坑 | content | supporting | valley | L-C | 生效表 + 坑表 | evidence | 460 字 / 留白 22% | 禁止把「只能重启」的配置写成可热更 |
| 102 | 15.10 速查卡 | content | supporting | valley | L-G | 代码 + 配置双块 | evidence | 400 字 / 留白 22% | 禁止只给代码不给配置 |
| 103 | 16 串讲 · 一次请求穿过整个框架 | content | hero | peak | L-F | 6 段调用链 | anchor | 420 字 / 留白 28% | 禁止把 6 段压成一段；禁止漏底座那一段 |
| 104 | 17.1 九个运行时模块 | content | supporting | valley | L-C | 9 行模块表 | evidence | 400 字 / 留白 24% | 禁止漏「被谁用了」列 |
| 105 | 17.2 + 17.3 f_base 与 f_io | content | supporting | valley | L-A | 左 f_base / 右 f_io | evidence | 360 字 / 留白 24% | 禁止漏 ExitCallbacks 权重顺序 |
| 106 | 17.4 + 17.5 f_cache 与 f_pool | content | supporting | peak | L-A | 左缓存 / 右池 | anchor | 320 字 / 留白 26% | 禁止漏「非一次性＝滑动续期」 |
| 107 | 17.6 + 17.7 f_collection 与 f_time | content | supporting | valley | L-A | 左集合 / 右时间 DSL | evidence | 320 字 / 留白 26% | 禁止漏 Dict 的 hasher/equals 注入 |
| 108 | 17.8–17.10 f_regex / f_rx / f_random | content | supporting | valley | L-B | 3 卡 | evidence | 340 字 / 留白 28% | 禁止漏 f_random 的已知行为 |
| 109 | 18.1 高频坑 1–11 | content | supporting | valley | L-C | 11 行表 | evidence | 520 字 / 留白 20% | 禁止只写现象不写解法 |
| 110 | 18.1 高频坑 12–22 | content | supporting | valley | L-C | 11 行表 | evidence | 520 字 / 留白 20% | 禁止只写现象不写解法 |
| 111 | 18.2 Q&A 一 | content | supporting | valley | L-B | 3 卡问答 | evidence | 300 字 / 留白 28% | 禁止用「视情况而定」收尾 |
| 112 | 18.2 Q&A 二 | content | supporting | valley | L-B | 3 卡问答 | evidence | 300 字 / 留白 28% | 禁止答非所问式复述问题 |
| 113 | 附录 · 命令速查 | content | supporting | valley | L-G | 命令代码块 | evidence | 320 字 / 留白 24% | 禁止省略参数占位符 |
| 114 | 附录 · 配置速查 | content | supporting | peak | L-G | 配置代码块 | anchor | 420 字 / 留白 22% | 禁止把优先级规则删掉 |
| 115 | 附录 · 关键 API 速查 | content | supporting | valley | L-A | 左 f_bean/f_orm / 右 f_data/f_log | evidence | 420 字 / 留白 22% | 禁止只贴签名不分组 |
| 116 | 结束页 | ending | hero | peak | 自定义 | L1: 收束金句 + 渐变带 | anchor | 50 字 / 留白 50% | 禁止致谢式空页；禁止堆二维码与联系方式 |
