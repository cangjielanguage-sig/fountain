# f_jit 详细设计 · M3 增量（verMajor 3：Any 通道 · JSON 字面量 · CALL_HOST 转发特化）

> 依据：`jit-bytecode-m3.md` v0.3.16（同目录）。本文只写 **M3 的增量与受影响面**；未提及的包、声明、成员一律沿用 `design-m1.md` / `design-m2.md`。
> 版本口径：`.fbc` **verMajor 3**（verMinor 0）；M1/M2 产物按各自规则集运行，语义**完全不变**。
> 三个专项：① **Any 通道**（§0–§10）；② **JSON 字面量**（§11，含世界内可变 API）；③ **CALL_HOST 转发特化**（§13，纯加速、语义零变更）。
> 附录（文末）：**M3 增量三表**（附 A 语法 → 字节码 · 附 B 指令定义增量 · 附 C 字节码 ↔ 机器码增量）；M1 全量三表见 `design-m1.md` 附录。

---

## §0 M3 定位与增量总览

**需求**：世界内**异构数据**——`List<Any>`、`Map<String, Any>`、`Map<Int64, Any>`：容器与局部可持「类型开放」的值，用 `is` / `as` 做类型问答与取出（HostObject 要求内容按类型化类声明封闭，覆盖不了开放内容）。

**三个支点**：

| 专项 | 支点 | 增量 |
|---|---|---|
| Any | **Any = 装箱搬运类型**：句柄条目直存原生 Cangjie `Any`；唯一算子 = `is` / `as`（延用仓颉 Any 语义本体；无动态调用/计算/等值；**唯一例外：`as` 按本方言强制转型处理——命中 → T、未命中 → 22，见 m3 §3 / §12-10**） | LocalType 15 / token 12；H66–H68；错误码 22 |
| JSON | **字面量本体零世界内新机制**：kind 11（原始 JSON 字节）+ HostObject 通道（14）+ 预定义函数通道的组合；**世界内可变 API**（H73–H75）为 M3 内追加 | kind 11；词法两形态；H73/H74/H75；frozen 传播 |
| 特化 | **分层特化**：签名级（身份无关）+ 条目级 per-call；**纯加速**（不改语义/格式/错误面） | `SignatureTable`/`SignaturePlan`（桥内部运行时物） |

**新增概念一览**：

| 概念 | 既有对应 | 增量 |
|---|---|---|
| Any 类型 | 边界 `Any`（仅桥 Marshal） | 世界内 LocalType 15 / token 12 |
| 装箱 | 无（世界内类型静态封闭） | H66 `any_box`（分配型） |
| 类型问答 | M2 验签（边界一次性核对） | H67 `any_is` / H68 `any_as`（运行期、可反复） |
| 错误码 22 | 7 = 值转型（静态） | 22 = **动态转型失败**（`as` 未命中；site = `any_as` 调用点） |
| JSON 常量 | kind 3 String | **kind 11 = Json**（原始字节；加载期一次解析） |
| JSON 世界内可变 | 非空字面值 = 常量（只读） | 空形态构造（H75）+ `[]` 读写（H73/H74）+ **frozen 标记与传播** |
| 转发特化 | H63 通用流程（逐参描述符遍历） | `SignatureTable`（签名级）+ 条目 `plan` 绑定（零签名查找） |

---

## §1 包与声明增量总览

| 包 | 新增声明 | 受影响的既有声明 | 不变面 |
|---|---|---|---|
| `base` | — | `LocalType`（+15）、`TypeToken`（+12）、`ErrCode`（+22 与描述） | 其余全部 |
| `bytecode` | — | `ConstKind`（+11）、`ConstPayload`（+`PJson`）、`ConstRegistry`（+`addJson`）、`FbcReader`（kind 11 解析/校验 + verMajor 3 规则集） | 容器头、段模型（kind 11 载荷 = u32 长度 + UTF-8 字节，与 kind 3 同构） |
| `compiler` | — | `AstExpr`（+ JSON 字面/下标读写/`is`/`as`/`any_box` 形态）、`Lowerer`（装箱插入点/拆箱问答/JSON 发射）、`Lexer`（反引号 JSON 段保护）、`TypeRef`（`AnyT`） | 其余降低模式 |
| `runtime` | `SignatureTable`、`SignaturePlan` | `HandleTable`（条目 +`frozen` 标记）、H66/H67/H68/H73/H74/H75（顶层 @C func）、`HostCallback`（+`plan`）、`IterTable`（不变） | ctx、迭代器、既有 helper |
| 根包 | — | `CallMarshal`（+Any 参数/返回行）、`CompilePipeline`（特化表接入）、`JitFunction`（无新公共成员） | 六步/卸载/去重 |

