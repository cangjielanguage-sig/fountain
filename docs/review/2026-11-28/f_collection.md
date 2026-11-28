# f_collection 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_collection`（21 个文件：19 个 .cj + 2 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_collection.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

### [严重] `UnionSetView.iterator()` 用交集逻辑实现并集，并集视图恒为空

- **位置**：`f_collection/src/UnionSetView.cj:36-38`（`iterator` 返回 `IntersectionSetIterator(DifferenceSetView(set1,set2).iterator(), set2)`）；`f_collection/src/UnionSetView.cj:21-32`（`UnionSetIterator` 定义后在本文件与全仓均无引用）；`f_collection/src/UnionSetView.cj:39-50`（`isEmpty` / `size` 都建立在 `iterator()` 之上）
- **来源**：存量（快照模式无基线；blame 4be871f2f）
- **判据**：review-checklist §11「语义与命名不符 / 契约与实现不符」、§2「近似重复（并集用交集迭代器）」
- **证据**：静态确定 —— `DifferenceSetView(set1,set2)` 迭代出的是 `set1 - set2`，再套 `IntersectionSetIterator(..., set2)` 会按 `set2.contains(e)` 过滤；`set1 - set2` 中每个元素都不在 `set2`，因此一条也留不下。真正的并集迭代器 `UnionSetIterator`（本文件 21-32 行，`itr1` 耗尽后接 `itr2`）写了却没人用
- **描述**：`HashSet/LinkedHashSet/TreeSet/ConcurrentHashSet` 的 `union()`（`SetOp.cj:29-31/40-42/51-53`、`f_concurrent/src/ConcurrentHashSet.cj:147-149`）都返回该视图，于是 `a.union(b)` 的 `size` 恒为 0、`isEmpty()` 恒为 true、`for (e in a.union(b))` 一次都不进入、`toArray()` 得空数组；`contains` / `subsetOf` 却是对的（58/66 行），同一对象出现「contains 说在、迭代说没有」的自相矛盾。本模块与 `f_collection/src/Collection_test.cj` 都没有任何集合视图用例，问题不会被现有测试发现
- **建议**：改为 `UnionSetIterator<T>(DifferenceSetView<T, C>(set1, set2).iterator(), set2.iterator())`；补三条视图用例（`union`/`intersection`/`difference` 各断言 `size`、迭代序列、`contains` 一致），并加「并集大小 = |A|+|B|-|A∩B|」的恒等式断言

### [严重] `BitSet.set(value)` 只对「已置位」的 bit 生效，永远不会新增元素

- **位置**：`f_collection/src/BitSet.cj:82-104`（`set<T>(value, store)` 的 88-97 行；`public func set` 在 99-101 行转调 `store=true`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」、§3「公开契约承诺有行为，实现为空」
- **证据**：静态确定 —— `if (let i <- computePosition(h) && (bits[idx] & i) != 0)` 要求目标位**已经是 1** 才进入写分支；而分支里 `bits[idx] |= i` 对已为 1 的位是恒等操作。目标位为 0 时走 `else` 直接 `false`，不写任何 bit
- **描述**：`README.md:21` 承诺「将参数的哈希保存于当前的位集」。实际 `set(v)` 是「位已置 1 则返回 true，否则返回 false 且不置位」——即哈希从不落库，只回报当前状态。`remove(v)` 因为「只清已置位的位」在语义上恰好正确，所以测试 `Collection_test.cj:218-233`（只用了下标算子与 `| & ^`，完全没调 `set/remove/contains` 的值重载）无法暴露。下游若用 `BitSet` 做去重/布隆式集合，会得到「永远判不存在」的静默错误
- **建议**：写成 `if ((bits[idx] & i) == 0) { if (store) {bits[idx] |= i}; false } else { if (!store) {bits[idx] &= !i}; true }`（返回「操作前是否已存在」，与 `HashSet.add` 一致），并补 `set/contains/remove` 的值重载用例

### [严重] `BitSet.&(index)` 用整字与单 bit 掩码相与后直接写回，抹掉同字其余 63 位

- **位置**：`f_collection/src/BitSet.cj:159-166`（`163` 行 `let r = val & mask`、`164` 行 `bits[idx] = r`）
- **来源**：存量
- **判据**：review-checklist §11「数据错误」、§2「近似重复导致的实现漂移」（同组 `|` / `^` 只改目标位，`&` 改了整字）
- **证据**：静态确定 —— `computePosition` 生成的掩码只有 1 个 bit 为 1，`val & mask` 的结果必然只剩该位；把结果整体写回 `bits[idx]`，同一 `UInt64` 字内的 63 个其它位全部变成 0
- **描述**：`bs & i` 会静默清空与 `i` 同属一个 64 位字的所有其它元素（`i / 64` 相同的全部键）。这是不可逆的数据丢失，而 `|`（143-149）、`^`（180-190）都是按位修改。测试 `Collection_test.cj:230-232` 在调用 `&` 前已把其它位清零（`bs[21324] = false`、`^` 也清成 0），因此覆盖不到
- **建议**：语义澄清后二选一：若意图是「把目标位与 1 相与（恒等，返回当前值）」则写成 `let r = bits[idx] & mask; r != 0`（不写回）；若意图是「清空目标位」，写成 `bits[idx] &= !mask`。补一条「同字多键、`&` 后其它键仍在」的用例

### [严重] `BitSet` 以 `hashCode`/下标直接决定数组长度并即时预分配：负哈希或大下标直接触发巨额分配（OOM / 崩溃）

- **位置**：`f_collection/src/BitSet.cj:52-58`（`growIfNeed(index: UInt64)`，`55` 行 `bits.add(all: Array<UInt64>(idx - bits.size + 1, repeat: 0))`）、`59-61`（`Int64` 版本无范围校验）、`82-84`（`set` 用 `value.hashCode().toUInt()` 当位下标）、`124-127`
- **来源**：存量
- **判据**：review-checklist §5「按不可信长度预分配 / 无界容器」
- **证据**：静态确定 —— `f_base/src/ExtendNumber.cj:392-399` 的 `Int64.toUInt()` 是 `@OverflowWrapping` 的补码回绕：`-1` → `0xFFFF_FFFF_FFFF_FFFF`。于是 `bs[-1] = true` 或 `bs.set(x)`（`x.hashCode()` 为负，任何正常 `Hashable` 都可能）得到 `idx ≈ 2^58`，`Array<UInt64>(2^58, repeat: 0)` 约 2 EB，必然 `OutOfMemoryError`/分配失败异常。正哈希同样无上限：`hash = 10^12` 就需要约 125 GB 的位图
- **描述**：位集合的容量由「哈希值大小」而非「元素个数」决定，且没有 `maxBits` 之类的拒绝路径，`contains`（不扩容，返回 false）与 `set`（扩容，爆内存）对同一负哈希的行为还互相矛盾。`README.md:10-11` 只说「64 * capacity 位」，没有声明这是「按哈希取模的定长位图」，调用方很容易当成普通集合用
- **建议**：`growIfNeed` 加「下标 < 上限（构造参数 `maxBits`，默认如 2^26）」校验，越界抛明确异常；`set/contains/remove` 改成 `h % size`（有界位图）或 `abs(h)` 且拒绝负值；`Int64` 重载先判 `>= 0`

### [严重] `LinkedHashMap.remove(all!)` 只删索引表不摘链：迭代器继续返回已删元素，`max` 模式下 `add` 可能死循环（并波及 `LinkedHashSet.remove(all!)`）

