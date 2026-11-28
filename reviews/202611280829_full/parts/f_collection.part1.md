# f_collection 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_collection`（19 个源文件；本部分覆盖 15 个 `.cj`）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，`git status` 除 `docs/review/`、`reviews/` 外干净；无 diff → 本部分全部为存量）
- **审查重点**：集合/字典实现正确性、迭代器失效、扩容策略、并发安全、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（第 1/2 部分，供主 Agent 合并为 `docs/review/f_collection_review_20261128.md`）
- **本部分文件**：`BitSet.cj`、`Collection_test.cj`、`Dict.cj`、`DifferenceSetView.cj`、`ExtendCollection.cj`、`GrowSizePolicy.cj`、`Growable.cj`、`HashDict.cj`、`IntersectionSetView.cj`、`LinkedHashDict.cj`、`LinkedHashMap.cj`、`LinkedHashSet.cj`、`LinkedNode.cj`、`MapKeyValues.cj`、`PriorityQueue.cj`
- **不在本部分**：`SetOp.cj`、`TreeDict.cj`、`UnionSetView.cj`、`ValueEqualMap.cj`、`README.md`、`README_en.md`（第 2 部分）

## 发现

### [严重][存量] `BitSet.set(value)` 对未置位的 bit 永久失效

- **位置**：`src/BitSet.cj:82-101`（关键分支 `88`）
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02，换行符统一提交引入，全文件同源）
- **判据**：review-checklist §11（语义与命名不符 / 逻辑错误）、§10 正确性
- **证据**：静态确定 —— 第 88 行 `if (let i <- computePosition(h) && (bits[idx] & i) != 0)` 中 `let i <- expr` 是不可反驳 let 模式（仓内同类写法见 `f_cmd/src/CmdArgs.cj:47`、`f_io/src/BytePointerStream.cj:90`，恒为真），条件退化为"该 bit 已经是 1"。于是 `set(value)` 只在 bit 已为 1 时才进入分支，`bits[idx] |= i` 是自我赋值，返回值恒 `false`；未置位的 bit 永远进不去 `else` 的写入路径。
- **描述**：`public func set<T>(value: T): Bool`（`BitSet.cj:99`）作为"按 Hashable 加入元素"的对外 API 完全不生效：`bs.set(x)` 返回 false 且 `bs.contains(x)` 仍为 false。`remove(value)`（`102-104`）借用同一实现，反而正常（bit 为 1 时能清 0），所以不对称的失败更难被发现。`Collection_test.cj:218-233` 只测了下标运算符，未覆盖这条路径。
- **建议**：条件改为 `if ((bits[idx] & i) != 0)` 之外再补写入分支，即
  `if (store) { if (bits[idx] & i) == 0 { bits[idx] |= i; return false } else { return true } }`；
  并补 `set/remove/contains` 三元组用例（含重复 set、set 后 remove）。

### [严重][存量] `LinkedHashMap.remove(all!)` 只删哈希表不摘链表，产生幽灵条目并可能死循环

- **位置**：`src/LinkedHashMap.cj:257-259`；受影响调用方 `src/LinkedHashDict.cj:125-128`、`src/LinkedHashSet.cj:85-87`
- **来源**：存量（`git blame` 命中 `4be871f2fd`；该行自首次入库未改动）
- **判据**：review-checklist §11（数据不一致 / 死循环）、§5（无界增长）、§10 正确性
- **证据**：静态确定 —— `remove(all:)` 直接调 `map.remove(all: all)`（std `HashMap`），未对每个 key 取 `ValueNode` 调 `n.remove()`；而 `remove(key)`（`248-251`）与 `removeIf`（`265-273`）都会摘链。`size` 取自 `map.size`（`64-68`），链表长度不再与之一致。
- **描述**：三条后果都由同一根因派生：
  1. `iterator()`（`93-95`）沿链表遍历，会继续产出已删除的 key/value（幽灵条目）；
  2. `firstEntry`/`lastEntry`/`pollFirstEntry`/`pollLastEntry`（`172-206`）取到幽灵节点，`pollFirstEntry` 的 `delete(entry, removeMap: true)` 再删一次 `map.remove(n.value[0])` 得到 `None`，链表与表彻底错位；
  3. 容量淘汰循环 `add`（`216-227`）`while (max && s > 0 && s >= size_ && !this.contains(key))` 中，若 `head.next` 是幽灵节点，`remove(n.value[0])` 返回 `None`、`delete` 什么都不摘，`s = size` 不变 → **死循环**（先 `remove(all:)` 清掉一批 key，再填满到 `size_` 后插入新 key 即可触发）。
- **建议**：`remove(all!)` 改为逐个 `remove(key)`（或在链表侧遍历并摘链）；补 `remove(all:)` 后"size == 迭代次数"与"再插入到容量上限"的回归用例。

### [严重][存量] `ExtendMap.retain(c)` 遍历方向反了，实际是空操作