---

## §2 `base` 增量

| 声明 | 新增成员 | 值/意义 | 锚点 |
|---|---|---|---|
| `LocalType` | `static const ANY = 15` | 装箱搬运类型（句柄型；恒非空） | m3 §1 |
| `TypeToken` | `static const ANY = 12` | 句柄槽 tag 与 `is`/`as` 编码 | m3 §1 |
| `ErrCode` | `static const ANY_CAST = 22` | `as` 动态转型失败（盒内容与目标类型不符；site=`any_as` 调用点）；与 7 分列 | m3 §2、§12-6 |
| `ErrCode describe` | 映射范围扩至 1–22、23 | 21/22 行入桥静态表 | m3 §12-6 |

**可转集（冻结，实施依据）**：LocalType `0–8、9–11` + `14`（v0.3.12：`Any ⇄ 14` 双方向开放；类界按仓颉继承语义）；其中 `3=Unit` 前端不发射装箱点；`12=Closure` 不开放转型（且**闭包禁止存入集合——含经 Any 盒的间接路径**）；`13=HostClosure` 二期候选（约束已定：转型目标必须为明确函数类型）；`15` 不在可转集（**盒不套盒**，最终形态）。

---

## §3 `bytecode` 增量

| 声明 | 新增/变更成员 | 意义 | 锚点 |
|---|---|---|---|
| `ConstKind` | `static const JSON = 11` | 常量 kind 11（**M3 版本内追加**；m2「kind 11 不新增」的表述仅限 HostClosure） | m3 §11 |
| `ConstPayload` | `+ PJson(raw: String)` | payload = 规范化后的原始 JSON 字节串（与 kind 3 同构；原始字节即 payload，解析在加载期） | m3 §11 |
| `ConstRegistry` | `+ addJson(raw: String): Int64` | 注册 JSON 常量 → hid（**拼装期仅登记原始字节**，不解析） | m3 §11 |
| `FbcReader` | kind 11 分支 | ① 载荷校验（u32 长度 + UTF-8）；② **实例化一次**：调 `fountain::f_data.json` 解析器构建 `JsonObject`/`JsonArray` → 登记 ConstTable（路径 A：跨调用同 ID、单元生命周期、不可变）；③ 防御性再校验失败 → 加载期拒绝 | m3 §11 |
| `FbcReader` | verMajor 3 规则集 | LocalType 0–15；含 H66–H68/H73–H75 的 helper 值域；kind 11 合法 | m3 §2、§9.2 |
| `ConstRegistry` | （无独立 frozen 成员） | 「实例化登记」动作把 **frozen 标记写入句柄条目**（唯一所有者 = `HandleTable`，见 §5.4）；供 H74 写保护判定 | m3 §11 |

---

## §4 `compiler` 增量

### 4.1 既有声明的新增/变更成员

