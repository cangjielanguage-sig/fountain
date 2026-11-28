# f_collection 模块审查报告（模块第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_collection`（本部分 1 个 `.cj` + 0 个 `.md`，共 1 个文件；第 1 部分为其余 18 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线；`git blame -L 55,83` 全部指向 2026-10-02 `4be871f2f`「统一换行符为 LF（CRLF→LF，1293 个文件）」，再向上只有版权/命名空间类提交，无法归因到功能改动，故全部记为「存量」）
- **审查重点**：集合实现正确性、扩容与并发安全、OOM、栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1

## 发现

### [一般][存量] `ConcurrentHashMap.values()` 返回活视图，`Collection<V>` 契约下 `size`/`isEmpty`/迭代互不自洽，且未声明弱一致语义

- **位置**：`f_collection/src/ValueEqualMap.cj:63-76`（`ConcurrentHashMapValues`：`isEmpty` 65-67、`size` 68-72、`iterator` 73-75 各自直接透传底层 map）、`78-83`（迭代器包装）；触发点 `55-61`（`extend ConcurrentHashMap <: ValueContainsMap/ValueEqualMap`，使 `containsValue` 走这条路径）
- **来源**：存量（快照模式无基线；blame 4be871f2f）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「迭代与修改并发 / 异步语义」
- **证据**：静态确定 —— 三个成员都直接读 `map.size` / `map.isEmpty()` / `map.iterator()`，类内没有任何快照、缓存或锁。而 std 文档已明确这两条语义：`collection_concurrent_class.md:837-839`「`prop size` 此方法不保证并发场景下的原子性」；同文档 `1923-1927`「迭代器不保证迭代结果为某一时刻的快照，也不保证感知环境线程对目标 ConcurrentHashMap 的修改」
- **描述**：`Values<V>` 声明返回 `Collection<V>`，而 `Collection<T>` 的语义是「一个集合」（`core_package_interfaces.md:514-522`：`size` / `isEmpty` / `toArray` / `iterator` 描述同一批元素）。实现返回的是活视图，于是调用方按 `Collection` 直觉写的代码在并发写时会自相矛盾：①`if (v.size > 0) { v.iterator().next().getOrThrow() }` 可能拿到 `None` 抛 `NoneValueException`；②`for (v in values)` 期间新增的值可能被看到也可能不被看到，`containsValue` 的返回值只代表「遍历窗口内某次观察」，不是任一时点的判定；③`size` 与随后 `iterator()` 的元素个数可以不同。这不是数据竞争（底层容器线程安全，见 `collection_concurrent_class.md:799` 的 `ConcurrentHashMap<K, V> <: ConcurrentMap<K, V> & Collection<(K, V)>`），而是**语义契约缺口**：`Collection<V>` 的类型语义暗示这是一批确定元素，实现与文档都没说清弱一致
- **建议**：在 `ConcurrentHashMapValues` 与 `ValueContainsMap.containsValue` 上加类注释/接口注释，写明「并发修改下为弱一致遍历，`size` 非原子，结果不代表快照」；若业务需要稳定结果，补 `func snapshot(): Array<V>`（一次遍历收集）；同时把 `isEmpty()` 统一为 `size == 0` 或明确其非原子性，避免与 `iterator()` 混用

### [一般][存量] README 承诺「所有 Map 实现」都能获得 `containsValue` 扩展，但 `Dict` 家族（本模块自有的 Map 抽象）完全没有扩展

