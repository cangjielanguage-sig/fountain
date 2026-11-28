# f_collection 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_collection`（19 个源文件；本部分覆盖 4 个 `.cj`）
- **基线**：工作区快照（当前检出 `sts/1.3.x`；`git status` 仅 `docs/review/`、`reviews/` 未跟踪，源码无 diff → 本部分全部为存量，blame 均为 `4be871f2fd` 2026-10-02「统一换行符」提交）
- **审查重点**：集合运算、树字典、等值映射的正确性与迭代器语义；死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（第 2/2 部分，供主 Agent 合并为 `docs/review/f_collection_review_20261128.md`）
- **本部分文件**：`SetOp.cj`、`TreeDict.cj`、`UnionSetView.cj`、`ValueEqualMap.cj`
- **与第 1 部分的关系**：`IntersectionSetView.cj` / `DifferenceSetView.cj` / `HashDict.cj` / `Collection_test.cj` 属第 1 部分；本部分只把它们当证据引用，不重复记账。凡与第 1 部分同源的条目均已注明，合并时请合并为一条。

## 发现

### [严重][存量] `UnionSetView.iterator()` 用「差集 ∩ 第二个集合」实现并集，恒为空

- **位置**：`src/UnionSetView.cj:36-38`（核心 `37`）；受污染成员 `39-41`（`isEmpty`）、`42-50`（`size`）、`66-71`（`subsetOf`）；下游使用者 `f_concurrent/src/ConcurrentHashSet.cj:147-149`（范围外，仅作影响面）
- **来源**：存量（`git blame -L 33,38` → `4be871f2fd` 2026-10-02，全文件同源）
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）、§10 正确性、§14（承诺并集视图但产出空集）
- **证据**：静态确定 —— 第 37 行组合了两层过滤：
  1. `DifferenceSetView(set1, set2).iterator()` 产出满足 `!set2.contains(e)` 的 `e`（`DifferenceSetView.cj:21`、`34`）；
  2. `IntersectionSetIterator(itr, set2)` 只放行满足 `set2.contains(e)` 的 `e`（`IntersectionSetView.cj:21`）。
  两个谓词互斥，同一元素不可能同时成立 → `iterator()` 对任何输入都只会返回 `None`。这是纯谓词推演，无需运行。
- **描述**：并集视图的全部**遍历型**语义都被打穿，而 `contains`（`57-59`，`set1.contains || set2.contains`）仍是对的，于是同一个对象自相矛盾：
  - `for (e in s.union(t))` / `toArray()`（`Collection.toArray` 默认走迭代器）/ 任何序列化都是空；
  - `size` 恒 0、`isEmpty()` 恒 true，即使 `s.union(t)` 明确包含 `s` 的全部元素；
  - `subsetOf(other)` 因遍历空而恒返回 true（空真），`{1}.union({2}).subsetOf({})` 也判 true；
  - 反之 `contains(1)` 返回 true 而 `size == 0`，调用方无法用任一口径自洽。
  另外 `UnionSetIterator`（`21-32`）已实现且**全仓零引用**（`grep UnionSetIterator` 只命中定义），说明作者原本就想用它、结果接错成了交集迭代器；但该 helper 本身只是两段迭代器顺序拼接，两个集合有交集时会产出重复元素，也不能直接当并集用。
  测试侧完全没有覆盖：`Collection_test.cj` 全文无 `union` / `intersection` / `difference` / `SetOp` 字样（`grep` 无命中），只有一个 `containsValue` 用例（`236-238`）。
- **建议**：改为「先取 `set2 \ set1`，再与 `set1` 拼接」，这样既不重复也不遗漏：
  `UnionSetIterator<T>(set1.iterator(), DifferenceSetView<T, Set<T>>(set2, set1).iterator())`；
  `isEmpty()` 改成 `set1.isEmpty() && set2.isEmpty()`（避免为判空全量扫描）。补一条 `{"a","b"}.union({"b","c"})` 的 `size == 3` + `toArray` 无重复 + `isEmpty() == false` 用例。

### [一般][存量] `TreeDict` 的四组包装类型与 `HashDict` 逐行同构，且可见性已经漂移