| 声明 | 增量 | 说明 | 锚点 |
|---|---|---|---|
| `TypeRef` | `+ AnyT` | `Any` 可声明为局部/参数/返回（15）；HostObject 字段**不扩展**至 15 | m3 §3/§12-4 |
| `AstExpr` | `+ AnyBox(e, typecode)`、`AnyIs(e, target)`、`AnyAs(e, target)`、`JsonLit(raw, shape)`、`JsonIndexGet(obj, key)`、`JsonIndexSet(obj, key, v)` | 装箱/问答/JSON 字面与下标读写的 AST 形态 | m3 §3/§11 |
| `Lexer` | **反引号 JSON 段**的**词法保护** | 段取界 = JSON 字符串感知 + 括号配平（`{"a":"}"}`、`["]"]`、嵌套 `[{…}]` 正确取界）；段内 `//`、`/*`、引号、`{`、`}`、**行首锚定标记**（§8.8）不参与注释识别与配对；换行规范化 CRLF/CR→`\n` | m3 §11 |
| `Lexer` / `Parser` | `{` / `[` **原义保持（无消歧）**——**订正（2026-10-12）**：撤销 v0.3「直写形态」，JSON 只能经反引号书写 | `{ args => body }` = 闭包字面量；`{}` = M1 空 Map 构造；`[…]`（表达式起始）= 列表字面值；`list[i]`/`map[k]` = 下标语法——**不存在「闭包 vs JSON」判定与空形态上下文定夺**；负向：非闭包形态的 `{ "a" : 1 }` → 语法错误 | m3 §11 v0.3.16 |
| `Parser` / `Lowerer` | 顶层结构静态类型 | `{`→`JsonObject`、`[`→`JsonArray`（编译期标注；子类名 = 前端静态知识）；**标量顶层 → 编译错误**（仅作元素） | m3 §11/§12-8① |
| `Lowerer` | **装箱插入点**（类型驱动，全部静态可知） | ① 赋值/初始化 Any 槽；② Any 参数实参；③ Any 返回；④ 容器元素类型为 Any 的写入前（`LIST_APPEND/LIST_SET/LIST_INSERT/MAP_PUT`）——异构容器的实现基础 | m3 §3 |
| `Lowerer` | **拆箱与问答** | `expr is T` / `expr as T`（T ∈ 可转集，程序 15）：左 15 → H67/H68；左非 15 → 按静态类型关系（上行零操作；不相容 → 编译错误）；`as T` 结果类型 = T（可继续参与 T 的既有运算——「先 as 后算」唯一计算路径）；`as <宿主类>` 携类身份（typecode=14 + aux=typeRef） | m3 §3 |
| `Lowerer` | **禁止面（编译错误）** | 15 型上的运算/比较/等值/成员访问/调用；二次装箱（`any_box(15,…)` 不可发射）；非可转集目标（含 `as Closure`）；闭包存入集合（含 Any 盒间接路径） | m3 §3/§12-1/§12-3 |
| `Lowerer` | **JSON 发射** | 非空字面值 → `PUSH_KH`（kind 11 常量）；**JSON 上下文下的空 `{}`/`[]` → H75 `json_new`**（世界内构造，可变、非常量）；`j[i]` → H73 `json_get`；`j[i] = v` → H74 `json_set`（v ∈ 值型 0–3（除 Unit）/String/14——**JSON null 由 `JsonNull.instance` 承载**，非语言 null）；索引类型不符 → 编译错误 | m3 §11 |
| `NameResolver` / 静态检查 | `fountain::f_data.path` 访问 | 经预定义函数通道注册（宿主库提供类型化 getter）；"从 Any 取 JSON 节点"（`as JsonObject`）自 v0.3.12 可用 | m3 §11 |

---

## §5 `runtime` 增量

### 5.1 H66–H68（Any 通道）

| hid | 函数 | 语义 | 失败码 | 锚点 |
|---|---|---|---|---|
| H66 | `any_box(typecode: u8, cell) → h` | **分配型**：值型 → 拷贝装箱（宿主侧分配）；句柄型 → fetch 后存引用（零拷贝） | 6, 8, 16 | m3 §5 |
| H67 | `any_is(h, typecode: u8, aux: u16) → 0/1` | 纯读：`box is T`（集合外类型 → 0 非错误；14 按继承语义） | 8 | m3 §5 |
| H68 | `any_as(h, typecode: u8, aux: u16) → cell` | **条件分配型**：命中 → 值型拆箱直返 / 句柄型按引用 pin（登记 1 槽）；未命中 → 22 | 8, 16, 22 | m3 §5 |

**类型描述符**：`typecode` = 主类型码；`aux` = 容器附加码（`List(10)`：aux=元素类型码；`Map(11)`：aux=(键码<<8)|值码；其余 `0xFFFF`）；二者以 cell 压栈传递（helper ABI 无立即数）。

**容器转型与 P2**：`as List<Any>` / `as Map<Int64,Any>` 的运行期检查依赖仓颉泛型 **reified** 信息；不可用时退化为**不校验元素/键值类型 + 宿主契约**（行为差异必须显式、不允许静默）。

### 5.2 H73–H75（JSON 世界内可变 API）

| hid | 函数 | 语义 | 失败码 | 锚点 |
|---|---|---|---|---|
| H73 | `json_get(h, key, mode: u8) → h15` | 读：结果 = **Any(15) 盒**（对象/数组元素 → 节点盒；标量 → 宿主值盒；**JSON null → 节点盒装 `JsonNull.instance`——单例，非语言 null**）；**条件分配型** | 4, 5, 6, 8, 16 | m3 §11 |
| H74 | `json_set(h, key, typecode: u8, v) → 0` | 写（**变更型**）：对象 upsert（沿 `MAP_PUT`）；数组仅既有下标（越界 → 4，不自动扩展）；**目标 frozen → 20** | 4, 6, 8, 19, 20, 99 | m3 §11 |
| H75 | `json_new(mode: u8) → h14` | 世界内构造空 JSON 值（`{}`/`[]`，可变、非常量）；**分配型** | 16 | m3 §11 |