- **位置**：`src/ExtendCollection.cj:55-59`
- **来源**：存量（快照模式无基线；`git blame` 指向 `4be871f2fd`）
- **判据**：review-checklist §3（公开契约承诺有行为、实现为空）、§11（契约与实现不符）
- **证据**：静态确定 —— 实现为 `for (k in c where !contains(k)) { remove(k) }`：遍历的是**入参** `c`，只对"`c` 里但本 map 里没有"的 key 调 `remove`，而这类 key 本来就不存在，`remove` 必然 no-op。
- **描述**：`ExtendMap` 被 `HashMap`（`105`）、`TreeMap`（`107`）、`LinkedHashMap`（`121`）、`ConcurrentHashMap`（`123`）四个 extend 继承，因此这四类容器的 `retain(c)` 全部静默失效；对照 `ExtendList.retain(set)`（`30-32`）明确是"只保留 set 内元素"，Map 侧契约应为"只保留 key 在 c 内的条目"。调用方会以为剪枝完成，实际条目一个没少（内存与语义双失）。
- **建议**：改为遍历自身键空间：`for (k in keys() where !c.contains(k)) { remove(k) }`（`ConcurrentHashMap` 需按段弱一致遍历，避免遍历中改容器）；补"retain 后 size/内容"用例。

### [严重][存量] `BitSet` 用 `hashCode()` 当 bit 下标且无上限校验，单次调用即可 OOM

- **位置**：`src/BitSet.cj:44-58`（`growIfNeed`）、`79-104`（`contains`/`set`/`remove`）、`123-136`（`[]=`）
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §5（按不可信长度预分配 / 无界容器）、§11
- **证据**：静态确定 —— `growIfNeed(index, grow)` 用 `idx = (index / 64).toInt()` 后 `Array<UInt64>(idx - bits.size + 1, repeat: 0)` 一次性补足到目标下标，**没有任何上限判断或拒绝路径**。
- **描述**：
  - `set/remove/contains<T>(value: Hashable)`（`79-104`）把 `value.hashCode()` 直接当 bit 下标：仓颉字符串等类型的 hashCode 落在 31 位量级，`h ≈ 2^31` → 需要 3.3e7 个 `UInt64` ≈ **256 MB**，一次 `bs.set(someString)` 就可能吃掉数百 MB；若 hashCode 为负，`toUInt()` 后 ≈`2^64`，`idx ≈ 2^58` → 申请 `2^58 × 8 B` 直接 OOM 崩溃。
  - 显式下标同理：`bs[1_000_000_000_000] = true` 申请约 125 GB；`bs[-1] = true`（`Int64` 负数 → `toUInt`）必定崩溃。
  - 另有一处语义缺陷：`contains(value)` 只比较 hashCode 对应的 1 个 bit，**哈希碰撞即误报**（不同对象同 hash 会互相"存在"）。
- **建议**：`contains/set/remove(Hashable)` 不应复用"按 hash 定址"的位图语义，改为 `HashSet` 实现或删除这组重载；位图下标入口加 `maxIndex` 上限（构造参数/常量）并抛明确异常；`[]=` 对负数下标显式拒绝。

### [一般][存量] `firstEntry()` 是读接口却改链表序，`LinkedHashSet.first` 因此带副作用

- **位置**：`src/LinkedHashMap.cj:172-183`（`turnToTail(e)` 在 `179`）；`src/LinkedHashSet.cj:94-98`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符）、§10 正确性
- **证据**：静态确定 —— `firstEntry()` 取到首节点后调 `turnToTail`，把"第一个"移到队尾再返回；`lastEntry()`（`192-198`）不动链表。`get(key)`（`110-122`）默认 `turn=true` 也会重排。
- **描述**：`firstEntry` 名义是查询，实际每次调用都在旋转顺序：对 `LinkedHashSet`，`set.first` 一次读取就会改变后续迭代顺序与 LRU 淘汰顺序；在遍历中调用还会让已访问节点被搬到尾部而**被重复访问**。与 `lastEntry` 行为不对称，说明大概率是误抄 `get` 的维护逻辑。
- **建议**：`firstEntry` 去掉 `turnToTail`；若确实需要"访问即置尾"，另开 `getFirstEntry(access!)` 并在注释里写明。

### [一般][存量] `LinkedHashMap.get` 是写操作，类未声明非线程安全，共享只读也不安全

- **位置**：`src/LinkedHashMap.cj:110-122`、`96-101`（`turnToTail`）、`23-24`（`head`/`tail` 普通字段）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护、迭代与修改并发）
- **证据**：静态确定（给定共享）—— `get` → `turnToTail` → `Node.turnTo` 会写 `prev`/`next` 四五个指针（`LinkedNode.cj:200-216`），`head.next`/`tail.prev` 也跟着改；这些字段没有任何同步或原子化。仓内已知证据：`f_cache/src/SyncLinkedHashMap.cj:28` 的注释明确写着"`get` 经 LinkedHashMap.get 维护 LRU 链表序（turnToTail 写链表指针），本身就是写操作"。
- **描述**：两个线程同时对同一个 `LinkedHashMap` 调 `get`（哪怕没有任何写入意图）就会并发写链表指针，可能形成环（`turnTo` 先 `remove()` 再插入，中间态对外可见）→ 迭代器死循环/丢节点。类上没有"非线程安全 / 需外部加锁"的说明，使用者很容易把它当只读容器共享。当前仓内调用方（`SyncLinkedHashMap`、`SyncPriorityQueue`）都自行加了锁，所以这是"契约未声明"而非现存数据竞争。
- **建议**：在类注释声明"非线程安全，且 `get` 会修改内部链表序，读也需外部同步"；如要支持并发读，可提供不重排的 `peek`/`getNoTouch` 或读时只维护近似序（`Atomic` 时间戳）。