- **位置**：`f_collection/src/LinkedHashMap.cj:257-259`（`remove(all!)` 只调 `map.remove(all: all)`）、`93-95`（`iterator()` 走 `LinkedNodeIterator(head)` 遍历链而非索引表）、`216-226`（`add` 的驱逐循环）、`141-151`（`delete` 对 `None` 不摘链）；`f_collection/src/LinkedHashSet.cj:85-87`、`51-53`
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符 / 数据错误」、§12.1「迭代与修改并发」、§4（间接的死循环）
- **证据**：静态确定 —— `HashMap.remove(all:)` 只清索引，`ValueNode` 仍挂在 `head..tail` 链上；`iterator()` 按链遍历，所以被删键仍被迭代出来。`LinkedHashSet.remove(all:)` 转调同一方法，`iterator()` 走 `map.keys()` 同样按链遍历
- **描述**：三条可复现后果：①`for ((k,v) in map)` 仍返回已删条目，`size` 却是新值，`toArray()`（82-87 行 `Array(size){getOrThrow}`）取到的是前 `size` 个节点的内容，可能整批是脏数据；②`LinkedHashSet.remove(all:)` 后 `add(同一个键)` 会插一个新节点、旧节点还在链上，迭代同一键两次而 `size` 只算 1；③`max=true` 时（`LinkedHashSet` 内部 `LinkedHashMap<T, Unit>()` 是 `max=false`，但直接使用 `LinkedHashMap(size,true)` 的 LRU 场景会命中）`add` 的驱逐循环取 `head.next` 这个脏节点调 `remove(key)`，`map.remove` 返回 `None` → `delete(None)` 不摘链 → `s = size` 不变 → `while` 条件恒真，**进程挂死**。仓内目前没有 `remove(all:)` 调用者（`grep -rn "remove(all:"`），属潜伏缺陷，但 `f_log`（`Logger` 的 `LinkedHashMap<String,T>` 参数表）与 `f_cache`（`SyncLinkedHashMap`）都在用该类型
- **建议**：`remove(all!)` 逐 key 调用 `this.remove(key)`（走 `delete(Some)` 摘链），或先收集命中的 `ValueNode` 再统一 `n.remove()`；驱逐循环增加「本轮 size 未下降即 `break`」的兜底，避免死循环

### [严重] `ExtendMap.retain(c)` 判定方向反了，永远删不掉任何 key（静默失效）

- **位置**：`f_collection/src/ExtendCollection.cj:55-59`
- **来源**：存量
- **判据**：review-checklist §3「公开契约承诺有行为，实现为空」、§11「契约与实现不符」
- **证据**：静态确定 —— `for (k in c where !contains(k)) { remove(k) }` 遍历的是「要保留的集合」`c`，条件 `!contains(k)` 恰好筛出「本来就不在 map 里」的键，对这些键 `remove(k)` 是 no-op；map 里那些不在 `c` 中的键从未被遍历，自然不会删
- **描述**：`retain` 的语义是「只保留 `c` 里的键」，实现等价于空函数。`HashMap`（105 行）、`TreeMap`（107 行）、`LinkedHashMap`（121 行，注意这是 `f_collection` 自己的类型）、`ConcurrentHashMap`（123 行）都通过 `ExtendNonConcurrentMap` / `ExtendMap` 继承该默认实现，因此 `map.retain(keys)` 在所有标准 Map 上都是静默 no-op，且没有任何返回值或日志提示失败。对照同一文件 `ArrayList.retain`（30-32 行）用的是 `set.contains(this[r]) == complement`，方向是对的——同一语义两种写法，其中一种写反
- **建议**：改为 `for (k in this.keys()) { if (!c.contains(k)) { remove(k) } }`（先物化 keys 避免边遍历边删）；`ConcurrentHashMap` 版本改用 `removeIf {k, _ => !c.contains(k)}`；补「3 个键保留其中 2 个」的用例

### [一般] `PriorityQueue.removeIf` 只向上修复（`adjustUp`），压缩后堆序不变量被破坏

- **位置**：`f_collection/src/PriorityQueue.cj:239-258`（`253` 行 `adjustUp(lastIdx, v)`）
- **来源**：存量
- **判据**：review-checklist §6.4「低效算法」、§11「逻辑错误」
- **证据**：静态确定（不变量破坏）＋ 需实测（是否导致出队顺序错误）—— 对堆 `[1,10,2,11,12,3,4]` 执行 `removeIf{v => v == 10}`，逐步代入得数组 `[1,2,4,12,3,11]`（`currentSize=6`），其中 `queue[4]=3 < queue[1]=2`，父子关系已被破坏
- **描述**：删除空洞后把后面的元素整体前移，等价于「每个幸存者向左移动」，平移会改变父子下标关系，而 `adjustUp` 只能修「比父小」，修不了「比子大」。破坏后的堆对 `peek` 仍返回全局最小，但 `remove()` 的 `adjustDown` 只沿一条路径下沉，深层倒挂的较小元素会被推迟出队；`toArray()`（259-264 行）用 `Array(size){next().getOrThrow}`，若 `removeIf` 中间留下 `None` 洞还会直接抛 `NoneValueException`。现有用例 `Collection_test.cj:201-216`（1..10 隔一个删一个）规模太小，落在 `adjustUp` 恰好够用的路径上
- **建议**：改为标准做法——把删除位置之后的幸存者追加到写指针处后，对 `[0, newSize)` 从 `newSize/2-1` 倒序做一遍 `adjustDown`（O(n)），或在写入后对每个落位元素做一次「先上后下」的修复；用例补「删中间元素后连续 `remove()` 断言严格升序」与「随机堆 + 随机谓词，与排序结果比对」

### [一般] `LinkedHashSet.==` 依赖迭代顺序，同元素不同访问顺序判为不等

- **位置**：`f_collection/src/LinkedHashSet.cj:112-127`（`122` 行 `while (let (Some(x), Some(y)) <- (itr1.next(), itr2.next()) && x == y)`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— 逐个位置比较 `x == y`，中途不等即退出，`i == this.size` 只在「顺序完全一致」时成立
- **描述**：`Set` 语义下相等只看元素集合，且该类型的迭代顺序由访问顺序决定（`get` 会把节点移到尾部，见 `LinkedHashMap.cj:113-122`）。于是 `a = {1,2}`、`b = {2,1}`（`b` 通过先 add 2 再 add 1 得到）判为不等；甚至同一个集合在读取元素后与自身副本比较也可能不等。`T <: Comparable` 的约束也与 `Set` 的 `Equatable` 语义无关
- **建议**：改为「`size` 相等且 `other.contains` 全含」（双向 `subsetOf`），或直接复用 `Set` 的 `==` 语义；约束降到 `T <: Hashable & Equatable<T>`

### [一般] `ConcurrentHashMapKeys.toArray()` 用调用瞬间的 `size` 预分配，并发缩容时抛 `NoneValueException`

- **位置**：`f_collection/src/ExtendCollection.cj:186-190`（`189` 行 `Array<K>(size){_ => itr.next().getOrThrow()}`）
- **来源**：存量
- **判据**：review-checklist §12.1「迭代与修改并发」、§11「空值未处理」
- **证据**：静态确定 —— `ConcurrentHashMapIterator`（`cangjie_runtime/stdlib/libs/std/collection/concurrent/concurrent_hash_map.cj:1125-1170`）持桶引用做弱一致遍历，`next()` 在桶被清空/元素被删后可提前返回 `None`；`getOrThrow()` 把它变成异常。`size` 与 `iterator()` 之间没有任何快照或锁
- **描述**：`ConcurrentHashMapKeys` 是 `ConcurrentHashMap.keys()` 的返回类型（144-146 行），调用方按「并发容器」预期无锁调用 `toArray()`；另一线程删元素时，`Array(size)` 需要 `size` 个元素而迭代器只给出更少 → 抛 `NoneValueException`，属于把并发场景下的正常竞态变成崩溃
- **建议**：改成 `while (let Some(k) <- itr.next()) { list.add(k) }` 后 `list.toArray()`（或者直接 `map.toArray(){...}`），不要用 `size` 驱动循环