**JSON 类界谱系（v0.3.13）**：`JsonObject`/`JsonArray` 均为类、同属 `abstract class JsonValue` 子类——`is/as JsonValue` 命中子类；`as JsonObject` 对数组实例 → 22；抽象类不作实例（世界内构造仅 `JsonObject`/`JsonArray`）。

**frozen 标记与传播**：常量实例化登记时置 frozen；**frozen 经读（H73）与拆箱（H68）传播**（从常量取出的子节点保持只读——无需树遍历）。

### 5.3 `SignatureTable` / `SignaturePlan`（CALL_HOST 转发特化）

| 声明 | 成员 | 意义 | 锚点 |
|---|---|---|---|
| `SignatureTable`（protected class） | `func plan(sig: SignatureDescriptor): SignaturePlan` | 键 = canonical 签名（参数 LocalType 序列 + 返回）；值为预解析 marshal 计划（逐参转换器向量 + 返回转换器 + 装配序列）；**身份无关**（不含句柄 ID/单元指纹/注册表快照/对象引用）；桥实例级、只读共享 | m3 §13.1 |
| | `func size(): Int64` | 有界性断言（签名空间 = 类型码序列，天然有界、无淘汰） | T56 |
| `SignaturePlan`（protected class） | `func marshalArgs(args: CPointer<Int64>, out: …): Unit` | 按计划直通转换（消除描述符遍历）；冷路径（plan 未绑定/构建失败）→ 逐字照旧走 m2 §5 通用流程（结果无差；失败不报错、记 diagnostics） | m3 §13.1/§13.3 |
| | 小 argc 展开序列 | `CALL_HOST argc` 为编译期立即数 → 小 argc 预生成展开序列（第 1 步优化） | m3 §13.4 |
| `HostCallback` | `var plan: ?SignaturePlan` | 验签完成时绑定（**per-call**，随条目 try/finally 释放）——此后 H63 零签名查找 | m3 §13.1 |
| 失效门禁（冻结，实现约束） | — | ① 身份相关加速不得跨调用存活；② 若引入（Layer C）必须逐次 `(idx,gen,tag)` 全等校验 + per-call 生命周期 + 绝不跨线程共享；③ **特化路径不得绕过既有失败路径**（含 CALL_HOST 单元卸载后 → 19） | m3 §13.2 |

### 5.4 既有声明的新增/变更成员

| 声明 | 增量 | 说明 | 锚点 |
|---|---|---|---|
| `HandleTable` | 条目 `frozen: Bool` | 可常量化宿主类（JSON）的写保护标记；H74 判定 | m3 §11 |
| `HelperId` | `H_ANY_BOX=66`、`H_ANY_IS=67`、`H_ANY_AS=68`、`H_JSON_GET=73`、`H_JSON_SET=74`、`H_JSON_NEW=75` | 编号接 H65 之后（JSON 面 v0.3.15 顺延 H73–H75） | m3 §5/§11 |
| `Interp` | H66–H68/H73–H75 路由 | M3 规则集单元可含这些 helper 调用 | m3 §5 |
| 分配型清单 | +H66、H68（句柄型命中时）、H73（命中时）、H75 | 每次登记 1 槽（§9.6 扩容兜底照旧） | m3 §5/§11 |
| 变更型清单 | +H74 `json_set` | §9.15 三条规则（常量禁写 20 / deopt 禁令 / 兜底 99） | m3 §11 |

---

## §6 根包（门面/桥）增量

| 声明 | 增量 | 意义 | 锚点 |
|---|---|---|---|
| `CallMarshal` | 参数 `Any` 行 | 接受**任意宿主值**（含闭包、宿主类实例、任意对象）→ 装箱入条目（存放原生 `Any`）→ cell = 句柄；null → 19（与句柄恒非空不变式一致） | m3 §4 |
| `CallMarshal` | 返回 `Any` 行 | `get` → 原生 Cangjie `Any` 原样返回宿主 | m3 §4 |
| `CallMarshal` | 错误码映射 1–22 | 22 行入静态表 | m3 §4 |
| `H63`（运行时）| 特化接入 | fetch → `entry.plan`（命中跳过解释循环）→ 调用 → 返回封装 → 异常转码；冷路径照旧 | m3 §13.1 |
| `CompilePipeline` | 特化开关（强制通用 / 强制特化） | 验收：T30–T36 全量 ×（强制通用/强制特化）逐位对拍 + T56 | m3 §13.3 |