### [一般][存量] `LinkedHashSet.==` 依赖遍历顺序，同元素不同插入序判不等

- **位置**：`src/LinkedHashSet.cj:112-127`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§10 正确性
- **证据**：静态确定 —— `==` 同时推进两个迭代器逐位比较（`122-124`），最后以 `i == this.size` 收尾；两个集合 `{1,2}` 与 `{2,1}` 元素相同但 `==` 返回 false。另外约束写成 `T <: Comparable<T>`，比 `Set<T>` 需要的 `Equatable` 更强。
- **描述**：`Set` 的相等语义应与顺序无关；当前实现把"插入序"变成相等性的一部分，放进 `HashMap` 当 key、或做断言/去重比较时结论会反直觉。
- **建议**：改为"大小相等且 `other.contains(all: this)`"，或把顺序敏感比较改名 `sameOrder`；泛型约束收窄回 `Equatable`。

### [一般][存量] 链表迭代器无失效检测，节点自指会让迭代原地死循环

- **位置**：`src/LinkedNode.cj:39-54`（`next`）、`154-168`（`ValueNode.remove` 末尾 `this.prev = this; this.next = this`）；`src/LinkedHashMap.cj:93-95`
- **来源**：存量
- **判据**：review-checklist §12.1（迭代与修改并发）、§11（无界循环）、§10 正确性
- **证据**：静态确定 —— `next()` 返回当前节点值后把 `current` 置为 `n.next`；若该节点在两次 `next()` 之间被删除，`remove()` 已把 `n.next` 写成 `n` 自身，于是 `current` 又指回自己，`next()` 无限返回同一个值。`LinkedHashMap` 没有 `modCount`/版本号，也不检查链表结构是否被改。
- **描述**：`for ((k, v) in map) { map.remove(k) }`、或在遍历回调里调用任何写接口（含 `firstEntry`/`get` 的重排），都可能出现重复元素、跳过元素乃至死循环。`iterator().remove()` 本身是安全的（先取 next 再摘链），问题只在"外部修改"这条路径，而没有任何检测或文档约束。
- **建议**：加 `modCount`，迭代器构造时快照、每次 `next()` 校验并抛 `ConcurrentModificationException`；或在 `ValueNode.remove()` 里保留 `prev/next` 指向真实邻居（自指只是为 GC 取巧，代价是这类不可诊断的死循环）。

### [一般][存量] `PriorityQueue` 超过 capacity 后每次 `add` 都触发全量扩容拷贝

- **位置**：`src/PriorityQueue.cj:103-113`（`add`）、`130-148`（`grow`）；`src/GrowSizePolicy.cj:22-25`
- **来源**：存量（`grow` 的死循环修复见 `5c76cb466`，但容量判定逻辑未改）
- **判据**：review-checklist §6.4（已知规模仍反复扩容复制）、§11（扩容策略缺陷）
- **证据**：静态确定 —— `add` 的判据是 `capacity > 0 && size >= capacity`，而 `capacity` 是构造期 `let`（`51`），`grow()` 只改 `queue` 数组、不改 `capacity`。于是走 `overSizePolicy`（如 `GrowSizePolicy.reject` → `o.grow(); fn()`）后，size 仍 ≥ capacity，**下一次 add 会再次 grow**；`grow` 的目标是 `currentSize * 2`，每次都是"新建数组 + 全量拷贝"。
- **描述**：`capacity: 3` 的队列加到 n 个元素，会做约 n 次 `grow`，累计拷贝 O(n²)；且 `grow()` 以 `currentSize*2` 而非 `queue.size*2` 为目标，在"元素被大量 remove 后再 add"的场景会把数组**缩小**（如 16 → 2），下一次 add 再翻倍，形成抖动。`GrowSizePolicy` 因此不仅是无效扩容，还把插入退化成平方级。
- **建议**：把"软容量"与"数组容量"分开：扩容后同步更新 `capacity`（或判定用 `queue.size`），`grow()` 以 `max(queue.size*2, currentSize+1)` 为目标；`add` 直接 `doOffer`，由 `doOffer` 的 `isFull()` 统一决定是否扩容。

### [一般][存量] 用 `Collection.size` 预分配数组再用迭代器取值，长度不一致即抛异常

- **位置**：`src/ExtendCollection.cj:186-190`（`ConcurrentHashMapKeys.toArray`）、`src/HashDict.cj:140-143`、`src/LinkedHashDict.cj:125-128`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失）、§12.1（并发下 size 与迭代不一致）
- **证据**：静态确定 —— `Array<K>(size){_ => itr.next().getOrThrow()}` 把"取 size 时刻的元素数"当成循环次数；`ConcurrentHashMap` 明确允许并发增删（`ExtendCollection.cj:123-154` 的实现本身就在并发上下文中使用），size 与迭代产出的条数可以不同 → 多则抛 `NoneValueException`，少则截断。`HashDict.remove(all!)`/`LinkedHashDict.remove(all!)` 同样先按 `all.size` 建数组再 `keys.next().getOrThrow()`，入参若是惰性/并发容器即崩。
- **描述**：`toArray` 是 `Collection` 的公开契约，并发 map 上调用会随机抛异常，属于"读操作把正常并发当错误"。
- **建议**：改为 `ArrayList` 累积后 `toArray()`（或先取 `iterator()` 再 `while (let Some(x) <- itr.next())` 收集），不要用 size 做循环上界；`remove(all!)` 直接 `for (k in all) { remove(k) }`，省掉中间数组。