- **位置**：`src/TreeDict.cj:246-254`（`ComparableKeyMapIterator`）↔ `src/HashDict.cj:231-239`（`HashDictIterator`）；`TreeDict.cj:255-301`（`ComparableKeyCollection`）↔ `HashDict.cj:240-286`（`HashKeyCollection`）；`TreeDict.cj:302-310` ↔ `HashDict.cj:287-295`；`TreeDict.cj:311-326` ↔ `HashDict.cj:296-311`
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §2（只改类型名 / 跨文件复制）
- **证据**：静态确定 —— 四组类逐段对齐后只差 `HashKey<K>` ↔ `ComparableKey<K>`、`HashDict` ↔ `TreeDict`；`next()` 都是 `for(x in itr){ return x.key[...] }`，`entryView` 都是 `key → view.key.key` 的两行转发。第 1 部分已就 `HashDict` ↔ `LinkedHashDict` 报过同一条（第 1 部分「重复逻辑：`HashDict` 与 `LinkedHashDict` 整套同构」），`TreeDict` 是第三份拷贝。
- **描述**：三份 `Dict` 实现共用同一套「键包装 + 解包迭代器 + 键集合 + entryView 转发」结构，任何一处行为修正（例如下一轮给迭代器加版本校验）都要改三遍。已经出现可见性漂移：同样职责的 `HashDictIterator` / `HashKeyMapEntryView` 是 `public`（`HashDict.cj:231`、`296`），而 `TreeDict` 侧四个类全是包内可见（`TreeDict.cj:246`、`255`、`302`、`311`），对外表现不一致，且 `ComparableKey*` 这几个类型名完全没出现在 README 里。
- **建议**：抽一个 `KeyUnwrapIterator<W, K, V> where W <: KeyWrapper<K>` 与对应的 `KeyCollection` / `KeyEntryView`，`HashKey`、`ComparableKey` 只实现 `KeyWrapper<K>.unwrap(): K`；并把四个包装类统一收成 `internal`（`HashDict` 侧一并收窄，属第 1 部分文件）。

### [一般][存量] README 的 `TreeDict` 段把类名写成 `LinkedHashDict`，按文档写代码编译不过

- **位置**：`README.md:267`、`README_en.md:267`（`public class LinkedHashDict<K, V> <: Dict<K, V>`）；对照实现 `src/TreeDict.cj:32`
- **来源**：存量（文档与代码同在 `4be871f2fd` 快照内，无 diff）
- **判据**：review-checklist §13（API 与源码不符 / 示例不能用）
- **证据**：静态确定 —— `README.md:263` 的标题是 `## TreeDict`，正文第一行声明的类型却是 `LinkedHashDict`；全仓 `TreeDict` 只有 `TreeDict.cj:32` 一处定义，`LinkedHashDict` 是另一个类（`LinkedHashDict.cj`）。同一段落里 `TreeDict.cj:39` 用的是 `public TreeDict(...)` 主构造器（正确），与首行的类名自相矛盾，说明是复制 `LinkedHashDict` 段落后漏改。
- **描述**：使用者照抄该段声明 `LinkedHashDict` 却传 `cmp` 参数（`README.md:271`），会直接编译失败；更糟的是这个类名错误出现在「排序树字典」条目下，容易让人以为 `LinkedHashDict` 接受比较函数。另有一处次要偏差：`README.md:281` 对 `init(size, initElement, cmp)` 写「初始容量是 size」，而实现（`TreeDict.cj:45-51`）是把 `0..size` 的返回值逐个 `add` 进去（`TreeMap` 没有容量概念），`size` 是元素个数不是容量。
- **建议**：两处类名改为 `TreeDict`；`README.md:281`/`README_en.md:281` 的「初始容量是 size」改成「用 initElement 生成 size 个键值对」。

## 优化可行性方案

### [堆内存] `SetOp` 三个运算在构造视图时就全量复制入参