---

## §7 关键调用链（M3 增量）

### 7.1 Any 装箱/拆箱流

```
装箱（类型驱动插入点）: expr(非 15) 目标要 15 → any_box(类型码, expr)  [H66；值型拷贝 / 引用型存引用]
问答: a is T  → any_is(h, T码, aux)                         [H67；集合外 → false]
拆箱: a as T  → any_as(h, T码, aux)                         [H68；命中 → 值型直返 / 句柄型 pin；未命中 → 22]
容器: GET_IDX/GET_KEY 返回值直接是 15 型表达式（盒句柄），无需转换
```

### 7.2 JSON 字面量编译/加载流

```
词法（唯一形态）: 反引号 `…`
  → 词法保护段（JSON 字符串感知 + 括号配平）→ 换行规范化
  → 编译期按 JSON 语法解析一遍（非法 → 源编译错误，含位置）
  → 静态类型：体首 {→JsonObject / [→JsonArray（标量顶层 → 编译错误）
  → 发射：非空字面值 → kind 11 常量（PUSH_KH）；空字面量（`` `{}` `` / `` `[]` ``）→ H75 json_new
加载期: kind 11 → f_data.json 解析器实例化一次 → ConstTable（路径 A、不可变、frozen）
访问: f_data.path 类型化 getter（预定义通道）；异构取值 → Any 盒 + is/as
```

### 7.3 JSON 世界内可变流

```
j[i]   → json_get(h, key, mode)  [H73；结果 = Any 盒；越界 4 / 缺键 5；frozen 经读传播]
j[i]=v → json_set(h, key, 码, v) [H74；变更型 → flags.bit0 + deopt 禁令；frozen → 20；对象 upsert / 数组仅既有下标]
{}、[] → json_new(mode)          [H75；分配型；可变新值，非常量]
```

### 7.4 CALL_HOST 转发特化流

```
H63: fetch → entry.plan（Layer B，验签时绑定）
        ├ 命中 → 按 plan 直通（转换器向量 + 装配序列；argc 展开）
        └ 冷路径 → 逐字照旧（m2 §5 通用流程；结果无差）
      → 调用 fn → 返回封装 → 异常转码 21
失效面：plan 身份无关（槽复用/gen 不影响）；条目 plan per-call（随 try/finally 释放）；
        卸载零交互（CALL_HOST 单元卸载后 → 19 不得绕过）；注册表/常量无关
```

---

## §8 兼容矩阵与版本规则

| 产物 \ 加载器 | M1（1） | M2（2） | M3（3） |
|---|---|---|---|
| verMajor 1/2 产物 | ✓ | ✓ | ✓（按各自规则集） |
| verMajor 3 产物 | ✗（18） | ✗（18） | ✓ |

- LocalType 合法集按 verMajor 分派：M1=0–12；M2=0–14；M3=0–15；16–255 恒拒。
- 不变项：ctx、帧布局、全部 M1/M2 指令语义、fail-fast、窗口/逃逸机制、§9.15 规则集（变更型**无新增来源**——M3 的 json_set 为显式新来源）。

---

## §9 设计决策

| 决策 | 理由 |
|---|---|
| Any 用「盒 = 句柄条目直存原生 Any」 | 决策 ④ 复利：句柄表天然能存；零新机制；装箱语义 = Cangjie 本体（值型拷贝/引用共享） |
| `as` 未命中独立错误码 22（与 7 分列） | 动态转型失败与静态值转型语义不同；独立码利于宿主分支处理 |
| 盒不可变 ⇒ 「不触发 deopt 禁令、不置 flags.bit0」 | box 分配型 + is/as 纯读 ⇒ 重放安全沿用 I8「重复分配等值对象」 |
| JSON 非空字面值 = 常量（frozen）；空形态 = 世界内构造（可变） | 对齐 M1 v0.18 空容器先例；常量面白捡（重放/差分安全），可变面经 §9.15 纪律 |
| frozen **经读/拆箱传播**（不树遍历） | 从常量取出的子节点保持只读；实现 O(1) |
| 特化以「是否携带身份信息」划界 | 身份无关 ⇒ 失效语义可冻结；Layer C 设**门禁三条**（未满足不得合入） |
| 特化 ≡ 通用为构造性：转换器**直接复用**同一转换函数 | 不写第二份语义；唯一可观察差异 = 性能 |
| 非托管内存（ctx / 转储缓冲） | 沿用 M1 选型 `std.core.LibC.malloc<T>` / `LibC.free<T>`（design-m1 §5.3.1）；M3 不新增任何非托管内存 |