### [一般][存量] `LinkedHashMap.clone()` 丢失容量与 max 配置

- **位置**：`src/LinkedHashMap.cj:287-289`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `clone()` 走 `LinkedHashMap<K, V>(this)` → `init(c: Collection)`（`38-43`）固定 `max = false`、`size_ = c.size`；原对象的 `max`/容量（`33-37` 构造的参数）不会被复制。
- **描述**：对一个 `LinkedHashMap(3, true)`（3 容量 LRU）clone 后得到无界 map，后续 `add` 不再淘汰；依赖容量上限的调用方会拿到行为不同的副本。
- **建议**：`clone()` 用 `LinkedHashMap<K, V>(this, size_, max)`（`44-49` 已有该构造），或显式注释"clone 不保留上限"。

### [一般][存量] 重复逻辑：`HashDict` 与 `LinkedHashDict` 整套同构（仅底表类型不同）

- **位置**：`src/HashDict.cj:35-311` ↔ `src/LinkedHashDict.cj:20-296`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 跨文件复制）
- **证据**：静态确定 —— 逐段对齐后仅 `HashMap` ↔ `LinkedHashMap`、以及 `LinkedHashDict` 多一组带 `max` 的构造（`33-42`）不同；`HashDictIterator`/`LinkedHashDictIterator`（`HashDict.cj:231-239` ↔ `LinkedHashDict.cj:216-224`）、`HashKeyIterator`/`LinkedHashKeyIterator`（`287-295` ↔ `272-280`）、`HashKeyCollection`/`LinkedHashKeyCollection`（`240-286` ↔ `225-271`）、`HashKeyMapEntryView`/`LinkedHashKeyMapEntryView`（`296-311` ↔ `281-296`）四组内部类型逐行一致。
- **描述**：已经出现行为漂移：`remove(all!)` 里同一段"按 size 建数组 + 迭代器取 key"在两边各写一遍（`HashDict.cj:141-142`/`LinkedHashDict.cj:126-127`），任何一侧修复都容易漏另一边；构造器集合也不一致（`HashDict` 没有 `max` 语义）。
- **建议**：抽一个 `AbstractHashDict<K, V, M> where M <: Map<HashKey<K>, V>`，由子类只提供 `newMap()`；或至少把四组迭代器/视图合并成泛型一份（`HashKeyIterator` 已只依赖 `Iterator<HashKey<K>>`，可直接复用）。

### [一般][存量] 重复逻辑：`DifferenceSetView` 与 `IntersectionSetView` 除一处取反外完全同构

- **位置**：`src/DifferenceSetView.cj:18-143` ↔ `src/IntersectionSetView.cj:18-147`
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 只改类型名）
- **证据**：静态确定 —— 两个迭代器只差 `where !set.contains(e)` 与 `where set.contains(e)`（`DifferenceSetView.cj:21` ↔ `IntersectionSetView.cj:21`）；`contains`/`subsetOf`/`contains(all!)`/六个空 mutator/`retain`/`clone` 结构完全一致，差异仅在 `iterator()`（Intersection 会选较小的驱动集合，`33-39`）与 `contains` 的双向判断。
- **描述**：两份约 145 行的视图各维护一遍，`retain` 的无用分配（见下条）也是成对复制；后续修改极易只改一份。
- **建议**：抽 `SetFilterIterator<T>(itr, pred)` 与一个 `AbstractSetView<T>` 承载只读语义，两个视图只传谓词（`e => set2.contains(e)` / `!set2.contains(e)`）。

### [一般][存量] 重复逻辑：`entryView` 系列默认实现三处同语义、命名还不统一

- **位置**：`src/Dict.cj:130-164`、`src/ExtendCollection.cj:61-102`、`src/ExtendCollection.cj:108-118`
- **来源**：存量
- **判据**：review-checklist §2（同语义不同名 / 跨文件复制）
- **证据**：静态确定 ——
  - `Dict.removeIf(key, predicate)`（`156-164`）与 `ExtendNonConcurrentMap.removeIf(key, predicate)`（`94-102`）函数体逐行一致；
  - `Dict.addIfAbsent(key, fn)`（`136-145`）与 `ExtendMap.computeIfAbsent`（`61-69`）同语义（"缺失才计算并写入"），但一个走 `entryView` 手写分支、一个走 `entryView(fn)` 回调；
  - `Dict.addIfPreset`（`146-155`）与 `ExtendMap.computeIfPresent`（`70-78`）同语义不同名（`Preset` 应为 `Present`）；
  - `TreeMap.entryView`（`108-118`）复制了 `ExtendNonConcurrentMap.entryView`（`88-93`）的流程，只把 `entry.key/entry.value` 换成 `key/this.get(key)`。