- **现状**：`intersection` / `union` / `difference` 一进来就 `HashSet<T>(collection)`（`SetOp.cj:27`、`30`、`33`；`LinkedHashSet` 行 `38`、`41`、`44`；`TreeSet` 行 `49`、`52`、`55`），把 m 个元素的入参整体复制成一个 Set 并持有到视图生命周期结束；视图本身（`UnionSetView` 等）只存两个 Set 引用。峰值增量 ≈ m ×（Set 节点 + 桶）量级，m 由调用方决定，没有上限。
- **方案**：视图改为持有 `Collection<T>`，`contains` 走 `collection.contains`（`HashSet` 入参仍是 O(1)）；或延迟到首次 `contains`/`iterator` 时再物化并缓存（`var index: ?Set<T>`）。同时可以去掉 `SetOp` 方法上的装饰性类型参数 `C`（`C` 在视图类型体中从不出现，只是让每个入参类型生成一个不同的 `UnionSetView<T, C>` 静态类型；第 1 部分「幽灵类型参数」条已就视图侧提过）。
- **预期**：构造期从 O(m) 堆占用降到 O(1)（未命中物化路径）；代价是非 Set 入参的单次 `contains` 从 O(1) 退化为 O(m)，需按入参类型分流。
- **代价**：语义不变（视图仍只读），但 `contains` 复杂度依赖入参实现；`size`/`iterator` 已是 O(n)，不受影响。
- **验证**：入参分别用 `ArrayList`（n = 1e4 / 1e5 / 1e6）与 `HashSet`，对比 `union` 构造后与首次遍历前的 `getAllocatedHeapSize()` 峰值、以及一次完整遍历的耗时中位数（`-O2`，同机同 SDK）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SetOp` 的入参物化是集合运算路径的主要分配来源（复制出的 Set 占峰值内存大头） | `src/SetOp.cj:27/30/33` | 分配量与峰值占比 | `cjprof heap` 或前后 `getAllocatedHeapSize()`，入参 1e5/1e6 两档 |
| 2 | `TreeDict.get/contains` 每次构造 `ComparableKey` 的自耗时不可忽略（1e5 元素树、1e6 次查询） | `src/TreeDict.cj:53-55`，调用点 `61-72` | 自耗时占比与单次开销 | `cjprof record` 跑 1e6 次 `get`，与裸 `TreeMap<Int64, V>` 对照 |
| 3 | 使用方在循环条件里调用视图 `size`（O(n) 且每次重算）导致 O(n²) | `src/UnionSetView.cj:42-50`（另两个视图见第 1 部分同条） | 真实调用点与轮次 | 全仓搜 `.size` 于视图变量上的使用；`cjpm bench -O2` 对比 `size` 调用 1 次与 1e4 次 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/SetOp.cj` | .cj | ✅ | 见严重 1 的下游影响面、重复逻辑与未使用 import |
| 2 | `src/TreeDict.cj` | .cj | ✅ | 见重复逻辑一条；边界/空值/并发已逐函数核对，未发现新缺陷 |
| 3 | `src/UnionSetView.cj` | .cj | ✅ | 见严重 1、`retain` 条（并入第 1 部分） |
| 4 | `src/ValueEqualMap.cj` | .cj | ✅ | 见接口设计轻微条；扩展与迭代器实现无缺陷 |

合计（本部分清单）：`.cj` 4 个 / `.md` 0 个，全部读完。