### [一般] `HashDict`/`LinkedHashDict`/`TreeDict.remove(all!)` 按 `all.size` 一次性预分配并用 `getOrThrow` 取值

- **位置**：`f_collection/src/HashDict.cj:140-143`；`f_collection/src/LinkedHashDict.cj:125-128`；`f_collection/src/TreeDict.cj:129-132`
- **来源**：存量
- **判据**：review-checklist §5「按不可信长度预分配」、§11「空值未处理」
- **证据**：静态确定 —— 三处同一写法 `Array<Wrap>(all.size){_ => newKey(keys.next().getOrThrow())}`，`size` 与迭代条数脱钩时立即抛 `NoneValueException`；`size` 由调用方集合决定，超大时先分配整块数组
- **描述**：`all` 可以是任意 `Collection<K>`（含另一个 Map 的 `keys()` 视图、惰性集合），`Collection.size` 与 `iterator()` 条数不保证一致。同一模式在本模块出现三次，属复制传播的同一缺陷
- **建议**：改为先 `ArrayList` 逐条 `add` 再 `map.remove(all: list)`，或直接 `for (k in all) { remove(k) }`（三次重复合并为一个 private 辅助函数）

### [一般] `Node<T>` 接口的 5 个默认实现全部 `throw UnreachableException()`，对 `HeadNode`/`TailNode`/`NoneNode` 调用即抛「不可达」异常

- **位置**：`f_collection/src/LinkedNode.cj:68-84`（`insertPrev`/`insertNext`/`remove`/`removePrev`/`removeNext` 默认体都是 `throw UnreachableException()`）；`86-88`（`NoneNode` 未覆盖任何方法）
- **来源**：存量
- **判据**：review-checklist §3「接口给了默认空实现 / 占位仍在主路径」、§11「契约与实现不符」
- **证据**：静态确定 —— `Node<T>` 是 `public` 接口，`HeadNode`/`TailNode` 只覆盖各自支持的两个方法，其余落到默认体；`HeadNode.remove()`、`NoneNode.insertNext()` 都是可经公开接口调用的路径，却抛「不可达代码」异常
- **描述**：`UnreachableException` 语义是「编译器/开发者认为不会发生」，这里恰恰是「接口允许但子类型不支持」。调用方无法从签名看出哪些方法可用，`catch (UnreachableException)` 会把真正的逻辑错误混在一起。同文件 `HeadNode.removeNext`（100-106）、`TailNode.removePrev`（121-127）、`ValueNode.remove`（154-168）的 `case _ => throw UnreachableException()` 亦然
- **建议**：接口改为只声明公共子集，或默认体抛专门的 `UnsupportedOperationException`/返回 `None`；`NoneNode` 显式实现（返回 `None`/自身）把哨兵语义写清

### [一般] `PriorityQueue.grow()` 以 `currentSize * 2` 为目标，公开的「扩容」API 实际可把数组缩小

- **位置**：`f_collection/src/PriorityQueue.cj:130-148`（`133-139` 行 `target = if (currentSize > 0) currentSize * 2 ...`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名不符」
- **证据**：静态确定 —— `queue` 长度与 `currentSize` 无耦合：`capacity=16` 时扩容到 32、再 `remove()` 到 `size=5` 后调用 `grow()`，`target=10 < 32`，`Array(10)` 重建，容量从 32 掉到 10
- **描述**：`README.md:423` 与 130 行注释都称「扩容」，`GrowSizePolicy.reject`（`GrowSizePolicy.cj:22-25`）也依赖它「先 grow 再插入」。缩容本身不丢元素（只拷 `i < currentSize`），但 ①连续 `grow()` + `add()` 会在 10/20/40 之间抖动，与「扩容后不会再满」的调用方假设冲突；②若 `currentSize == 0` 且 `capacity == 0`，`target` 落到 `DEFAULT_CAPACITY`，此时 `grow()` 反而创建容量 16 的空数组——三种分支语义不统一
- **建议**：`target = max(queue.size * 2, capacity, DEFAULT_CAPACITY)`，并明确 `grow()` 只增不减；缩容另开 `trimToSize()`

### [一般] 三个只读视图的 `retain(all!)` 构造一个新视图后丢弃，纯死语句

- **位置**：`f_collection/src/IntersectionSetView.cj:137-139`；`f_collection/src/DifferenceSetView.cj:133-135`；`f_collection/src/UnionSetView.cj:136-138`（三处都是 `IntersectionSetView<T, Set<T>>(this, all)` 作为语句丢弃）
- **来源**：存量
- **判据**：review-checklist §1「不可达/无副作用语句」、§3「空实现」
- **证据**：静态确定 —— 表达式结果未赋值、未返回，构造函数无副作用，整条语句编译后无任何效果；注释却写「只保留重复的 T」
- **描述**：`retain` 在只读视图上是 no-op（可接受），但当前实现每次调用还额外分配一个视图对象，等于「不但没做事，还制造垃圾」。同类只读集合 `f_base/src/EmptyCollections.cj:126` 的 `retain` 直接空体，说明本模块这两处是遗漏而非设计
- **建议**：三处改为空体并加注释「只读视图不支持 retain」，或删掉该成员（`Set<T>` 接口要求的实现必须保留，所以只能空体 + 注释）

### [一般] `TreeMap.entryView` 覆盖实现里留着 `//todo 我认为TreeMapEntryView有BUG`，并绕过 `entry.value` 二次查表

- **位置**：`f_collection/src/ExtendCollection.cj:107-119`（`110` 行 TODO 注释、`111-115` 行 `this.get(key)` 再查一次）
- **来源**：存量
- **判据**：review-checklist §3「`TODO`/`FIXME` 占位仍在主路径」、§6.4「同一输入重复解析/重复查找」
- **证据**：静态确定 —— 注释明确写着「entry.value 会出 NoneValueException」，代码随即改用 `this.get(key)` 取旧值，`entry` 只用于最后 `entry.value = value`
- **描述**：`ExtendNonConcurrentMap` 的默认 `entryView(key, fn)`（88-93 行）与 `Dict.entryView`（`Dict.cj:130-135`）走 `entry.value`，只有 `TreeMap` 走这条带 TODO 的分支：①`fn` 拿到的 key 是入参 `key` 而非 `entry.key`（默认实现传的是 `entry.key`，两者可能不是同一对象）；②每次调用多一次 `TreeMap.get`（O(log n)）；③注释里的「BUG」若成立，说明 `TreeMapEntryView.value` 的读取路径仍有未定位问题，而这段绕行会把它掩盖
- **建议**：先定位 `TreeMapEntryView` 的真实问题（给 `TreeMap.entryView(k).value` 单独写用例），修好后删掉这段覆盖实现与 TODO，让 `TreeMap` 与 `HashMap`/`LinkedHashMap` 共用同一默认实现

### [一般] README 三处 API 与实际声明不符（TreeDict 类名、LinkedHashDict 构造签名、PriorityQueue 继承与参数）