- **位置**：`f_collection/src/ValueEqualMap.cj:43-61`（只有 4 条 `extend`：`HashMap` / `TreeMap` / `LinkedHashMap` / `ConcurrentHashMap`）；缺失侧 `f_collection/src/Dict.cj:20`（`public interface Dict<K, V> <: Collection<(K, V)>`）、`Dict.cj:110`（`func values(): Collection<V>`）、`TreeDict.cj:180`、`HashDict.cj:191`、`LinkedHashDict.cj:176`（三者都实现了 `values()`）
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现 / 能力未接入」、§13「文档与代码不一致」
- **证据**：静态确定 —— 承诺源 `README.md:321`「这是两个接口，**所有Map实现**和ConcurrentHashMap都可以增加这两个接口的扩展」、`README_en.md:322`「every Map implementation and ConcurrentHashMap can be extended with them」；缺失证据：全仓搜 `ValueContainsMap|ValueEqualMap` 仅命中本文件（`grep` 覆盖 `f_*` 全部 `.cj`），`Dict` 家族没有任何 `extend ... <: ValueContainsMap`，也没有手写 `containsValue`
- **描述**：`Dict<K,V>` 是本模块自己的 Map 抽象，`TreeDict`/`HashDict`/`LinkedHashDict` 都实现了它并都提供 `values(): Collection<V>`——正是 `ValueContainsMap` 所需的那一个成员，却拿不到 `containsValue`。以 `Dict` 编程的调用方（本模块与下游）只能手写全表遍历，同一「判断 value 是否存在」的能力出现两套写法；README 的措辞则让人以为 `dict.containsValue(x)` 可用，按文档写会编译失败
- **建议**：优先给 `Dict<K, V>` 本身加 `extend<K, V> Dict<K, V> <: ValueContainsMap<K, V> where K <: Equatable<K>`（是否允许对 interface 类型做 `extend` 需先验证，见下「待确认」）；若语言不允许，对 `TreeDict`/`HashDict`/`LinkedHashDict` 各加一条与 43-53 行同形的 `extend`，并补 `Collection_test.cj` 用例（三个实现各一条 `containsValue` 正/负例）；同时把 README 的「所有 Map 实现」改为精确清单
- **待确认**：仓颉 1.3 是否允许 `extend` 一个 interface 类型并追加父接口。查不到确定结论时按「逐实现类扩展」落地即可，不影响本条的成立

### [轻微][存量] `ConcurrentHashMapValues`/`ConcurrentHashMapValueIterator` 与同包 `MapValues`/`MapValueIterator` 逐行同构，同包内还存在第三种等价写法

- **位置**：`f_collection/src/ValueEqualMap.cj:63-83`（本文件）对比 `f_collection/src/MapKeyValues.cj:85-90`（`MapValueIterator`：`entryIterator.next()?[1]`）、`MapKeyValues.cj:92-141`（`MapValues`：`iterator`/`size`/`isEmpty` 与本文件 65-75 行文本一致）；另一处 `f_collection/src/ExtendCollection.cj:182-184`（`ConcurrentHashMapKeys.iterator()` 用 `map.iterator().map<K> {i: (K, V) => i[0]}`）
- **来源**：存量
- **判据**：review-checklist §2「只改类型名」（同文件间/跨文件函数体逐行对齐）
- **证据**：静态确定 —— 三个成员一一对应且实现文本相同（`map.size` / `map.isEmpty()` / 包装迭代器），迭代器 `next()` 都是 `itr.next()?[1]`。实质差异只有三处：`MapValues` 多一个 `clear()`（会清空父 map 的副作用）、被包装类型不同（`Map<K,V>` vs `ConcurrentHashMap<K,V>`）、`ConcurrentHashMapValues` 未覆写 `toArray()`
- **描述**：同一件事在一个模块里有三种写法：专用迭代器类（`MapValueIterator`）、另一个专用迭代器类（`ConcurrentHashMapValueIterator`）、`Iterator.map` 适配（`ConcurrentHashMapKeys`）。第三种最省代码，且已在同包 `ConcurrentHashMapKeys` 上用开，说明这套代码本身接受 `.map{}` 适配；`ConcurrentHashMapValueIterator` 因此是纯粹的重复实现（`MapValueIterator` 只依赖 `Iterator<(K, V)>`，无泛型约束，可直接复用）
- **建议**：删掉 `ConcurrentHashMapValueIterator`，`iterator()` 改为 `map.iterator().map<V> {i: (K, V) => i[1]}`（与 `ExtendCollection.cj:183` 的 keys 侧写法对齐）；`ConcurrentHashMapValues` 与 `MapValues` 的 `size`/`isEmpty` 若要合并，用一个只依赖「迭代器 + 两个取值闭包」的通用视图，注意不要把 `MapValues.clear()`（清空父容器）带进只读视图

### [轻微][存量] 两个接口的 `containsValue` 默认实现是两份相同的遍历循环

- **位置**：`f_collection/src/ValueEqualMap.cj:26-31`（`ValueContainsMap.containsValue(predicate)`）与 `35-40`（`ValueEqualMap.containsValue(value)`）
- **来源**：存量
- **判据**：review-checklist §2「换控制流/同语义实现」
- **证据**：静态确定 —— 两者都是「遍历 `this.values()`，首个命中即 `return true`，否则 `return false`」，唯一差别是判定条件 `predicate(v)` 与 `v == value`
- **描述**：`ValueEqualMap` 表达的是 `ValueContainsMap` 的一个特例，却平行声明、复制同一段循环。后果是两处语义改动（例如将来要给空集合短路、要加计数、要改成 `any{}`）必须同步改两遍，属典型的重复逻辑导致的行为漂移风险；同时让「同时实现两个接口的类型」出现两个 `containsValue` 重载（`V` 本身是函数类型时调用会产生重载歧义，如 `HashMap<String, (Int64) -> Bool>`）
- **建议**：改为 `public interface ValueEqualMap<K, V> <: ValueContainsMap<K, V> where K <: Equatable<K>, V <: Equal<V>`，并令 `func containsValue(value: V): Bool { containsValue{v => v == value} }`；保留两个入口（对外签名不变），只留一份循环。若担心函数类型 `V` 的重载歧义，可把谓词版改名为 `containsValueIf`