---

## §10 待裁定 / 登记项

| # | 项 | 处置 |
|---|---|---|
| M3-1 | **T59 重号**：m2 §10 的 T59（HostClosure 签名含 14）与 m3 §10 的 T59（JSON 世界内可变 API + Any↔14）重号 | **已裁定并实施（2026-10-11）**：m3 侧改 **T61**（m2 侧保持 T59）；m3 规格、本文与 plan-m3 已同步 |
| M3-2 | P2（泛型 reified）可用性 | 容器转型元素校验的退化路径（不校验 + 宿主契约）——行为差异必须显式、不允许静默 |
| M3-3 | §13.5 开放钉子：plan 构建时点（默认倾向「验签即建」）、argc 展开阈值、Layer C 是否引入 | 实施时裁定（Layer C 须过门禁三条 + 收益门槛） |
| M3-4 | 已裁定（记录）：Any 等值/哈希永久排除；盒套盒不实现；struct 不考虑；HostObject 字段不扩展至 15；12 转型不开放；JSON 标量顶层不开放 | 无重议通道（等值）/维持裁定 |
| M3-5 | JSON 常量实例化依赖 `fountain::f_data.json` | f_jit 的 `cjpm.toml` 需增 `fountain::f_data` 依赖（M3 起点）；加载器对解析失败的防御拒绝 |

| M3-6 | **JSON helper 编号冲突**：m3 §11 写 H72/H73/H74（「编号接 H71」），但 M1 v0.18.19 已占用 **H72 = `regex_replace_range`**（m1 §6 行 609）| **已裁定并实施（2026-10-11）**：JSON 面顺延 **H73/H74/H75**；m3 规格「编号接 H71」已订正为「编号顺延」；本文与 plan-m3 已同步 |
| M3-7 | 错误码 22 与 7 的边界实施复核（m3 §12-6："若实现中 7 的覆盖面实际重叠，实施时复核"） | 复核钩；本设计维持**分列**裁定 |
| M3-8 | **JSON「直写形态」撤销（2026-10-12，用户订正）** | **已实施**：规格升 **v0.3.16**——JSON 只能经**反引号**书写（唯一形态）；`{`/`[` 保持 M1 原义（闭包字面量 / 空 Map / 列表字面值 / 下标），**不存在消歧与空形态上下文定夺**；v0.3.12 的「空形态 = 运行期构造（H75）」改锚到**反引号空字面量**（`` `{}` `` / `` `[]` ``），非空仍为常量。落点：本文 §1/§2/§7.2/附 A；plan-m3 R3.6/R3.7/R3.8/R4.8/R6.5；design-m1 附 A/附 C |

---

## 附录：M3 增量三表（语法 → 字节码 · 指令定义 · 机器码对照）

**口径**：与 `design-m1.md` 附录相同——**权威文本是规格 `jit-bytecode-m3.md`**（`§` 均指该规格章节），本附录为同源整理，冲突以规格为准。**本附录只列 M3 增量**；M1 全量三表见 `design-m1.md` 附录，M2 增量见 `design-m2.md` 附录。