- **描述**：四个类型（`Dict` 的实现类与 `HashMap`/`TreeMap`/`LinkedHashMap`/`ConcurrentHashMap`）分别暴露两套命名（`addIfAbsent`/`computeIfAbsent`、`addIfPreset`/`computeIfPresent`），使用者要么猜，要么两套都用；`removeIf` 两份实现将来修一处必漏一处。`TreeMap` 那份额外实现是为了绕开 `TreeMapEntryView` 的 `NoneValueException`（`110` 的 todo），说明差异确有原因，但应把原因参数化而不是整段复制。
- **建议**：`Dict` 直接复用 `ExtendMap` 的默认方法（或在 `Dict` 里委托 `entryView` 只留一份）；统一命名为 `computeIfAbsent/computeIfPresent`，旧名保留为 `@Deprecated` 转发；`TreeMap` 的取 value 方式作为 `entryView` 的一个 `safeValue` 参数而不是覆盖整个方法。

### [一般][存量] 三个已损坏的公开 API 没有回归用例

- **位置**：`src/Collection_test.cj:218-233`（`testBitSet`）、全文无 `remove(all:` 用例
- **来源**：存量
- **判据**：review-checklist §3/§14（覆盖不足掩盖失效实现）、§11
- **证据**：静态确定 —— 全仓搜 `bs.set(`/`\.set\(` 无调用；搜 `remove(all` 在 `f_collection/src/Collection_test.cj` 无命中；`Collection_test.cj:218-233` 只验证下标运算符 `[]`、`|`、`^`、`&`，没有验证 `set(Hashable)`、`remove(all:)`、`retain`。
- **描述**：`BitSet.set(value)` 恒 false、"`LinkedHashMap/LinkedHashSet.remove(all:)` 留幽灵节点"、"`ExtendMap.retain` 空操作"三处严重缺陷都因无用例而长期存在；`testPriorityQueueDiscard`（`154-164`）还把默认容量 16 写死（`@Assert(16, queue.size)`），`DEFAULT_CAPACITY` 一改用例即假失败。
- **建议**：补 `BitSet.set/remove/contains` 三元组、`LinkedHashMap.remove(all:)` 后 size==迭代数、`retain` 后内容、`PriorityQueue` 超容量 10 倍插入的用例；`testPriorityQueueDiscard` 用 `queue.size` 与显式 `capacity: 16` 对齐。

### [轻微][存量] 死代码：`MapValues.clear()` 不可达且全仓无调用

- **位置**：`src/MapKeyValues.cj:132-134`
- **来源**：存量
- **判据**：review-checklist §1（非公共顶级声明里的 `public` 成员，全项目无使用即死代码）
- **证据**：静态确定 —— `class MapValues`（`92`）是包内类型；它只经 `LinkedHashMap.values(): Collection<V>`（`LinkedHashMap.cj:322-324`）对外暴露，声明类型是 `Collection<V>`，而 std `Collection<T>` 只有 `size`/`isEmpty`/`toArray`（`std/core/core_package_api/core_package_interfaces.md:531-536`，已现场核对），没有 `clear`。全仓搜 `MapValues` 只命中定义与 `LinkedHashMap.cj:323` 的构造，无 `.values().clear()` 调用 → `clear` 不可达。另注：它清的是**整个原 map**，不是"值视图"，语义本身就危险。
- **建议**：删除；若确实需要"清空 map"，在 `LinkedHashMap.clear()` 上暴露。

### [轻微][存量] 视图 `retain(all!)` 创建新视图后丢弃，纯属无用分配

- **位置**：`src/DifferenceSetView.cj:133-135`、`src/IntersectionSetView.cj:137-139`
- **来源**：存量
- **判据**：review-checklist §1（读了不用/空洞语句）、§3（无效果实现）
- **证据**：静态确定 —— 方法体只有 `IntersectionSetView<T, Set<T>>(this, all)` 一条表达式语句，构造结果没有赋给字段也没有返回（返回类型 `Unit`）。
- **描述**：每次调用都分配一个视图对象后立即丢弃；对只读视图而言 `retain` 本来就不该改变任何状态，这两行既无效果又误导读者以为"视图被收窄了"。两处同名方法还都用了 `IntersectionSetView`（`DifferenceSetView` 里也是）。
- **建议**：方法体改为 `()` 并加注释说明只读视图不支持收窄；或在注释里明确"应改用 `a.difference(b).intersection(c)` 组合"。

### [轻微][存量] `BitSet.size` 返回分配位数、迭代器产出全部位（含 false）

- **位置**：`src/BitSet.cj:44-51`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符）、§10 可读性
- **证据**：静态确定 —— `size` = `bits.size * 64`（已分配 word 数 × 64），不是置位个数；`iterator()` 逐位返回 `?Bool`，`bs[21324]=true` 后遍历会产出 21325 个 `Bool`，其中 21324 个是 `false`。
- **描述**：名字与 `Collection.size`（元素个数）冲突，而类型只实现 `Iterable<Bool>`；用 `for (b in bs)` 统计元素或按 `size` 预分配都会得到错误规模。`init(capacity:)` 时 `size` 还为 0（`ArrayList(capacity)` 只给容量），同一 prop 在两种构造下含义也不一致。
- **建议**：改名为 `capacityBits`，另加 `cardinality()`（可用 `popcount`）与 `clear()`；`iterator()` 若要保留逐位语义，在类注释写清"产出的是位序列而非元素集合"。

### [轻微][存量] `BitSet` 的 `|`/`&` 语义无文档，且"读"路径也会扩容