### [轻微][存量] 两个接口的 `K` 类型参数在接口体内完全未使用，只贡献了一条无意义的 `K <: Equatable<K>` 约束

- **位置**：`f_collection/src/ValueEqualMap.cj:25`、`34`（两处 `where K <: Equatable<K>`）；接口体 26-31、35-40 只用 `V`
- **来源**：存量
- **判据**：review-checklist §10（设计合理性）、§1「读了不用」（未参与的声明）
- **证据**：静态确定 —— `ValueContainsMap`/`ValueEqualMap` 的成员只出现 `V` 与 `this.values()`；`K` 仅出现在泛型形参与 `where` 约束中，既不参与任何签名，也不参与判定
- **描述**：这条约束没有任何用途，却会成为扩展 `Dict` 家族（见第 2 条发现）时的新门槛：`Dict<K, V>` 本身对 `K` 无约束，加扩展时被迫写 `where K <: Equatable<K>`，把键不可判等的字典挡在外面，而接口根本不需要键可比较。保留 `K` 的合理理由只有一个——在类型上标注「这是某个 key 类型的 Map 的值视图」，但注释里没有说明
- **建议**：二选一并写注释：①收窄为 `ValueContainsMap<V>` / `ValueEqualMap<V>`（public 契约变更，影响下游 `map.containsValue(...)` 的类型推断，需用户拍板）；②保留 `K` 但删掉 `where K <: Equatable<K>`（`K` 未被使用，约束无意义），并在接口注释写明「`K` 仅用于表达与 Map 的对应关系」

### [轻微][存量] 两个包装器的公开面与文档不匹配：`ConcurrentHashMapValueIterator` 未进 README，二者均无并发语义说明；同族 `ConcurrentHashMapKeys` 却是 internal

- **位置**：`f_collection/src/ValueEqualMap.cj:63`（`public class ConcurrentHashMapValues`）、`78`（`public class ConcurrentHashMapValueIterator`）；文档侧 `f_collection/README.md:486`（「其他公开 API」清单只列了 `ConcurrentHashMapValues`，无 `ConcurrentHashMapValueIterator`，全 README/README_en 零命中该符号）；对照 `f_collection/src/ExtendCollection.cj:155`（`class ConcurrentHashMapKeys`，internal）
- **来源**：存量
- **判据**：review-checklist §1「可见性建议」（硬原则一：对外可达的 public 不判死代码）、§14.2「公开 API 未文档化」
- **证据**：静态确定 —— 全仓搜 `ConcurrentHashMapValues|ConcurrentHashMapValueIterator` 只有本文件定义处、本文件 57/74 行的内部构造，以及 README:486 的名字；没有任何外部构造或按名引用。二者的对外用途都只经由 `values(): Collection<V>` / `iterator(): Iterator<V>` 的接口类型返回
- **描述**：`ConcurrentHashMapValues` 属对外可达的 public 声明，按硬原则一**不算死代码**，但它当前只是 `values()` 的实现细节：仓内零外部使用、README 只有名字、无任何语义说明；同族、同形状的 `ConcurrentHashMapKeys` 则是 internal，可见性策略在同一模块内自相矛盾。晚一步收窄的成本是「已被下游当公开类型使用」，现在改成 internal 只是删掉一个没人用的公开符号
- **建议**：把两个类都改为 internal（`values()` 的返回类型是接口，不影响调用方编译）；若业务上确定要长期公开，则在 README 的 `ValueEqualMap` 段落补「`values()` 返回活视图、并发下弱一致」与 `ConcurrentHashMapValueIterator` 的条目，避免只留一个名字

## 优化可行性方案

> 本部分未提供任何 bench / profile / 堆采样数据，按铁律不产出带收益结论的优化方案。唯一可量化的候选（包装对象分配、`containsValue` 全扫描）已降级写入「待验证假设」。