- **位置**：`f_collection/README.md:267-271`（TreeDict 章节写成 `public class LinkedHashDict<K, V> <: Dict<K, V>`，且 `public TreeDict(private let cmp: ...)` 缺 `init`）、`README.md:253-259`（LinkedHashDict 只列 `init(size, hasher, equals)`）、`README.md:382-410`（`<: Queue<T> & Iterable<T> & Collection<T> & Growable`、四个构造/工厂签名都缺 `growOnFull!`）；`f_collection/README_en.md:267-271`、`:253-259`、`:383-411` 同样内容
- **来源**：存量
- **判据**：review-checklist §13「API / 默认值与源码不符」「示例代码不能用」
- **证据**：静态确定 —— 实际声明：`TreeDict.cj:32` 是 `public class TreeDict<K, V> <: Dict<K, V>`；`LinkedHashDict.cj:33/36` 的构造函数是 `init(size: Int64, max: Bool, hasher, equals)` 与 `init(size, max, initElement, hasher, equals)`，README 写的两个 `size` 重载**不存在**；`PriorityQueue.cj:37` 只实现 `Queue<T> & Growable`，`49-86` 的构造与三个工厂都有 `growOnFull!: Bool = true`
- **描述**：照着 README 写 `LinkedHashDict(16, hasher, equals)` 或 `PriorityQueue.create(capacity: 8, overSizePolicy: p)` 会编译失败/语义不同；`TreeDict` 章节被整段复制成 `LinkedHashDict` 的声明，读者无法判断这两个类型是不是同一个东西。`max: Bool`（LRU 上限）这个最关键的参数在两版 README 里都没有出现
- **建议**：按源码重新生成这三段（含 `max` 的 LRU 语义与 `growOnFull` 的丢弃/扩容选择），并把 README 片段抽成可编译样例纳入测试，避免再次漂移

### [一般] `LinkedHashMap.firstEntry()/lastEntry()` 读取即重排，`first` 重复读取不幂等；迭代中 `get()` 可重复访问

- **位置**：`f_collection/src/LinkedHashMap.cj:172-183`（`179` 行 `turnToTail(e)`）、`96-101`（`turnToTail`）、`113-122`（`get` 命中即 `turnToTail`）；受影响：`LinkedHashSet.cj:94-109`（`first/last/removeFirst/removeLast` 都经这两个方法）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名不符」、§12.1「迭代与修改并发」
- **证据**：静态确定 —— `firstEntry()` 先取 `head.next`，再调 `turnToTail` 把它挪到尾部，下一次调用取到的就是原来的第二个元素
- **描述**：`firstEntry` 是读接口，却修改访问顺序：(1) 连续调两次可能得到两个不同值，`LinkedHashSet.first` 同样；(2) 在 `for ((k,v) in map)` 期间调用 `get(k)`（`entryView.value` 的 getter 也会走 `get`）会把节点移到尾部，若该节点在迭代器当前位置之前，迭代器会**再次访问**它，`toArray()` 的 `Array(size){...}` 还会因此提前耗尽或重复填充。类注释说「按最近访问顺序遍历」（`README.md:291`），但没有一句话说明读操作会重排、以及迭代期间不得读
- **建议**：`firstEntry`/`lastEntry` 改为不重排（重排只由 `get` 触发），或新增 `peekFirstEntry`；在类注释与 README 明示「遍历期间调用 `get`/`entryView` 会改变顺序，不保证遍历完整性」

### [轻微] `HashDict` / `LinkedHashDict` / `TreeDict` 是三份同构实现，仅换包装类型名

- **位置**：`f_collection/src/HashDict.cj:35-311`、`f_collection/src/LinkedHashDict.cj:20-296`、`f_collection/src/TreeDict.cj:32-326`
- **来源**：存量
- **判据**：review-checklist §2「只改类型名」
- **证据**：静态确定 —— 把 `LinkedHashDict`→`Dict`、`LinkedHashKey`→`Key`、`LinkedHashMap`→`HashMap` 归一化后与 `HashDict` 做 diff，311 行里只差 99 行（差异全部集中在 `HashKey` 结构体是否存在、构造函数是否多 `max: Bool`、包装类名）；`TreeDict` 是同一模板换 `ComparableKey` / `TreeMap`。三者连 `contains(all!)`、`remove(all!)`、`keys()`、`values()`、`toArray()`、`entryView` 的实现体都逐行对齐
- **描述**：三份复制带来的实际后果已经出现：`remove(all!)` 的 `all.size` 缺陷（见「一般」第 4 条）在三个文件里各写了一遍；`get/contains/add` 都各自重复 `newKey` + 转调。任何一个修复都要改三处，漏一处就产生行为漂移
- **建议**：抽 `DictBase<K, V, W>`（泛型包装键类型 + 底层 `Map<W, V>` 构造闭包）承载全部转调逻辑，三个实现只提供 `newKey` 与底层 map 的构造；`Dict.cj` 已有大量默认实现，可继续沿用

### [轻微] `SetOp` 三个 `extend` 体逐行相同，只换集合类型名

- **位置**：`f_collection/src/SetOp.cj:25-57`
- **来源**：存量
- **判据**：review-checklist §2「只改类型名」
- **证据**：静态确定 —— 三段 `intersection/union/difference` 只有 `HashSet`/`LinkedHashSet`/`TreeSet` 与对应约束（`Hashable & Equatable` / `Comparable`）不同，其余字符完全一致
- **描述**：`f_concurrent/src/ConcurrentHashSet.cj:143-153` 是第四份复制。并集缺陷（见「严重」第 1 条）正是因为这类复制没人核对
- **建议**：保留三处 `extend`（受 `extend` 语法限制无法泛化），但把「构造视图」抽成模块内私有工厂 `viewOf(set1, set2, kind)`，三处只留一行调用

### [轻微] `Dict.entryView(key, fn)` / `removeIf(key, predicate)` 与 `ExtendNonConcurrentMap` 中的默认实现完全相同

- **位置**：`f_collection/src/Dict.cj:130-135`、`156-164` 与 `f_collection/src/ExtendCollection.cj:88-93`、`94-102`
- **来源**：存量
- **判据**：review-checklist §2「跨文件复制」
- **证据**：静态确定 —— 两个函数体逐字符相同（含 `if (let Some(v) <- view.value && predicate(v))` 的写法）
- **描述**：`Dict` 与 `ExtendNonConcurrentMap` 是两套互不相干的接口体系（一个面向自定义字典，一个面向 std Map 扩展），同一语义各维护一份；`TreeMap` 的覆盖实现（107-119 行）正是二者漂移的产物——它不复用 `Dict` 那份，而是另写一份带 TODO 的版本
- **建议**：把 `entryView(key, fn)` 与 `removeIf(key, predicate)` 抽到模块内私有泛型辅助（如 `entryCompute(view, fn)`），三处共用

### [轻微] `contains(all!)` 与 `Array(size){itr.next().getOrThrow()}` 两块样板代码各复制 7 处

- **位置**：`contains(all!)`：`HashDict.cj:90-95`、`LinkedHashDict.cj:75-80`、`TreeDict.cj:79-84`、`ExtendCollection.cj:148-153`、`IntersectionSetView.cj:79-84`、`DifferenceSetView.cj:75-80`、`UnionSetView.cj:78-83`；`toArray` 的 `size` 驱动写法：`HashDict.cj:220-226`、`LinkedHashDict.cj:205-211`、`TreeDict.cj:209-215`、`LinkedHashMap.cj:82-87`、`MapKeyValues.cj:52-57`/`135-140`、`ExtendCollection.cj:187-190`
- **来源**：存量
- **判据**：review-checklist §2「字面量复制 / 换控制流」
- **证据**：静态确定 —— 均为 `for (e in all where !contains(e)) { return false }; true` 与 `Array<T>(size){_ => itr.next().getOrThrow()}`
- **描述**：同一语义两种风险也一起被复制：`getOrThrow` 版本在 `size` 与迭代不一致时直接抛异常（见「一般」第 3 条），要修得改 7 处
- **建议**：`contains(all!)` 用 `all.all {e => contains(e)}` 之类一行表达；`toArray` 统一走一个模块内 `collect(itr)` 辅助（`while (let Some(x) <- itr.next())` 追加），顺带修掉 `getOrThrow` 崩溃面