> **移交提示**：`README.md` / `README_en.md` 不在本部分任务清单内（第 1 部分报告声明由第 2 部分覆盖，但本轮任务书只给了 4 个 `.cj`）。本报告只读了与这 4 个 API 相关的段落（`README.md:240-337`、`447-499`，`README_en.md:263-286`、`447-499`）并据此报了 1 条文档缺陷；**README 全文的 §13/§14 覆盖仍缺口**，需主 Agent 指派或补一轮。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 1（并集迭代器恒空）；设计 1（`ValueEqualMap` 的 `K` 形参未使用、自研 `Dict` 未获扩展）；可读性 1（`TreeDict` 的 `addIfAbsent/replace/toArray/entryView/first/last/forward/removeFirst/removeLast` 无注释，`SetOp` 接口无注释）；安全性 0（无外部输入、无凭据、无 SQL/文件/网络） |
| §1 死代码 | 1 | 机械动作全做：`private`/`internal` 符号全仓搜引用——`newKey`（10 处调用）、`extract`（4 处）均有调用者；非 public 类 `ComparableKeyMapIterator`/`ComparableKeyCollection`/`ComparableKeyIterator`/`ComparableKeyMapEntryView` 均被本文件构造，其 `public` 成员均为接口实现（`Iterator`/`Collection`/`MapEntryView`）故豁免；未使用 import 命中 `ReadOnlySet`（`SetOp.cj:18`，全文件仅此一次出现）。另记 2 条**可见性建议**（不计死代码）：`UnionSetIterator`（`UnionSetView.cj:21-22`）与 `ComparableKey`（`TreeDict.cj:20-24`）是公开类型但构造器为 `internal`（仓颉 struct/class 成员缺省 `internal`，见 `cangjie_docs/docs/dev-guide/source_zh_cn/struct/define_struct.md:199`、`class_and_interface/class.md:370`），外部无法构造 |
| §2 重复逻辑 | 2 | 已把 4 个文件的函数体压成「输入→输出→副作用」两两比对，并跨文件对齐 `HashDict`/`LinkedHashDict`/两个 SetView：命中 `SetOp` 9 个同构方法体、`TreeDict` 四组包装类（第三份拷贝）；`UnionSetView` 与 `IntersectionSetView`/`DifferenceSetView` 的 100 余行同构（含 `retain`/`clone`/六个空 mutator）并入第 1 部分同名条目，本部分只补位置 `UnionSetView.cj:33-147` |
| §3 空实现 | 1 | 视图六个 mutator（`add/remove/removeIf/clear` 等）是类注释 `UnionSetView.cj:18-20` 明示的 Null Object，按 §3 误报边界不判；命中 `retain(all!)`（`136-138`）构造视图后丢弃——与第 1 部分同源，仅追加位置 |
| §4 栈溢出 | 0 | 4 个文件无递归：`ComparableKey.compare` 直接调外部闭包；迭代器全部是 `for` + `return`；`SetOp` 三个方法是单条构造表达式。无自引用结构 |
| §5 OOM | 0 | 未发现无上限/按不可信长度分配：`TreeDict.remove(all!)` 按 `all.size` 建数组（规模受调用方控制，同第 1 部分「用 size 预分配」条）；`ConcurrentHashMapValues` 是惰性视图不落地。`SetOp` 的入参全量复制量级由调用方决定、无拒绝路径，但无上限常量可判 → 进「优化可行性方案」，不按缺陷记账 |
| §6.1 热点瓶颈 | 0 | `scope.md` 未提供任何 profile/bench，三条性能推断全部降级到「待验证假设」，未写成结论 |
| §6.2 大粒度锁 | 0 | 4 个文件无锁、无原子、无 `synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池/批处理 |
| §6.4 低效算法 | 1 | 命中 `UnionSetView.isEmpty()`/`size` 因迭代器恒空而退化为「全量扫描 + 结果恒真」（并入严重 1）；`TreeDict` 各操作是 `TreeMap` 的 O(log n) 转发，`toArray`/`remove(all!)` 均是单遍 O(n)，无嵌套扫描 |
| §7 降堆内存方案 | 1 | `SetOp` 延迟物化，已标 `无基线（待验证）` |
| §8 降 CPU 方案 | 0 | 本部分无新方案；第 1 部分「视图 `size` 惰性缓存」同样适用于 `UnionSetView.size`，合并处理，不重复记账 |
| §9 local mode 可行性 | 0 | 4 个文件里唯一的大临时对象是 `TreeDict.remove(all!)` 的 `Array<ComparableKey<K>>`（`129-131`），它直接作为参数传给 `map.remove(all:)` 后即弃，但需要 `@ local` 版本的 `TreeMap.remove(all:)` 与 `Array` 初始化器，std 无对应 mode 重载；且该路径不是分配热点（无数据）→ 不成立 |
| §11 现有代码的 BUG（存量） | 8 | 逐函数核对了 4 个文件的边界/空值/契约：`TreeDict.get/add/contains/remove/removeIf/clear/entryView/first/last/forward/removeFirst/removeLast`、`ComparableKey.compare` 两个重载、`ConcurrentHashMapValues/Iterator`、6 个接口默认实现的返回路径均与 std 语义一致；命中即上面 8 条（全部 `[存量]`，快照模式无基线可比） |
| §12 并发安全与锁粒度 | 0 | 4 个文件无共享可变静态状态、无锁可评。逐一过「会被多线程调用」：`TreeDict`/视图/`ConcurrentHashMapValues` 都是无同步的普通容器，与 std `HashMap`/`TreeMap` 同类；仓内无跨线程共享证据（`TreeDict`、`SetOp` 仓内零调用，`union` 仅被 `f_concurrent` 的 `ConcurrentHashSet` 暴露成方法而未在本仓被调）。视图持有调用方的 `set1` 引用，构造后修改底层集合会导致 `size` 与迭代不一致——属视图语义而非数据竞争，已在类注释「只读集合」范围内 |
| §14 功能完备性与 README 覆盖 | 1 | `README.md:321`「所有 Map 实现和 ConcurrentHashMap 都可以增加这两个接口的扩展」→ 搜索证据：全仓只有 `HashMap`/`TreeMap`/`LinkedHashMap`/`ConcurrentHashMap` 四个 `extend ... <: ValueContainsMap/ValueEqualMap`（`ValueEqualMap.cj:43-61`），自研的 `HashDict`/`LinkedHashDict`/`TreeDict` 都没有，`treeDict.containsValue(x)` 无法编译；另 `UnionSetIterator`/`IntersectionSetIterator`/`DifferenceSetIterator` 三个 public 类型未进 README 的「其他公开 API」表（`README.md:486-499`） |
| 文件覆盖（§13 等） | 4/4 | 本部分 4 个 `.cj` 全部读完；`README.md`/`README_en.md` 仅核对了相关段落，全文覆盖缺口见上方「移交提示」 |

**范围外提示**（不计入统计）：
- `docs/speech/speech.md:4058` 称「`SetOp` 的三个视图……做集合运算不产生拷贝」，与 `SetOp.cj:27/30/33` 的入参物化不一致，建议随优化方案一起改口径。
- `f_concurrent/src/ConcurrentHashSet.cj:147-149` 复用了同一份 `UnionSetView`，因此该模块的 `union` 也返回空迭代；本轮只在 f_collection 记账，修复后无需改 f_concurrent。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 2 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

存量缺陷 8 条（本部分全部为存量），是否纳入修复待用户决定。

## 总评

这 4 个文件的骨架是清楚的：`TreeDict` 用 `ComparableKey` 把调用方比较器适配进 std `TreeMap`（std 没有比较器构造器，这是唯一可行写法，实现也正确——`get/add/remove/entryView/first/last` 全部走同一比较器，没有出现 `HashKey` 那种「一半按 hash 一半按内容」的混乱）；`ValueEqualMap`/`ValueContainsMap` 用接口默认方法给出两个 `containsValue` 重载，`ConcurrentHashMap` 缺 `values()` 时用惰性视图补齐，都是干净做法。这两块本轮没有发现缺陷，只有接口参数冗余与文档覆盖的小问题。

真正的阻塞项只有一个，但很致命：`UnionSetView.iterator()` 把「差集」和「交集」串在一起，等于永远返回空——`union` 这个公开 API 的遍历语义（含 `size`、`isEmpty`、`subsetOf`、`toArray`）全错，而 `contains` 又是对的，调用方拿到的对象自相矛盾。它同时污染 `f_concurrent` 的 `ConcurrentHashSet.union`。更值得警惕的是，正确的 helper `UnionSetIterator` 就躺在同文件第 21 行且全仓零引用——代码写完了但没接上，测试也恰好没有一条 SetOp 用例，这和第 1 部分发现的 `BitSet.set`、`ExtendMap.retain` 是同一类「能编译、能跑、静默错」的问题。

排期建议：严重 1 条立即修（三行改动 + 一个用例即可止损，且必须补 `union` 的 size/toArray 断言，否则下一次重构还会漏）。两条一般里，README 类名错误是几分钟的事，可紧随其后；包装层去重涉及 `HashDict`/`LinkedHashDict` 三个文件，建议与第 1 部分同名条目合并成一个独立重构提交，不与缺陷修复混在一起。五条轻微（未使用 import、视图 `retain`、公开类型构造器 `internal`、接口冗余参数、Value* 扩展覆盖）与那条堆内存方案都缺基线或属整理性质，按「待验证假设 / 后续整理」处理，不进本轮修复清单。