- **位置**：`src/BitSet.cj:143-149`（`|`）、`159-166`（`&`）
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 必要注释）、§11（语义与命名不符）
- **证据**：静态确定 —— `|` 返回"操作前该位是否为 1"（`r == val`），`&` 把整个 word 覆盖为 `val & mask`（同 word 其余 63 位被清零）。两者都调 `growIfNeed(index, grow: true)`，同时 `^`（`180-190`）也返回旧值。
- **描述**：`bs & i` 看起来像"与一个位图相与"，实际是"与单元素集合 `{i}` 求交"；若按前者理解会静默清掉同 word 的其它位。三个运算符都返回旧状态，但只有 `^` 有注释（`170-172`）。另外只读式调用也会分配/扩容，和 `[]` 读取不扩容的行为不一致。
- **建议**：给 `|`/`&` 补注释（"把集合与 `{index}` 求并/交，返回操作前状态"）；`&` 若不需要扩容，用 `grow: false` 并在越界时返回 false。

### [轻微][存量] `Dict` 文档残留乱码行、关键方法无注释，`addIfPreset` 拼写错误

- **位置**：`src/Dict.cj:44-45`（注释里孤立的 `120`）、`58-61`（`addIfAbsent(key,value)`/`replace` 无任何说明）、`146`（`addIfPreset`）
- **来源**：存量（同一段 `120` 在 `HashDict.cj:99`、`LinkedHashDict.cj:84` 各复制了一份，见 §2 字面量复制）
- **判据**：review-checklist §13（文档与代码一致性）、§10 可读性
- **证据**：静态确定 —— `Dict.cj:45` 是缩进 11 个空格的 `120`，破坏了 `add(key,value)` 的 KDOC；`addIfAbsent(key, value): ?V`、`replace` 完全无注释，而接口里其余方法都有；`addIfPreset` 应为 `Preset`→`Present`。
- **建议**：删除 `120` 三处；补 `addIfAbsent/replace` 注释（尤其返回值语义：旧值 vs 新值）；`addIfPreset` 改名并保留转发。

### [轻微][存量] `LinkedHashSet` 同时提供 `retain` 与 `retainAll`，两者实现重复

- **位置**：`src/LinkedHashSet.cj:71-73`、`91-93`
- **来源**：存量
- **判据**：review-checklist §2（同语义重复）、§10 API 设计
- **证据**：静态确定 —— `retain(all!)` = `map.removeIf {k,_ => !all.contains(k)}`，`retainAll(elements)` = `removeIf {v => !elements.contains(v)}`，语义与实现路径完全相同，仅参数名与调用层次不同（一个走 map、一个走自身 `removeIf`）。
- **建议**：保留 `Set` 接口要求的 `retain`，`retainAll` 改为转发并标 `@Deprecated`，或直接删除（本仓无调用）。

### [轻微][存量] `BitSetIterator` 是公开类型但构造器包内可见，`GrowSizePolicy`/视图带幽灵类型参数

- **位置**：`src/BitSet.cj:20-29`；`src/GrowSizePolicy.cj:20`；`src/DifferenceSetView.cj:30`、`src/IntersectionSetView.cj:30`
- **来源**：存量
- **判据**：review-checklist §1（可见性建议，非死代码）、§10 API 设计
- **证据**：静态确定 —— `class BitSetIterator` 无 `public` 修饰、`BitSetIterator(...)` 构造器无修饰，外部既不能命名（顶层非 public）也无法构造，实际只经 `Iterator<Bool>` 使用；`GrowSizePolicy<T, C>` 的 `T` 在类型体中从未出现（`where` 只用到 `C <: Growable`），调用方必须写 `GrowSizePolicy<Int64, PriorityQueue<Int64>>()`（`Collection_test.cj:189`）；两个 SetView 的 `C` 同样是幽灵参数。
- **建议**：`BitSetIterator` 收成 `internal`/私有；`GrowSizePolicy<C>` 去掉 `T`（破坏性但本仓只有一处调用）；视图去掉 `C`（`SetOp.cj` 的四处构造随之简化，属第 2 部分范围）。

## 优化可行性方案

### [堆内存] `LinkedHashMap` 每个条目三个对象，可用"值内联 + 节点复用"降占用

- **现状**：每个 entry = `HashMap` 条目（`HashKey` 不适用此处，是 `K`+节点引用）+ 一个 `ValueNode<(K,V)>` + 一个装箱的 `(K,V)` 元组；删除时旧节点直接被丢弃（`LinkedHashMap.cj:216-227` 每次覆盖都 `insertPrev` 新节点再 `delete(old)`），替换 N 次同一 key 会产生 N+1 个节点对象。
- **方案**：`ValueNode` 直接持有 `K`/`V` 两个字段（省掉元组对象）；`add` 命中已存在 key 时复用旧节点（`n.value = (k, v); turnToTail(n)`），不新建节点。
- **预期**：每 entry 少 1 个对象（约 24-32 B）；高频覆盖场景节点分配量降到 O(1) 每 key。
- **代价**：`ValueNode` 泛型从 `T` 变 `<K, V>`，`LinkedNode.cj` 与 `LinkedHashSet` 的 `Unit` 值需跟着改；`remove` 的"自指帮 GC"逻辑要保留。
- **验证**：`cjpm bench -O2` 跑"10 万 key × 每 key 覆盖 100 次"，对比 `getAllocatedHeapSize()`、GC 次数与耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `PriorityQueue.grow` 目标改为 `max(queue.size*2, currentSize+1)`