### [轻微] `LinkedHashSet.retain(all!)` 与 `retainAll(elements)` 语义完全重复

- **位置**：`f_collection/src/LinkedHashSet.cj:71-73` 与 `91-93`
- **来源**：存量
- **判据**：review-checklist §2「同文件内两两比对：输入-输出-副作用相同」
- **证据**：静态确定 —— 前者 `map.removeIf{k,_ => !all.contains(k)}`，后者 `removeIf{v => !elements.contains(v)}`（后者转调本类 88-90 行的 `removeIf` → 同样落到 `map.removeIf`），唯一差别是经 `Set.removeIf` 多一层转调
- **描述**：`README.md:494` 把两者都列为公开 API，用户无法判断该用哪个；`f_concurrent/src/ConcurrentHashSet.cj:73/100` 也复制了这对同名方法
- **建议**：`retainAll` 保留为 `retain(all:)` 的别名（一行转调并注明互为别名），或只留一个

### [轻微] 未使用的 `import` 与无用类型参数

- **位置**：`f_collection/src/LinkedHashDict.cj:18`（`HashMap`、`EquatableCollection` 均未使用）、`f_collection/src/LinkedHashMap.cj:18`（`ArrayList`）、`f_collection/src/PriorityQueue.cj:18`（`ArrayList`）、`f_collection/src/SetOp.cj:18`（`ReadOnlySet`）；`f_collection/src/GrowSizePolicy.cj:20`（`T` 只出现在 `where T <: Comparable<T>`，从不使用）、`IntersectionSetView.cj:30`、`DifferenceSetView.cj:30`、`UnionSetView.cj:33`（`C` 声明为类型参数但构造函数与字段都只用 `Set<T>`）
- **来源**：存量
- **判据**：review-checklist §1「未使用的 import」；无用的泛型参数属于接口噪声
- **证据**：静态确定 —— 逐个文件搜索符号：`LinkedHashDict.cj` 内 `HashMap`/`EquatableCollection` 零次出现；`LinkedHashMap.cj`/`PriorityQueue.cj` 内 `ArrayList` 零次出现；`SetOp.cj` 内 `ReadOnlySet` 零次出现；`GrowSizePolicy` 的 `T` 在类体中零次出现，`C` 在三个视图类体中零次出现（仅用于构造调用时的显式类型实参）
- **描述**：`GrowSizePolicy<T, C>` 因为那个多余约束，`PriorityQueue<SomeNonComparable>` 无法使用该策略（`Collection_test.cj:189` 被迫写 `GrowSizePolicy<Int64, PriorityQueue<Int64>>()`）；三个视图的 `C` 迫使调用方写 `IntersectionSetView<T, C>` 两个类型实参却毫无语义
- **建议**：删 4 个 import；`GrowSizePolicy` 只保留 `C`（`<: Growable`），视图去掉 `C`（`SetOp` 的 `where C <: Collection<T>` 仍可保留在方法上）

### [轻微] 注释垃圾与错误注释（复制残留、`size` 说成「容量」、`help GC`）

- **位置**：`f_collection/src/Dict.cj:43-45`（`* 将指定的值与此映射中指定的键关联` 后夹一行裸 `120`，同样残留在 `HashDict.cj:97-99`、`LinkedHashDict.cj:82-84`、`TreeDict.cj:86-88`）；`f_collection/src/MapKeyValues.cj:116-124`（`isEmpty` 的文档里混入 `130`、`3.2.8 class ArrayListIterator`、`3.2.9 class HashMapIterator` 三行无关文字）；`f_collection/src/LinkedHashMap.cj:60-63`（`size` 注释写「返回值 Int64 - 列表的容量」，实际返回元素个数）、`MapKeyValues.cj:30-33` 同样；`f_collection/src/LinkedNode.cj:165-166`（`this.prev = this // help GC`）
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 必要注释」、§11「语义与注释不符」
- **证据**：静态确定 —— 逐条对照函数实现与注释文案
- **描述**：`120` / `130` / `3.2.8` 是复制粘贴残留，出现在对外文档注释里；`size` 注释说「容量」会误导调用方以为能读到 `capacity`；`this.prev = this` 的自我引用对 GC 判定无影响（对象是否存活只看可达性），注释起的「帮助 GC」是错的——它带来的是「remove 后再 remove 会自环」的隐式状态
- **建议**：清理残留行；`size` 注释改成「元素个数」；`help GC` 改成「断链：置自环避免误用旧指针」，或直接置 `NoneNode`

### [轻微] `BitSet` 三个位运算符返回值语义互不一致

- **位置**：`f_collection/src/BitSet.cj:143-149`（`|` 返回 `r == val`，即「操作前是否已置位」）、`159-166`（`&` 返回 `r != 0`，即「操作后该位是否为 1」）、`180-190`（`^` 返回「操作前的位值」，注释 170-172 行如此声明）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名不符」、§10 可读性
- **证据**：静态确定 —— 三个分支的返回值分别取「前态」「后态」「前态（真值语义经过翻转）」
- **描述**：`^` 的「前态」是 `true` 表示原来是 1，`|` 的「前态」却是 `r == val`（原来是 1 则 true）——两者碰巧一致，但 `&` 用的是后态，`false` 既可能是「原来是 0」也可能是「操作后是 0」，调用方无法从文档判断。`README.md:34-48` 对三者返回值只字未提
- **建议**：统一为「操作前的位值」并在 README 写明；`&` 改成 `let before = bits[idx] & mask != 0; bits[idx] &= !mask; before`（或按上一节建议改为不写回）

### [轻微] `BitSet(capacity)` 的 `size` 与 README「64 * capacity 位」不符

- **位置**：`f_collection/src/BitSet.cj:38-40`（`bits = ArrayList<UInt64>(capacity)`）、`44-48`（`size = bits.size * 64`）；`f_collection/README.md:10-15`、`README_en.md:10-15`
- **来源**：存量
- **判据**：review-checklist §13「API / 默认值与源码不符」
- **证据**：静态确定 —— `ArrayList<UInt64>(capacity)` 是「初始容量为 capacity 的**空**列表」（`std/collection/collection_package_api/collection_package_class.md:887-897`），`size` 为 0，因此 `BitSet(4).size == 0` 而不是 256
- **描述**：`capacity` 在这里是「预分配多少个 64 位字」，与 `size` 无关；README 说「实例化一个 64 * capacity 的位集」，而 `size` 注释写「当前的位数」，两者一起看会得出「size == 64*capacity」的错误预期，`iterator()` 也会一次都不迭代
- **建议**：README 改为「预分配 capacity 个 64 位字（容量）」，并新增 `capacity` 属性或在 `size` 注释里说明「size 是已使用位数，随最大下标增长」

### [轻微] README 未覆盖 `LinkedHashMap.add(entry:)`、`get(key, turn:)`、`entryView` 等 public API

- **位置**：`f_collection/src/LinkedHashMap.cj:113-122`（`get(key, turn: Bool)`）、`228-230`（`add(entry:)`）、`102-104`（`entryView`）；`f_collection/README.md:287-317`（只列 5 个构造函数）、`README.md:493`（「其他公开 API」只列 `clone`/`firstEntry`/`lastEntry`/`pollFirstEntry`/`pollLastEntry`）
- **来源**：存量
- **判据**：review-checklist §14.2「公开 API 未文档化」
- **证据**：静态确定 —— 在 README 全文检索 `turn`、`add(entry`、`entryView` 均无命中（`README_en.md` 同）
- **描述**：`get(key, turn:false)` 是唯一「读而不改变访问顺序」的入口，对 LRU 场景很关键；`add(entry:)` 是 `Map` 之外多出来的重载；`entryView` 是 `Dict` 系列的核心扩展点。三者都没进文档，用户只能读源码
- **建议**：在 LinkedHashMap 段落补这三项（尤其 `turn` 的语义），并在「其他公开 API」表里补齐 `LinkedHashSet` 的 `==`/`toString` 扩展