## 附 A M3 语法元素 → 字节码（增量）

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| Any 槽（赋值 / 初始化） | `let a: Any = e` | 目标位置要求 15 而表达式类型 ≠ 15 ⇒ 发射 `any_box(typecode, e)`——装箱插入点 **①赋值/初始化**（类型驱动、全部静态可知） | `CALL_HELPER` H66 | §3 |
| Any 实参 / Any 返回 | `f(e)`（形参 15）、`return e` | 同上——插入点 **②实参、③返回** | H66 | §3 |
| 异构容器元素写入 | `list.add(e)`、`m[k] = v`（元素/键值类型 = Any） | 写入前对元素发射 `any_box`（**异构容器的实现基础**）；容器大类型仍为 10/11，元素类型是前端/桥的**静态外知**；元素**读回** cell 即盒句柄（15 型表达式、**无需转换**） | H66 | §3 |
| Any 问答 | `a is T`（T ∈ 可转集） | `any_is(h, typecode, aux)`——**纯读**；集合外类型 → **0（非错误）**；`a` 静态类型非 15 时按静态关系处理（不发射 helper） | H67 | §3、§5 |
| Any 强制转型 | `a as T` | `any_as(h, typecode, aux)`——**本方言 `as` = 强制转型（fail-fast）**（**非仓颉 `as`**，后者返回 `Option<T>`）：命中 → 值型拆箱直返 / 句柄型按引用 pin（**条件分配型**，登记 1 槽）→ 结果类型 = **T**、可继续参与 T 的全部运算；未命中 → **22**；`T = 14` 时按**仓颉继承语义**核对（`is` 含子类）；`as Closure` / 非可转集目标 → 编译错误；"任意 HostObject"（不指明类）仍不开放 | H68 | §3、§5 |
| 类型描述符（H67/H68 的 2/3 实参） | — | `typecode` = 主类型码（LocalType）；`aux` = 容器附加码：List → 元素类型码、Map → `(键码 << 8) \| 值码`、其余 `0xFFFF`；**以 cell 形式压栈传递**（helper ABI 无立即数，同既有模式） | — | §5 |
| 失败可继续的写法 | `if (a is T) { … a as T … }` | 先 `is` 后 `as`（盒不可变 ⇒ 两次判定一致）；`as` 自身即 fail-fast 单步路径 | H67/H68 | §3 |
| JSON 字面量（反引号形态） | `` `{"k":1}` `` | 常量注册 **kind 11**（payload = u32 长度 + UTF-8 原始 JSON 字节，**同 kind 3 编码同构**）→ `PUSH_KH idx`；**加载期一次解析**为 `JsonObject` / `JsonArray`（路径 A 常量、**不可变**） | `0x16` | §11 |
| JSON 空字面量 | `` let o: JsonObject = `{}` ``、`` let a: JsonArray = `[]` `` | **运行期构造**（`json_new`，分配型；可变新值、**非常量**）——对齐 M1 空容器先例；非空字面值维持常量（只读） | H75 | §11 |
| JSON 下标读 | `j[i]`（`JsonArray`: Int64 / `JsonObject`: String） | `json_get(h, key, mode)`——**条件分配型**；结果 = **Any 盒**：对象/数组元素 → 节点盒，标量元素 → 宿主值盒，JSON `null` → **`JsonNull.instance` 盒**（单例，非语言 `null`）；数组越界 **4** / 对象缺键 **5**；索引类型不符 / 对标量节点下标 → **编译错误** | H73 | §11 |
| JSON 下标写 | `j[i] = v` | `json_set(h, key, typecode, v)`——**变更型**（对象 = upsert；数组 = 仅既有下标、越界 **4** 不自动扩展）；`v` ∈ 值型 0–3（除 Unit）/ String / 14 节点；**frozen 目标（从常量取出的子节点）→ 20**（frozen 经 H73 读与 H68 拆箱**传播**） | H74 | §11 |
| JSON 标量顶层 | `123` / `"s"` / `true` / `null` 作字面量顶层 | **编译错误（不开放）**——标量仅作元素存在（顶层恒为对象/数组） | — | §11 |
| JSON 访问 API | `fountain::f_data.path` 的类型化 getter | 纯宿主库 → 经 **M2 §8.4 预定义函数通道**注册（`CALL_HELPER <user hid>`）；JSON 句柄（14）作参数直接可传；成员访问语法糖与本篇**无交互** | `0x75` | §11、m2 §8.4 |
| CALL_HOST 转发特化 | 热路径宿主回调（同源形式） | **不改 `.fbc`、不改 lowering**：验签后按签名绑定 `SignaturePlan`（桥内部运行时物）；机器码仍是 `call H63` | — | §13 |
| 禁止面 | 15 型表达式上的运算 / 比较 / 等值 / 成员访问 / 调用 | **全部编译错误**（提示"先 `as`"）——仓颉 `Any` 本体语义；等值/哈希为**永久排除** | — | §3、§12 |
| M1 / M2 面 | — | 见 `design-m1.md` 附 A、`design-m2.md` 附 A | — | — |

## 附 B M3 字节码增量定义