（本部分：堆内存 0 条 / CPU 0 条）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `containsValue` 在 `ConcurrentHashMap` 上必然是 O(n) 全表遍历（无值索引），若被放在请求主路径高频调用会成为 CPU 热点，且弱一致遍历反复取 `map.iterator()` | `f_collection/src/ValueEqualMap.cj:26-40`、`55-61`、`73-75` | 调用频次、自耗时占比、单次遍历规模 | 在调用点加计数埋点，跑稳态负载后用 `cjprof record` 取 self time 占比；输入 10 万条、并发 8，对照「改用维护反向索引」版本 |
| 2 | 每次 `values()` 调用新建 1 个包装器、每次 `iterator()` 新建 1 个迭代器，在高频调用点带来额外分配与 GC 压力 | `f_collection/src/ValueEqualMap.cj:57`、`74` | 每秒调用次数、分配字节数 | 埋点统计调用次数 + `getAllocatedHeapSize()` 前后差值；`cjprof heap` 看 wrapper 类型占比 |

> 以上不进 `todo.md` / `tasks.md`。取证说明：`~/.autocode/cj`（`CODEBUDDY.md` 里登记的文档根）在本机不存在，std 语义改用手边的 1.3 官方文档副本 `C:/Users/74414/.codebuddy/skills/cangjie-doc-1.3/references/libs/std/**` 核对，引用处均标了文档文件与行号；`Dict`/`MapValues`/`ConcurrentHashMapKeys` 等仓内符号用全仓 grep 取证。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_collection/src/ValueEqualMap.cj` | .cj | ✅ | 83 行全文；5 个公开声明（`Values`、`ValueContainsMap`、`ValueEqualMap`、`ConcurrentHashMapValues`、`ConcurrentHashMapValueIterator`）+ 4 条 `extend` 全部逐条核对；另读了 `MapKeyValues.cj:85-141`、`ExtendCollection.cj:155-191`、`Dict.cj:20/110`、`LinkedHashMap.cj:21/322`、`README.md:319-338/486`、`README_en.md:320-338`、`Collection_test.cj:234-238` 作为对照证据（均属第 1 部分，不计入本部分覆盖数） |

合计：`.cj` 1 个 / `.md` 0 个 / 共 1 个，全部读完（本部分不含任何 `.md`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 命中 1（并发语义契约）、2（能力未接入 `Dict`）、5（冗余类型参数与无意义约束）；安全性已核：无外部输入、无注入面、无凭据、无日志泄露；语言特性已核：`Equal<T>` 只提供 `==`（`core_package_interfaces.md:878-884`），故 `V <: Equal<V>` 足以支撑 `v == value`，非误用 |
| §1 死代码 | 0 | 本文件无 `private`/`internal`/`protected` 声明；5 个公开声明全部对外可达（顶层 public、嵌套链无阻断），按硬原则一不判死代码；无 `return`/`throw`/`break`/`continue` 后续语句、无恒真恒假分支、无未使用局部变量、无未使用 `import`（第 18-19 行两条 `public import` 导出的 3 个类型 `HashMap`/`TreeMap`/`ConcurrentHashMap` 均在 43-61 行被使用）；`K` 的冗余归入设计条目而非死代码。可见性问题单列第 6 条 |
| §2 重复逻辑 | 2 | 命中 3（包装器/迭代器三处同构）、4（两份 `containsValue` 循环）；已把 6 个函数体压成「输入→输出→副作用」摘要两两比对：`isEmpty`/`size`/`iterator`/`next` 与 `MapValues` 侧逐行一致，`containsValue` 两份只差判定式 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`、无 `throw UnsupportedException`；两个接口默认实现都是完整逻辑（26-31、35-40），4 条 `extend` 的空体是「复用类型已有成员 + 接口默认实现」，非空实现 |
| §4 栈溢出 | 0 | 全文件无递归、无自引用结构、无深度遍历；`next()` 只对底层迭代器做一次取值 |
| §5 OOM | 0 | `values()` 不物化数据（仅 1 个包装对象，惰性迭代）；无按不可信长度预分配、无无界容器、无全量任务提交。`toArray()` 未覆写，走 `Collection` 的默认实现（否则该文件无法通过编译）；默认实现的具体写法未在 std 文档展开，故不据此推断其并发行为，规模上界仍受 map 自身大小约束 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench / 分段计时数据，热点不成立；`containsValue` 的全扫描成本已列入待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 本文件无任何锁、`synchronized`、原子类型；`ConcurrentHashMapValues` 无线程共享锁对象 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无批处理窗口；单次 `containsValue` 为单线程顺序遍历 |
| §6.4 低效算法 | 0 | `containsValue` 为 O(n) 单层遍历，这是「按值查 Map」的固有下界（无值索引），不构成低效实现；无嵌套循环、无循环内 `contains`/`remove(at: 0)`/字符串拼接 |
| §7 降堆内存方案 | 0 | 仅有的可减项是每次 `values()`/`iterator()` 的包装对象（2 个短生命周期对象），无基线无法量化收益，降级为待验证假设 #2 |
| §8 降 CPU 方案 | 0 | 同上；无基线不得写成结论 |
| §9 local mode 可行性 | 0 | 无函数内临时大对象（包装器只持有一个 map 引用）；收益无法用峰值内存证明，且 `Collection`/`Iterator` 返回的对象必然逃逸，local mode 不成立 |
| §11 现有代码的 BUG（存量） | 1 | 逐条核对了 2 个默认方法、4 条 `extend`、3 个包装器成员、1 个迭代器 `next()` 的边界与空值：`next()` 用 `?` 正确传播 `None`（81 行），`v == value` 的约束成立。唯一存量缺陷为弱一致语义未声明（发现 1） |
| §12 并发安全与锁粒度 | 1 | 已核共享路径：`ConcurrentHashMapValues` 的 `private let map` 只读不可变，包装器无其它字段，两个 `containsValue` 无共享可变状态 → **无数据竞争**；并发正确性完全依赖 `ConcurrentHashMap` 自身线程安全（`collection_concurrent_class.md:799`）。命中的 1 条是弱一致语义（发现 1），非锁粒度问题；本文件无锁可谈粒度 |
| §14 功能完备性与 README 覆盖 | 2 | 命中 2（README 承诺「所有 Map 实现」但 `Dict` 家族缺扩展）与 6（`ConcurrentHashMapValueIterator` 未进 README、两个包装器无并发语义说明）。已逐项把本文件 5 个公开声明与 README 对照：`Values`/`ValueContainsMap`/`ValueEqualMap` 的签名与 README.md:319-338、README_en.md:320-338 一致，`ConcurrentHashMapValues` 仅在 README:486 名单中出现 |
| 文件覆盖（§13 等） | 1/1 | `files/f_collection.part2.txt` 仅 1 行，已读完；本部分无 `.md`，`.md` 一致性只在「本文件 API 与 README 对照」范围内核对（README 本身归第 1 部分） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分只有 `ValueEqualMap.cj`（83 行），是一层「给 Map 补 `containsValue`」的薄扩展：2 个接口 + 4 条 `extend` + 1 组并发 map 的值视图包装。**没有严重问题**——无递归、无预分配、无锁、无数据竞争、无空实现、无不可达代码；5 个公开声明全部对外可达（其中 `ConcurrentHashMapValueIterator` 未进 README，见第 6 条）。