<!-- 第 2 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

> 以下均无改前基线，按规则只能作为「待验证」方案，不进修复清单。

### [堆内存] `SetOp.intersection/union/difference` 一次性物化对方集合，视图并不「视图」

- **现状**：`SetOp.cj:26-34/37-45/48-56` 每次调用都 `HashSet<T>(collection)` / `LinkedHashSet<T>(collection)` / `TreeSet<T>(collection)` 复制一份完整集合，随后交给只读视图持有。一次 `a.union(b)` 常驻内存 = `a` + `b` 的完整副本 + 视图对象；链式 `a.union(b).intersection(c)` 会留下中间 Set（视图持有它直到视图被回收）
- **方案**：视图直接持有 `Collection<T>`（`SetOp` 的方法签名已经接受任意 `Collection<T>`），把去重/成员判断推迟到迭代时用 `contains` 或按需建索引；`IntersectionSetView.contains` 已是双 `contains`，不需要物化
- **预期**：每次视图创建少一份 O(|collection|) 的哈希表拷贝（条目数 × 约 40–60 字节量级，按元素类型不同），链式调用时中间集合可全部省掉
- **代价**：`iterator()` 从 O(n) 变成 O(n·log n) 或依赖底层 `Collection.contains` 的复杂度；`size` 本来就是 O(n)，语义不变；若对方集合无高效 `contains`，需要惰性建一次索引（等于把拷贝推迟到首次迭代）
- **验证**：`a`/`b` 各 100 万元素，`-O2`，先采 `getAllocatedHeapSize()` 峰值与 RSS，再比较视图创建耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `HashDict`/`LinkedHashDict` 为每个 key 复制一份 `HashKey`（含两个闭包引用）

- **现状**：`HashDict.cj:20-34` 的 `HashKey<K>` 是 struct，字段为 `key` + `hasher` + `equals`；它作为 `HashMap<HashKey<K>, V>` 的键被存进每个桶，同时 `get/contains/add/remove/replace/addIfAbsent` 每次操作都 `newKey` 现造一个（8 处）。条目内存 = 原 key + 16 字节闭包引用 ×2 + 结构体对齐开销；闭包本身是 `HashDict` 的成员，每个键都存一份重复引用
- **方案**：`HashKey` 只保留 `key` 与指向 `HashDict` 的反向引用（或干脆让包装类持有 `hasher/equals`，`HashKey` 只存 `key` + `owner: HashDict`），哈希与比较经 `owner` 取得；`newKey` 改为不分配（struct 值语义，若仍需装箱则复用同一个包装对象，注意不可跨线程共享）
- **预期**：每个条目少 16 字节 + 一次结构体拷贝；`get` 路径少一次对象构造（若 `HashKey` 因作为泛型实参被装箱，则是每次操作一次堆分配）
- **代价**：`HashKey` 与字典互相引用（生命周期绑定，需确认不会阻止回收——`HashKey` 只在字典内部存活，父持有子、子持有父仍可整体回收）；泛型装箱行为取决于编译器，上机验证
- **验证**：100 万条目，`-O2`，对比 `getUsedHeapSize()` / 单次 `get` 的分配计数（`cjprof heap`）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `LinkedHashMap` 每个条目有三份表示，`ValueNode` 只服务顺序维护