| 项 | M2 | M3 增量 | 锚点 |
|---|---|---|---|
| LocalType | 0–14 | **+15 = Any**（句柄型、恒非空；16–255 仍拒绝） | §2 |
| 类型 token | 1–11 | **+12 = Any** | §2 |
| 指令 | — | **无新 opcode**：`box` / `is` / `as` 全部经 `CALL_HELPER` 路由（H66–H68） | §2 |
| 错误码 | 0–21、23 / -1 / -2 / 99 | **+22 `ERR_ANY_CAST`**：强制转型未命中（`site` = `any_as` 调用点）；与 **7（值转型，静态转换语义）分列** | §2 |
| 常量 kind | 1–10 | **+11 = Json**（payload = u32 长度 + UTF-8 原始 JSON 字节；解析在**加载期**；实例化登记 = **路径 A 常量** + **frozen 标记**） | §11 |
| 句柄条目 tag | +10 / +11（M2） | **+12 = Any**（`{tag=12, box: Cangjie Any}`——`box` 为原生 Cangjie `Any` 值，零新机制）；JSON 节点走**既有 HostObject 通道**（tag 11 / LocalType 14） | §1 |
| helper | H01–H65、H69–H72 | **+H66** `any_box(typecode, cell) → h`（**分配型**：值型拷贝装箱 / 句柄型 fetch 后存引用）、**+H67** `any_is(h, typecode, aux) → 0/1`（纯读）、**+H68** `any_as(h, typecode, aux) → cell`（**条件分配型**：命中值型直返 / 句柄型 pin）、**+H73** `json_get`、**+H74** `json_set`（变更型）、**+H75** `json_new`（分配型） | §5、§11 |
| 分配型清单 | 既有 | **+H66、H68**（句柄型命中时）；`hwCap` 估计按装箱/转型点的**静态类型**编译期计入 | §5 |
| 变更型清单 | H43–H48、H65 | **+H74** `json_set`（§9.15 全规则：frozen 目标 → 20 / deopt 禁令 `flags.bit0` / 防御兜底 → 99） | §11 |
| 版本 | verMajor 2 | `.fbc` 头 **verMajor 3**：M1/M2 加载器遇 3 → 加载期拒绝（18）；M3 加载器兼容 1/2/3（按 verMajor 分派规则集） | §2 |

**可转集（H67/H68 的 `typecode` 合法域，冻结）**：`0–8、9–11` + **14**（v0.3.12 并入）——其中 `3 = Unit` 无装箱发射点（前端不产生）；`9 = Regex` 自 v0.3.6 并入；**`12 = Closure` 不开放转型**、`13 = HostClosure` 为二期候选；**`15` 不在可转集内 ⇒ 禁二次装箱**（盒不套盒；需要嵌套载荷 → 宿主类包装）。

**不变项（§2）**：ctx、帧布局、全部 M1/M2 指令语义、fail-fast、窗口/逃逸机制、§9.15 变更型规则集（无新增来源）——**全部不变**。

## 附 C M3 字节码 ↔ 机器码（增量）

| 字节码 / 机制 | x86_64 / AArch64 | 备注 | 锚点 |
|---|---|---|---|
| `CALL_HELPER H66` / `H67` / `H68` | **= 模板 A**（`CALL_HELPER` 同款；自动尾随 `CHECK_ERR`） | 机器码**无新模式**（I8 自动满足）——装箱/转型语义全在 helper 内 | §5、m1 §12.4 模板 A |
| `CALL_HELPER H73` / `H74` / `H75` | 同上 | 分配型 / 变更型语义（窗口登记、frozen 检查、§9.15 路由）全在 helper 内实现 | §11 |
| JSON 常量（kind 11） | `PUSH_KH idx` **机制不变**（常量句柄镜像照旧） | payload 解码、`JsonObject`/`JsonArray` 实例化与 `frozen` 标记属**加载期 / 桥内**——**不产生机器码** | §11、m1 §12.4 |
| `CALL_HOST`（转发特化） | 仍是 **`call H63`** | `SignatureTable` / `SignaturePlan` 为**桥内部运行时物**——不入 `.fbc`、不改机器码；门禁三条（携带身份信息的加速结构不得跨调用存活） | §13 |
| 13 / 14 / 15 型 cell | 与既有句柄型**零差异**（1 cell = 8 B、不解引用） | 机器码层零新增 | m1 §3.2、§12.4 |
| 帧 / ctx / 寄存器 / W^X / IBT | 全部不变 | M3 的机器码增量**仅为 H66–H68、H73–H75 的 helper 入口本身** | §2 不变项 |

**验证面**：三引擎一致性（I7）照旧——`box`/`is`/`as`/JSON 全部经 helper ⇒ 解释器与两个 JIT 后端共用**同一份** helper 实现，差分口径为"结果、`errCode`、`site` 三者全等"（§7、§10 的 T37–T41 / T56 / T61）。