- **现状**：超 capacity 后每次 `add` 触发一次全量拷贝（见「一般」第 9 条），`grow` 目标取 `currentSize*2` 导致"删多后加"时数组抖动。
- **方案**：目标取 `max(queue.size * 2, currentSize + 1)`，并在 `doOffer` 成功后不再回看 `capacity`（软容量只用于策略判定，不进 `add` 的重试分支）。
- **预期**：n 次插入的拷贝总量从 O(n²) 降到摊销 O(n)（理论值；需实测确认常量）。
- **代价**：`capacity` 语义要从"硬上限"改为"触发策略的阈值"，需同步更新 `SyncPriorityQueue` 的默认 `capacity: 0` 文档。
- **验证**：`cjpm bench -O2`，`capacity: 8` 插入 1e3/1e4/1e5 三档，记录总耗时与 `getAllocatedHeapSize()` 增量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `DifferenceSetView/IntersectionSetView.size` 是 O(n)，避免在循环条件里调用

- **现状**：`size` 每次遍历整个视图（`DifferenceSetView.cj:39-47`、`IntersectionSetView.cj:43-51`）。
- **方案**：视图构造时惰性缓存一次 size（加 `var cached: ?Int64`），或在文档中标注"O(n)，勿在循环条件中使用"。
- **预期**：把 `while (view.size > 0)` 这类写法的复杂度从 O(n²) 降到 O(n)。
- **代价**：缓存会掩盖底层集合的后续变更（视图本就是快照语义，可接受）；需要 3 行状态字段。
- **验证**：构造 10 万元素的差集/交集，比较 `size` 调用 1 次与 1e4 次的总耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `BitSet` 的按位扩容是分配热点（每次跨 word 都新建 `Array` 再 `add(all:)`） | `src/BitSet.cj:52-58` | 分配量与占比 | `cjprof record` 跑"随机下标置位 1e6 次"，看 `Array` 分配占比 |
| 2 | `LinkedHashMap.get` 的链表重排在 LRU 场景（`HeapCache`）占端到端耗时显著 | `src/LinkedHashMap.cj:110-122` | 自耗时占比 | `cjprof record` 跑 `HeapCache` 读写混合 10 分钟稳态，按函数看 self time |
| 3 | `PriorityQueue.removeIf` 的 `adjustUp` 重插在大量删除时退化 | `src/PriorityQueue.cj:239-258` | 单次耗时、删除比例敏感度 | `cjpm bench -O2`，size 1e5，删除比例 10%/50%/90% 三档 |
| 4 | `ExtendList.batchRemove` 尾部逐个 `remove(at:)` 是否真的是 O(1) | `src/ExtendCollection.cj:36-49` | 实测曲线 | 1e5 元素、保留比例 0/50/100 三档，记录耗时是否线性 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/BitSet.cj` | .cj | ✅ | 见发现 1/4/13/14 |
| 2 | `src/Collection_test.cj` | .cj | ✅ | 见「三个已损坏的公开 API 没有回归用例」 |
| 3 | `src/Dict.cj` | .cj | ✅ | 见重复逻辑与文档残留两条 |
| 4 | `src/DifferenceSetView.cj` | .cj | ✅ | 见重复逻辑、retain 无用分配 |
| 5 | `src/ExtendCollection.cj` | .cj | ✅ | 见 retain 空操作、toArray 预分配、重复逻辑 |
| 6 | `src/GrowSizePolicy.cj` | .cj | ✅ | 见 PriorityQueue 扩容条与幽灵类型参数 |
| 7 | `src/Growable.cj` | .cj | ✅ | 仅 `grow()` 契约，无问题 |
| 8 | `src/HashDict.cj` | .cj | ✅ | 见重复逻辑、remove(all!) 预分配 |
| 9 | `src/IntersectionSetView.cj` | .cj | ✅ | 同上 |
| 10 | `src/LinkedHashDict.cj` | .cj | ✅ | 见 remove(all!) 幽灵节点、重复逻辑 |
| 11 | `src/LinkedHashMap.cj` | .cj | ✅ | 见严重 2、一般 5/6/11 |
| 12 | `src/LinkedHashSet.cj` | .cj | ✅ | 见 `==` 顺序敏感、first 副作用、retain/retainAll |
| 13 | `src/LinkedNode.cj` | .cj | ✅ | 见迭代器失效死循环 |
| 14 | `src/MapKeyValues.cj` | .cj | ✅ | 见死代码 `MapValues.clear()` |
| 15 | `src/PriorityQueue.cj` | .cj | ✅ | 见扩容策略缺陷 |

合计：`.cj` 15 个 / `.md` 0 个（本部分清单内），全部读完。模块剩余 `SetOp.cj`、`TreeDict.cj`、`UnionSetView.cj`、`ValueEqualMap.cj`、`README.md`、`README_en.md` 由第 2 部分覆盖（共 19 个源文件 + 2 个 `.md`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 3（BitSet.set、remove(all!)、retain）；设计 1（幽灵类型参数）；可读性 1（文档残留/运算符无注释）；安全性 0（本部分无外部输入、无凭据、无 SQL） |
| §1 死代码 | 1 | 逐个 `private`/`internal` 符号全仓搜过引用（`newMap`/`newKey`/`turnToTail`/`batchRemove`/`HashKeyIterator` 等均有调用者）；`protected` 0 个（本部分无 `protected`）；对外不可达的 `public` 成员只命中 `MapValues.clear()`；对外可达的 `public`（`BitSet`/`PriorityQueue`/`LinkedHashSet` 等）不判，`ValueNode.turnTo(HeadNode)` 全仓无调用但因属对外可达 public 类只记为信息 |
| §2 重复逻辑 | 3 | 已两两比对 15 个文件的函数体（压缩为"输入→输出→副作用"）并跨文件搜相同字面量；命中 HashDict/LinkedHashDict、DifferenceSetView/IntersectionSetView、`entryView` 三组；`retain`/`retainAll`、`120` 字面量复制分别在「轻微」里单列 |
| §3 空实现 | 1 | 两个 SetView 的六个 mutator 是文档化的 Null Object（`DifferenceSetView.cj:27-29` 有注释），不算缺陷；命中视图 `retain` 无效果实现；`DiscardOverSizePolicy.reject {}` 属 f_base（范围外） |
| §4 栈溢出 | 0 | 通读 15 个文件无递归：`adjustUp/adjustDown` 是循环，链表遍历/迭代器是循环，`Node` 默认实现直接 `throw`；无"递归遍历用户结构"的路径 |
| §5 OOM | 1 | 命中 BitSet 无上限扩容（严重 4）；另核查 `PriorityQueue` 无界增长属设计（`growOnFull`）、`toArray` 物化规模由 size 决定，未发现新的无界点 |
| §6.1 热点瓶颈 | 0 | 本轮未提供 profile / bench（`scope.md`「已有性能资料」为空），热点类结论全部降级到「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分 15 个文件无任何锁/原子操作，无临界区可评（锁包装在 f_concurrent 的 `SyncPriorityQueue`、f_cache 的 `SyncLinkedHashMap`，范围外） |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池使用 |
| §6.4 低效算法 | 1 | 命中 PriorityQueue 超容量后每次 add 全量拷贝；另核查 `contains` 线性扫描（视图/字典的 `contains(all!)` 是对输入单遍、无嵌套）与 `size` 的 O(n)（已进优化方案，不作缺陷） |
| §7 降堆内存方案 | 1 | LinkedHashMap 节点/元组瘦身，标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | PriorityQueue 扩容目标修正、视图 size 缓存，均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分无"函数内创建、返回前独占的大临时对象"；`ArrayList`/`Array` 都是成员字段或返回值（逃逸），且 `@ local` 无 std 重载可核对，改造不成立 |
| §11 现有代码的 BUG（存量） | 22 | 本轮读到的全部函数边界/空值/契约已核对；命中即上面全部 22 条（全部标 `[存量]`，快照模式无基线可比） |
| §12 并发安全与锁粒度 | 2 | `LinkedHashMap.get` 写副作用且未声明线程不安全、链表迭代器无失效检测（同一根因族）；本部分其余类型无线程共享证据，判为线程封闭（调用方 `Sync*` 包装已加锁，见范围外提示） |
| §14 功能完备性与 README 覆盖 | 1 | `BitSet` 缺 `cardinality`/`clear`（与"位集"预期能力不符，已并入 size 条）；README/README_en 不在本部分文件清单，`§13/§14` 的文档对照由第 2 部分完成 |
| 文件覆盖（§13 等） | 15/15 | 本部分清单 15 个 `.cj` 全部读完；模块余下 4 个 `.cj` + 2 个 `.md` 属第 2 部分 |

**范围外提示**（不计入本部分统计）：`f_concurrent/src/DelayQueue.cj:46-47,78-85` 的 `peek()/size/isEmpty` 未加锁直接读写同一个 `PriorityQueue`，与加锁的 `add/remove` 构成数据竞争，建议在 f_concurrent 轮次确认。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 11 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 22 条（本部分全部为存量），是否纳入修复待用户决定。

## 总评

这套集合实现的骨架（二叉堆、双向链表 + 哈希索引的 LRU、基于 `entryView` 的函数式辅助方法）思路是对的，`PriorityQueue` 的堆调整和 `LinkedHashMap` 的淘汰循环也是按标准写法组织的；`f_cache` / `f_concurrent` 对非线程安全容器统一加包装锁的做法也说明作者清楚边界。

主要风险集中在"公开契约与实现不一致"这一类**静默失效**上：`BitSet.set` 永远返回 false、`ExtendMap.retain` 是空操作、`LinkedHashMap/LinkedHashSet.remove(all:)` 留下幽灵节点（并可让容量淘汰死循环），三者都能编译、能跑、无异常，只用例一测就露馅——这也说明当前测试覆盖恰好绕开了它们。其次是 `BitSet` 用 hashCode 当 bit 下标、无任何上限，一次调用即可 OOM，属于必须处理的安全边界。

阻塞项建议：4 条严重全部在合并前修复（改动都很局部，`remove(all:)` 改成逐个 `remove`、`retain` 换遍历方向、`set` 补写入分支、位图加下标上限）。11 条一般里，`firstEntry` 重排、链表迭代器失效、`PriorityQueue` 扩容是"改一行能止损"的，可紧随其后；重复逻辑（HashDict/LinkedHashDict、两个 SetView）建议排期合并，但不要与缺陷修复混在一个提交里。轻微项与三条优化方案都缺基线数据，按「待验证假设」处理，不进本轮修复清单。