- **现状**：`LinkedHashMap.cj:22-24` 一份数据存在 `HashMap<K, ValueNode<(K,V)>>` 的桶、`ValueNode.value` 的 tuple、以及链表的 prev/next 指针里。每条目 = 哈希桶条目 + `ValueNode` 对象（3 字段）+ 一个 `(K,V)` tuple 对象（若 tuple 装箱）；key 在 `HashMap` 键与 tuple 里各存一份引用
- **方案**：`ValueNode` 只存 `value: V` 与 prev/next（key 由 `map.get(key)` 侧的键持有），`remove` 时用「已知 key」而非从节点读 key——需要把 `delete(opt)` 改成 `delete(key, opt)`；或把 `HashMap<K, ValueNode>` 换成 `HashMap<K, V>` + 独立的 `HashMap<K, Node>`（多一次查表，不推荐）
- **预期**：每条目少一个 tuple 对象与一份 key 引用（约 24–40 字节/条目），`f_log` 的日志参数表（通常 1–5 条，短生命周期）收益有限，`f_cache` 的 LRU 段（`SyncLinkedHashMap`，条目数可上千）收益更明显
- **代价**：`delete`/`removeIf`/`entryView` 需要同时拿到 key，改动面覆盖整个类；`ValueNode` 不再自描述，调试信息变少
- **验证**：`SyncLinkedHashMap` 装 10 万条 String 键，`-O2`，对比 `getAllocatedHeapSize()` 与 RSS；同时回归 `Collection_test.cj` 的 4 个 LinkedHashMap 用例（访问顺序断言）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ArrayList.batchRemove` 逐条 `remove(at:)`，最坏 O(k·n)

- **现状**：`ExtendCollection.cj:36-49`：前向压缩是 O(n) 一次遍历，但收尾 `for (i in s - 1..=w : -1) { remove(at: i) }` 每删一个元素都要把尾部整体左移一次，删 k 个就是 O(k·(s-w))。`retain`/`remove(set:)` 在「几乎全删」时退化到 O(n²)，且每次 `remove(at:)` 还有边界检查与长度维护开销
- **方案**：一次 `remove(w..s)`（`ArrayList` 提供 `remove(Range<Int64>)`，见 `std/collection/collection_package_api/collection_package_class.md:2089-2105`，step 必须为 1），把收尾降为 O(s-w)；或直接 `resize(w)`（若语义允许缩小长度）
- **预期**：从 O(k·n) 降到 O(n)；k≈n 时理论加速比 ≈ n/常数，实际取决于 `remove(at:)` 的 memmove 成本
- **代价**：无（`remove(Range)` 的越界/步长异常语义需确认，`w..s` 天然满足 step=1 且 `0<=w<=s<=size`）
- **验证**：`ArrayList<Int64>` 100 万元素、`retain` 掉 90%，`cjpm bench -O2` 取中位数与 P95，前后对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 只读视图的 `size` 每次调用都是 O(n)，`iterator()` 每次重建两层包装

- **现状**：`IntersectionSetView.cj:43-51`、`DifferenceSetView.cj:39-47`、`UnionSetView.cj:42-50` 的 `size` 都是 `for (_ in this) { s++ }`；`UnionSetView.iterator()`（36-38 行）每次还额外 new 一个 `DifferenceSetView` 与一个 `IntersectionSetIterator`；`LinkedHashSet.iterator()`（51-53）每次 new `MapKeys` + `MapKeyIterator` 两个对象
- **方案**：视图构造时缓存 `size`（底层集合不可变时可缓存；可变则缓存「上次计算结果 + 两个集合的 size 快照」，`size` 变化即失效）；`union` 的迭代器直接组合两个 `Iterator`，不建中间视图
- **预期**：`for (e in view)` 前若调用过 `size`（`toArray`、日志、断言都会），可省一次全量遍历；`LinkedHashSet` 每次 `iterator()` 少 2 次分配
- **代价**：底层集合可变时缓存会过期，需要 `size` 快照校验或干脆不缓存（那就只能拿到 `iterator()` 的收益）
- **验证**：10 万元素集合，`cjprof record` 看 `size` 的 self time 占比；同时测 `-O2` 下单次 `a.union(b).size` 的耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

> 本部分未提供任何 bench / profile / 堆采样数据，按铁律不产出带收益结论的优化方案。唯一可量化的候选（包装对象分配、`containsValue` 全扫描）已降级写入「待验证假设」。

（本部分：堆内存 0 条 / CPU 0 条）

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `HashKey` 作为泛型实参被装箱，`get/contains/add` 每次多一次堆分配，是 `HashDict` 的主要开销 | `HashDict.cj:64-66`（`newKey`）+ 8 个调用点 | 每次操作的分配次数、`newKey` 的 self time 占比 | `cjprof heap` + 100 万次 `get` 循环，`-O2`，与直接用 `HashMap<K,V>` 对照 |
| 2 | `batchRemove` 的尾部逐条 `remove(at:)` 是大集合 `retain` 的实际瓶颈 | `ExtendCollection.cj:46-48` | `remove(at:)` 循环的耗时占比、k 与 n 的关系 | 100 万元素列表，`retain` 掉 10%/50%/90% 三档，分段计时 + `cjprof report` |
| 3 | `PriorityQueue` 扩容用 `Array(target){i => if (i<currentSize) q[i] else None}` 逐元素重建，大堆扩容成本显著 | `PriorityQueue.cj:141-147` | 单次 `grow()` 耗时 vs 元素数、扩容次数 | 100 万次 `add`，`-O2`，分段计时统计 `grow()` 总耗时占比；与「容量翻倍 + 无 copy」的方案对照 |
| 4 | 视图的 `size` O(n) 在「先 size 后迭代」的调用模式下被重复计算 | `IntersectionSetView.cj:43-51` 等三处 | `size` 的调用次数与 self time | 对 `f_concurrent.ConcurrentHashSet` 的 `union/intersection` 调用点加计数埋点，跑 10 分钟稳态负载 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `containsValue` 在 `ConcurrentHashMap` 上必然是 O(n) 全表遍历（无值索引），若被放在请求主路径高频调用会成为 CPU 热点，且弱一致遍历反复取 `map.iterator()` | `f_collection/src/ValueEqualMap.cj:26-40`、`55-61`、`73-75` | 调用频次、自耗时占比、单次遍历规模 | 在调用点加计数埋点，跑稳态负载后用 `cjprof record` 取 self time 占比；输入 10 万条、并发 8，对照「改用维护反向索引」版本 |
| 2 | 每次 `values()` 调用新建 1 个包装器、每次 `iterator()` 新建 1 个迭代器，在高频调用点带来额外分配与 GC 压力 | `f_collection/src/ValueEqualMap.cj:57`、`74` | 每秒调用次数、分配字节数 | 埋点统计调用次数 + `getAllocatedHeapSize()` 前后差值；`cjprof heap` 看 wrapper 类型占比 |

> 以上不进 `todo.md` / `tasks.md`。取证说明：`~/.autocode/cj`（`CODEBUDDY.md` 里登记的文档根）在本机不存在，std 语义改用手边的 1.3 官方文档副本 `C:/Users/74414/.codebuddy/skills/cangjie-doc-1.3/references/libs/std/**` 核对，引用处均标了文档文件与行号；`Dict`/`MapValues`/`ConcurrentHashMapKeys` 等仓内符号用全仓 grep 取证。

## 文件覆盖

> 与 `files/f_collection.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_collection/README.md` | .md | ✅ | — |
| 2 | `f_collection/README_en.md` | .md | ✅ | — |
| 3 | `f_collection/src/BitSet.cj` | .cj | ✅ | — |
| 4 | `f_collection/src/Collection_test.cj` | .cj | ✅ | — |
| 5 | `f_collection/src/Dict.cj` | .cj | ✅ | — |
| 6 | `f_collection/src/DifferenceSetView.cj` | .cj | ✅ | — |
| 7 | `f_collection/src/ExtendCollection.cj` | .cj | ✅ | — |
| 8 | `f_collection/src/GrowSizePolicy.cj` | .cj | ✅ | — |
| 9 | `f_collection/src/Growable.cj` | .cj | ✅ | — |
| 10 | `f_collection/src/HashDict.cj` | .cj | ✅ | — |
| 11 | `f_collection/src/IntersectionSetView.cj` | .cj | ✅ | — |
| 12 | `f_collection/src/LinkedHashDict.cj` | .cj | ✅ | — |
| 13 | `f_collection/src/LinkedHashMap.cj` | .cj | ✅ | — |
| 14 | `f_collection/src/LinkedHashSet.cj` | .cj | ✅ | — |
| 15 | `f_collection/src/LinkedNode.cj` | .cj | ✅ | — |
| 16 | `f_collection/src/MapKeyValues.cj` | .cj | ✅ | — |
| 17 | `f_collection/src/PriorityQueue.cj` | .cj | ✅ | — |
| 18 | `f_collection/src/SetOp.cj` | .cj | ✅ | — |
| 19 | `f_collection/src/TreeDict.cj` | .cj | ✅ | — |
| 20 | `f_collection/src/UnionSetView.cj` | .cj | ✅ | — |
| 21 | `f_collection/src/ValueEqualMap.cj` | .cj | ✅ | — |

合计：`.cj` 19 个 / `.md` 2 个 / 共 21 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 3（并集视图、BitSet `set`、`&` 抹位）、设计 1（`firstEntry` 读即写）、可读性 1（注释垃圾）；语言特性上 `struct`/闭包/`Option` 用法本身无问题；安全性 0（本模块无外部输入解析、无凭据、无 SQL/路径拼接） |
| §1 死代码 | 3 | 已逐个检查本部分全部 `private` 符号（`growIfNeed`×2、`computePosition`×2、`HashDict/LinkedHashDict.newMap`×2、`LinkedHashMap.delete/getFirstEntry/getLastEntry/extract/turnToTail`、`PriorityQueue.doOffer/isFull/adjustUp/adjustDown`、`TreeDict.extract/newKey`）与 `internal` 符号（`BitSetIterator`、`HashKeyCollection`、`HashKeyIterator`、`LinkedHashKeyCollection`、`MapKeys`、`MapValues`、`PriorityQueueIterator`、`ConcurrentHashMapKeys`、`ComparableKey*` 系列、`HashDictIterator`、`LinkedHashDictIterator`）均有引用；`protected` 声明 0 个；死命中：三处 `retain` 死语句、4 个未使用 import、4 个无用泛型参数。`UnionSetIterator`、`LinkedNode.insertNext/removeNext/removePrev`、`LinkedNodeIterator.remove` 是**对外可达的 public**，仓内零引用按硬原则一不判死代码，仅在此记录 |
| §2 重复逻辑 | 5 | 已把约 320 个非测试函数体（含接口默认实现与 `extend`）压成「输入-输出-副作用」摘要两两比对；命中：HashDict/LinkedHashDict/TreeDict 三份同构（归一化 diff 仅 99/311 行）、SetOp 三份同构、Dict 与 ExtendNonConcurrentMap 两个默认实现逐字相同、`contains(all!)` ×7 与 `toArray` 模板 ×7、`retain`/`retainAll` 同语义。差异为业务要求的（如 `get(key, turn)` 与 `get(key)`、`HashDict` 有 `max` 与 `TreeDict` 无）未计入 |
| §3 空实现 | 2 | 视图 `retain`（构造即丢弃）与 `Node` 接口默认抛 `UnreachableException`；`DiscardOverSizePolicy` 的空体属有意设计（`f_base` 中已注释），不计 |
| §4 栈溢出 | 0 | 已检查全部函数：`growIfNeed`/`computePosition`/`adjustUp`/`adjustDown`/`turnTo`/`remove`/`next` 均为循环或单层转调，无自递归、无间接递归；`Node`/`LinkedNodeIterator` 的父子互指只在迭代中单向前进，无深度递归遍历；`PriorityQueue.doOffer` 的注释「递归改循环」已落地为 `while` |
| §5 OOM | 1 | BitSet 按哈希/下标无上限预分配（含负值回绕）；`HashDict.remove(all:)` 按 `all.size` 预分配已在「一般」中记为契约缺陷，量级受调用方集合约束，未单独计 OOM |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`batchRemove`、`HashKey` 装箱、`grow()` 重建三处只能进「待验证假设」，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本模块无任何锁（`grep Mutex/synchronized` 零命中），无临界区可评 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池调用，无「形式并发实际串行」路径 |
| §6.4 低效算法 | 2 | `batchRemove` 的 O(k·n) 尾部逐条删除（进优化方案）、视图 `size` O(n) 且被重复调用；具体耗时占比无数据，只作方案/假设 |
| §7 降堆内存方案 | 3 | SetOp 急切物化、`HashKey` 每键复制、`LinkedHashMap` 三份表示；均标 `无基线` |
| §8 降 CPU 方案 | 2 | `batchRemove` 收尾、视图 `size`/迭代器重建；均标 `无基线` |
| §9 local mode 可行性 | 0 | 逐个检查函数内临时对象：`grow()` 的临时 `Array` 赋给字段 `queue`（逃逸）、`growIfNeed` 的临时 `Array` 进入 `bits`（逃逸）、`toArray` 直接作为返回值（逃逸）、`HashKey` 被存入 `HashMap`（逃逸），无「函数内创建、函数内释放」的大对象；无前后峰值数据，收益无法证明，故不列方案 |
| §11 现有代码的 BUG（存量） | 26 | 上述「严重 6 + 一般 10 + 轻微 10」共 26 条全部为存量（快照模式无基线，blame 均指向 4be871f2f 格式提交）；边界/空值/并发/资源/契约五类均已逐函数核对 |
| §12 并发安全与锁粒度 | 1 | 模块内无全局 `var`、无单例、无静态可变状态；`BitSet`/`Dict` 系列/`LinkedHashMap`/`PriorityQueue` 均为实例级可变、无同步、未声明线程安全（与 std 非并发集合一致，不判缺陷）；下游 `f_cache.SyncLinkedHashMap` 与 `f_concurrent.SyncPriorityQueue` 已外加锁包装。唯一并发缺陷是 `ConcurrentHashMapKeys.toArray`（弱一致迭代 + `getOrThrow`）。锁粒度无可评对象 |
| §13 文档一致性 | 2 | README 三处签名/类名不符（合并为 1 条）、`BitSet(capacity)` 的 size 语义（1 条）；`README_en.md` 与中文版内容同步（含同一批错误），不存在只改一版的情况 |
| §14 功能完备性与 README 覆盖 | 1 | public API 未文档化：`LinkedHashMap.get(key, turn)`、`add(entry:)`、`entryView`、`LinkedHashSet.==/toString`；README 承诺的能力（BitSet/Dict/HashDict/LinkedHashDict/TreeDict/LinkedHashMap/LinkedHashSet/PriorityQueue/SetOp/三种视图/Extend* /ValueEqualMap）在代码中均有对应实现，无「承诺但缺失」 |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_collection.part1.txt` 一一对应，无缺项 |

### 第 2 部分

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
| 严重 | 6 |
| 一般 | 12 |
| 轻微 | 14 |
| 其中存量 | 6 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：这套集合代码的功能骨架是完整的（`Dict` 接口 + 三套底层 Map 包装 + LRU 链表 + 二叉堆 + 三种集合视图），但**「写完没验证」的痕迹很重**：`BitSet` 的三个核心方法各错一处（`set` 从不置位、`&` 抹掉整个字、哈希直接当位下标会爆内存），`UnionSetView` 的迭代器把并集写成交集导致视图恒为空，`ExtendMap.retain` 条件反向导致静默失效，`LinkedHashMap.remove(all:)` 只删索引不摘链且能让 `add` 死循环——这些都是读一遍代码就能认定的静态错误，却没有一条被现有测试覆盖（`Collection_test.cj` 的 18 个用例只覆盖 LinkedHashMap 4 个访问顺序、PriorityQueue 12 个、BitSet 1 个下标算子、`containsValue` 1 个）。阻塞项建议按「严重 6 条」全修，其中并集视图与 `retain` 因为签名是公开 API、下游 `f_concurrent.ConcurrentHashSet` 已在复用，优先级最高；`LinkedHashMap.remove(all:)` 属潜伏挂死，`f_log`/`f_cache` 正在使用该类型，也应尽快修。

`PriorityQueue` 的二叉堆改造（文件内注释标 PERF-1）方向正确、`adjustUp/adjustDown` 写法地道，`removeIf` 的堆序修复不完整是这次改造遗留的薄弱点。`HashDict`/`LinkedHashDict`/`TreeDict` 三份 250 行级复制是最大的维护风险源——本轮三个「一般」缺陷（`remove(all:)`、`toArray` 模板、`newKey` 重复）都是复制传播的直接后果，合并成一个基类后这类问题只需要修一次。文档侧 README 与实现已出现明显漂移（`TreeDict` 章节整段写成了 `LinkedHashDict`、`LinkedHashDict` 的 `max`/LRU 能力完全缺失、`PriorityQueue` 的 `growOnFull` 未记录），建议按源码重新生成并把样例纳入编译测试。

性能与内存方向没有可用的基线数据，报告里只给了 5 条待验证方案与 4 条假设，未做任何「能降 X%」的结论。

**第 2 部分**：本部分只有 `ValueEqualMap.cj`（83 行），是一层「给 Map 补 `containsValue`」的薄扩展：2 个接口 + 4 条 `extend` + 1 组并发 map 的值视图包装。**没有严重问题**——无递归、无预分配、无锁、无数据竞争、无空实现、无不可达代码；5 个公开声明全部对外可达（其中 `ConcurrentHashMapValueIterator` 未进 README，见第 6 条）。

主要风险集中在两处「说与做不一致」：一是 `ConcurrentHashMap.values()` 返回活视图，却被 `Collection<V>` 的类型语义包装成「一个集合」，并发写时 `size`/`isEmpty`/迭代会互相矛盾（std 文档已声明 size 非原子、迭代器非快照，本文件既未覆写也未注释），调用方极易写出 `size > 0` 之后 `next().getOrThrow()` 崩溃的代码；二是 README 承诺「所有 Map 实现」都能获得 `containsValue`，而本模块自己的 `Dict`/`TreeDict`/`HashDict`/`LinkedHashDict`（都已实现 `values()`）一个都没扩展，按文档写会编译失败。这两条属一般级、可排期修，均为存量。

其余 4 条是重复与收窄问题：包装器/迭代器与同包 `MapValues`/`MapValueIterator` 逐行同构（同包还已有 `Iterator.map` 的第三种写法）、两份 `containsValue` 循环可合并为继承、`K` 类型参数及其约束无意义、两个包装器的可见性与 README 登记不一致。它们不影响当前行为，但会放大后续维护成本，建议随下一次接口调整一起做。

存量问题共 6 条（一般 2 / 轻微 4），是否纳入修复待用户决定；本部分无本次改动引入的问题（快照基线）。模块整体风险以第 1 部分为主（该部分报出并集视图恒空、`BitSet.set` 不置位、`BitSet.&` 抹掉同字其余位、`LinkedHashMap.remove(all!)` 不摘链等 6 条严重缺陷），合并时请以两部分合计口径出模块结论。唯一测试覆盖参考：`Collection_test.cj:234-238` 只验证了 `HashMap.containsValue(3)` 一条，`ConcurrentHashMap` 值视图、谓词重载、`Dict` 家族均无用例。