主要风险集中在两处「说与做不一致」：一是 `ConcurrentHashMap.values()` 返回活视图，却被 `Collection<V>` 的类型语义包装成「一个集合」，并发写时 `size`/`isEmpty`/迭代会互相矛盾（std 文档已声明 size 非原子、迭代器非快照，本文件既未覆写也未注释），调用方极易写出 `size > 0` 之后 `next().getOrThrow()` 崩溃的代码；二是 README 承诺「所有 Map 实现」都能获得 `containsValue`，而本模块自己的 `Dict`/`TreeDict`/`HashDict`/`LinkedHashDict`（都已实现 `values()`）一个都没扩展，按文档写会编译失败。这两条属一般级、可排期修，均为存量。

其余 4 条是重复与收窄问题：包装器/迭代器与同包 `MapValues`/`MapValueIterator` 逐行同构（同包还已有 `Iterator.map` 的第三种写法）、两份 `containsValue` 循环可合并为继承、`K` 类型参数及其约束无意义、两个包装器的可见性与 README 登记不一致。它们不影响当前行为，但会放大后续维护成本，建议随下一次接口调整一起做。

存量问题共 6 条（一般 2 / 轻微 4），是否纳入修复待用户决定；本部分无本次改动引入的问题（快照基线）。模块整体风险以第 1 部分为主（该部分报出并集视图恒空、`BitSet.set` 不置位、`BitSet.&` 抹掉同字其余位、`LinkedHashMap.remove(all!)` 不摘链等 6 条严重缺陷），合并时请以两部分合计口径出模块结论。唯一测试覆盖参考：`Collection_test.cj:234-238` 只验证了 `HashMap.containsValue(3)` 一条，`ConcurrentHashMap` 值视图、谓词重载、`Dict` 家族均无用例。
