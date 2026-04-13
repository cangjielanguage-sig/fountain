/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::f_concurrent

import std.sync.*
import std.collection.*
import std.core.*
import std.collection.concurrent.ConcurrentMap
import std.time.DateTime
import fountain::f_base.*

// 跳表节点：键值对 + 多层前向指针
class Node<K, V> where K <: Comparable<K> {
    public let key: ?K
    public let value: AtomicOptionReference<Box<V>>
    public let next: Array<AtomicOptionReference<Node<K, V>>>
    public let level: Int64
    public let isHead: Bool   // 是否为头哨兵节点

    init(key: K, valbox: ?Box<V>, level: Int64) {
        this.key = key
        this.value = AtomicOptionReference<Box<V>>(if (let Some(x) <- valbox) {
            x
        } else {
            None
        })
        this.level = level
        this.next = Array<AtomicOptionReference<Node<K, V>>>(level + 1) {
            _ => AtomicOptionReference<Node<K, V>>()
        }
        this.isHead = false
    }

    // 仅用于创建头节点的特殊构造器，key 为占位值
    private init(level: Int64) {
        this.key = None<K>
        this.value = AtomicOptionReference<Box<V>>()
        this.level = level
        this.next = Array<AtomicOptionReference<Node<K, V>>>(level + 1) {
            _ => AtomicOptionReference<Node<K, V>>()
        }
        this.isHead = true
    }
    public static func createHead(level: Int64): Node<K, V> {
        // 使用全零值占位（实际比较逻辑会通过 isHead 跳过）
        return Node<K, V>(level)
    }
}
enum AddMode{
    | Anyway
    | IfAbsent
    | IfPresent

    public operator func ==(mode: AddMode): Bool {
        match((this, mode)){
            case (Anyway, Anyway) | (IfAbsent, IfAbsent) | (IfPresent, IfPresent) => true
            case _ => false
        }
    }
}
// 查找结果：包含找到的节点及每层前驱/后继
class FindResult<K, V> where K <: Comparable<K> {
    public var node: Option<Node<K, V>>
    public var preds: Array<Option<Node<K, V>>>
    public var succs: Array<Option<Node<K, V>>>

    public init(node: Option<Node<K, V>>, preds: Array<Option<Node<K, V>>>, succs: Array<Option<Node<K, V>>>) {
        this.node = node
        this.preds = preds
        this.succs = succs
    }
}

// findNode 线程局部缓存：预分配两个大小为 MAX_LEVEL+1 的数组
class FindNodeCache<K, V> where K <: Comparable<K> {
    public let preds: Array<Option<Node<K, V>>> = Array<Option<Node<K, V>>>(17) { _ => None }
    public let succs: Array<Option<Node<K, V>>> = Array<Option<Node<K, V>>>(17) { _ => None }
}

public class ConcurrentSkipListMap<K, V> where K <: Comparable<K> {
    private let zeroValue: K = unsafeZeroValue<K>()
    let MAX_LEVEL: Int64 = 16
    // 线程局部缓存 findNode 所需的数组，避免每次分配（每个 map 实例一个）
    private let findNodeCache: ThreadLocal<FindNodeCache<K, V>>
    // 根据 size 动态计算实际使用的最大层级（弱一致性，允许偶尔偏差）
    private func effectiveMaxLevel(): Int64 {
        let s = size_.load()
        if (s < 100) { 8 }
        else if (s < 1000) { 12 }
        else { MAX_LEVEL }
    }
    var headRef: AtomicReference<Node<K, V>>
    var size_: AtomicInt64
    var epoch: AtomicInt64   // 代际计数器，clear() 时递增，用于检测并发修改
    private static let seedGen = AtomicInt64((DateTime.now() - DateTime.UnixEpoch).toNanoseconds())   // 全局种子生成器
    var seed: AtomicInt64   // 并发安全的随机种子，替代非线程安全的 Random

    private static func compare(a: ?K, b: ?K): Ordering {
        match((a, b)){
            case (Some(x), Some(y)) => x.compare(y)
            case (None, Some(y)) => LT
            case (Some(x), None) => GT
            case _ => EQ
        }
    }

    @OverflowWrapping
    public init() {
        // 创建头哨兵节点（键为占位值，比较时特殊处理）
        this.headRef = AtomicReference(Node<K, V>.createHead(MAX_LEVEL))
        this.size_ = AtomicInt64(0)   // 初始化计数器
        this.epoch = AtomicInt64(0)   // 初始化代际计数器
        this.seed = AtomicInt64(seedGen.fetchAdd(1) * 6364136223846793005 + 1442695040888963407)  // LCG 混淆初始种子
        this.findNodeCache = ThreadLocal<FindNodeCache<K, V>>()
    }
    prop head: Node<K, V> {
        get() { headRef.load() }
    }
    // 使用 XorShift64 生成随机数，基于 AtomicInt64 种子实现无锁并发安全
    @OverflowWrapping
    private func xorShift64(): Int64 {
        var x = seed.fetchAdd(1)
        x ^= (x << 13)
        x ^= (x >> 7)
        x ^= (x << 17)
        return x
    }

    private func randomLevel(): Int64 {
        var level: Int64 = 0
        let effectiveMax = effectiveMaxLevel()
        // 每次随机取 1 bit：如果为 0 则继续提升层级（约 50% 概率）
        while (level < effectiveMax) {
            let r = xorShift64()
            // 检查最低位是否为 0（约 50% 概率）
            if ((r & (1 << 63)) == 0) {
                level += 1
            } else {
                break
            }
        }
        return level
    }

    // 判断一个节点是否为头哨兵
    private func isHead(node: Node<K, V>): Bool {
        node.isHead
    }

    // 核心查找：返回目标节点及其各层前驱/后继
    func findNode(key: K): FindResult<K, V> {
        // 使用线程局部缓存的数组，避免每次分配
        let cache = findNodeCache.getOrCompute { FindNodeCache<K, V>() }
        // 清空数组（复用前必须清理）
        for (i in 0..cache.preds.size) {
            cache.preds[i] = None
            cache.succs[i] = None
        }
        let preds = cache.preds
        let succs = cache.succs

        var pred: Node<K, V> = head
        var curr: Option<Node<K, V>> = None

        for (level in MAX_LEVEL..=0 : -1) {
            curr = pred.next[level].load()
            while (true) {
                match (curr) {
                    case Some(node) =>
                        if (!isHead(node) && node.key < key) {
                            // 延迟检查：遍历时跳过 value.load()，仅在找到目标 key 时检查
                            pred = node
                            curr = node.next[level].load()
                        } else {
                            break
                        }
                    case None => break
                }
            }
            preds[level] = Some(pred)
            succs[level] = curr
        }

        // 仅在找到目标 key 时检查 value 是否已被逻辑删除
        match (curr) {
            case Some(node) =>
                if (!isHead(node) && node.key == key) {
                    let nodeVal = node.value.load()
                    if (nodeVal.isNone()) {
                        // 节点已被逻辑删除，视为未找到
                        return FindResult(None, preds, succs)
                    }
                    return FindResult(Some(node), preds, succs)
                }
            case None => ()
        }
        return FindResult(None, preds, succs)
    }
 
    // 查找指定层的前驱节点（从 head 开始）
    private func findPredecessorAtLevel(key: K, level: Int64): Node<K, V> {
        var pred = head
        var curr = pred.next[level].load()
        while (let Some(node) <- curr) {
            if (!isHead(node) && compare(node.key, Some(key)) == LT) {
                // 遇到逻辑删除节点，主动清理并重新加载
                let nodeVal = node.value.load()
                if (nodeVal.isNone()) {
                    let nodeNext = node.next[level].load()
                    pred.next[level].compareAndSwap(curr, nodeNext)
                    curr = pred.next[level].load()
                    continue
                }
                pred = node
                curr = node.next[level].load()
            } else {
                break
            }
        }
        return pred
    }
    // 从 head 开始遍历，检查 target 是否在跳表中可达
    private func isReachable(target: Node<K, V>): Bool {
        var pred: Node<K, V> = head
        for (level in MAX_LEVEL..=0 : -1) {
            var curr = pred.next[level].load()
            while (true) {
                match (curr) {
                    case Some(node) =>
                        if (refEq(node, target)) {
                            return true
                        }
                        if (!isHead(node) && compare(node.key, target.key) == LT) {
                            pred = node
                            curr = node.next[level].load()
                        } else {
                            break
                        }
                    case None => break
                }
            }
        }
        return false
    }

    // 轻量可达性验证：检查 level 0 前驱的 next[0] 是否仍指向目标节点
    // 替代 isReachable 的 O(log n) 全表遍历，降为 O(1)
    private func validateNode(node: Node<K, V>, result: FindResult<K, V>): Bool {
        match (result.preds[0]) {
            case Some(pred) =>
                let succ = pred.next[0].load()
                match (succ) {
                    case Some(n) => refEq(n, node)
                    case None => false
                }
            case None => false
        }
    }

    private func add(mode: AddMode, key: K, valfn: () -> V): ?V {
        var valbox = None<Box<V>>
        func genbox(){
            if(valbox.isNone()){
                valbox = Box<V>(valfn())
            }
            valbox
        }
        while (true) {
            let curEpoch = epoch.load()   // 捕获当前代际
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let oldVal = node.value.load()
                    match(mode){
                        case Anyway =>
                            if (oldVal.isNone()) {
                                physicallyRemove(node)   // 遇到逻辑删除节点，帮助清理后重试
                                continue
                            }
                            // 验证节点仍可达（防止在已物理删除节点上 CAS 导致更新丢失）
                            if (!validateNode(node, result)) {
                                physicallyRemove(node)
                                continue
                            }
                            if (node.value.compareAndSwap(oldVal, genbox())) {
                                return oldVal?.value
                            }
                        case IfPresent =>
                            if (oldVal.isNone()) {
                                physicallyRemove(node)
                                return None
                            }
                            if (!validateNode(node, result)) {
                                physicallyRemove(node)
                                return None
                            }
                            if (node.value.compareAndSwap(oldVal, genbox())) {
                                return oldVal?.value
                            }
                            continue
                        case IfAbsent =>
                            if (oldVal.isNone()) {
                                physicallyRemove(node)
                                continue
                            }
                            return oldVal?.value
                    }
                case None where mode == IfPresent => return None
                case None =>
                    let level = randomLevel()
                    let newNode = Node(key, genbox(), level)
                    let pred0 = result.preds[0].getOrThrow()
                    if (!tryInsertAtLevel(newNode, 0, pred0)) {
                        continue
                    }
                    // 插入成功后验证前驱是否可达，防止新节点悬挂在已物理删除节点上
                    if (!isHead(pred0) && pred0.value.load().isNone()) {
                        // 前驱已被逻辑删除，新节点可能不可达
                        // 尝试逻辑删除新节点并补偿 size_
                        if (newNode.value.compareAndSwap(genbox(), None)) {
                            physicallyRemove(newNode)
                            // size_ 尚未递增，无需补偿
                            continue
                        }
                        // newNode 已被其他线程 remove（CAS 失败说明其他线程已逻辑删除），
                        // 其他线程的 remove 会 fetchSub(1)，所以如果新节点不可达，
                        // size_ 可能已多算。但 newNode 被其他线程找到说明它可达，无需补偿。
                    }
                    size_.fetchAdd(1)
                    // 检查代际是否变化（clear 可能已执行），若变化则补偿 size_ 并重试
                    if (epoch.load() != curEpoch) {
                        // 新节点可能挂在旧链表上（不可达），需回滚
                        if (newNode.value.compareAndSwap(genbox(), None)) {
                            physicallyRemove(newNode)
                            size_.fetchSub(1)
                            continue
                        }
                        // 其他线程已 remove 该节点，其 fetchSub 已执行
                        // 但我们的 fetchAdd 需要补偿
                        size_.fetchSub(1)
                        continue
                    }
                    // 限制高层插入重试次数
                    for (lvl in 1..=level) {
                        if (newNode.value.load().isNone()) {
                            break
                        }
                        var inserted = false
                        var retries = 0
                        while (!inserted && retries < 5) {
                            let pred = findPredecessorAtLevel(key, lvl)
                            if (!isHead(pred) && pred.value.load().isNone()) {
                                retries += 1
                                continue
                            }
                            let succ = pred.next[lvl].load()
                            if (let Some(n) <- succ && !isHead(n) && compare(n.key, newNode.key) == EQ && !refEq(n, newNode)) {
                                break
                            } else if (tryInsertAtLevel(newNode, lvl, pred)) {
                                inserted = true
                            } else {
                                retries += 1
                            }
                        }
                        if (!inserted) {
                            break
                        }
                    }
                    return None
            }
        }
        None<V>
    }
    // 插入/更新
    public func add(key: K, value: V): Option<V> {
        add(Anyway, key){value}
    }

    private func tryInsertAtLevel(newNode: Node<K, V>, lvl: Int64, pred: Node<K, V>): Bool {
        var currentPred = pred
        var retries = 0
        while (retries < 3) {   // 限制重试次数，避免死循环
            let succ = currentPred.next[lvl].load()
            match (succ) {
                case Some(n) =>
                    if (!isHead(n)) {
                        let cmp = compare(n.key, newNode.key)
                        if (cmp == LT) {
                            return false
                        } else if (cmp == EQ) {
                            if (refEq(n, newNode)) {
                                return true
                            } else {
                                return false
                            }
                        }
                        // 后继已被逻辑删除，帮助清理后返回重试
                        if (n.value.load().isNone()) {
                            let nodeNext = n.next[lvl].load()
                            currentPred.next[lvl].compareAndSwap(succ, nodeNext)
                            return false
                        }
                    }
                case None => ()
            }
            // 前驱已被逻辑删除，直接返回重试
            if (!isHead(currentPred) && currentPred.value.load().isNone()) {
                return false
            }
            newNode.next[lvl].store(succ)
            if (currentPred.next[lvl].compareAndSwap(succ, Some(newNode))) {
                return true
            }
            retries += 1
        }
        return false
    }

    // ---------- 仅当键不存在时插入 ----------
    public func addIfAbsent(key: K, value: V): Option<V> {
        add(IfAbsent, key){value}
    }
    public func addIfPresent(key: K, value: V): Option<V> {
        add(IfPresent, key){value}
    }

    // 物理删除（内部自动查找前驱）
    private func physicallyRemove(node: Node<K, V>) {
        match (node.key) {
            case Some(k) =>
                for (lvl in node.level..=0 : -1) {
                    var retries = 0
                    while (retries < 3) {
                        // 节点已被复活，终止物理删除
                        if (node.value.load().isSome()) {
                            return
                        }
                        let pred = findPredecessorAtLevel(k, lvl)
                        // 前驱已被逻辑删除，放弃本层清理（findPredecessor会顺带清理，下次重试即可）
                        if (!isHead(pred) && pred.value.load().isNone()) {
                            break
                        }
                        let succ = pred.next[lvl].load()
                        match (succ) {
                            case Some(n) where refEq(n, node) =>
                                let nodeNext = node.next[lvl].load()
                                if (pred.next[lvl].compareAndSwap(succ, nodeNext)) {
                                    break
                                }
                                retries += 1
                            case _ =>
                                break
                        }
                    }
                }
            case None => return
        }
    }

    // 尝试删除节点
    private func tryRemoveNode(node: Node<K, V>, curEpoch: Int64): Bool {
        let oldValOpt = node.value.load()
        match (oldValOpt) {
            case Some(v) =>
                if (node.value.compareAndSwap(oldValOpt, None)) {
                    physicallyRemove(node)
                    // 检查代际是否变化，若变化则跳过 size_ 递减
                    if (epoch.load() == curEpoch) {
                        size_.fetchSub(1)
                    }
                    return true
                }
                return false
            case None =>
                // 移除冗余的 physicallyRemove 调用，交给外层或 findNode 处理
                return false
        }
    }

    // 帮助物理删除
    internal func helpPhysicallyRemove(node: Node<K, V>): Unit {
        physicallyRemove(node)
    }

    // 清空（原子操作）
    public func clear(): Unit {
        // 先递增 epoch，使并发 add/remove 检测到代际变化
        let oldEpoch = epoch.fetchAdd(1)
        // 替换 head，断开旧链表
        headRef.store(Node<K, V>.createHead(MAX_LEVEL))
        // 重置 size_
        size_.store(0)
    }

    // ---------- 查找 ----------
    public func get(key: K): Option<V> {
        var pred: Node<K, V> = head
        var curr: Option<Node<K, V>> = None

        for (level in MAX_LEVEL..=0 : -1) {
            curr = pred.next[level].load()
            while (true) {
                match (curr) {
                    case Some(node) =>
                        if (!isHead(node) && compare(node.key, key) == LT) {
                            pred = node
                            curr = node.next[level].load()
                        } else {
                            break
                        }
                    case None => break
                }
            }
        }

        match (curr) {
            case Some(node) =>
                if (!isHead(node) && compare(node.key, key) == EQ) {
                    return node.value.load()?.value
                }
            case None => ()
        }
        return None
    }

    public func remove(key: K, predicate: (V) -> Bool): Option<V> {
        while (true) {
            let curEpoch = epoch.load()   // 捕获当前代际
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let oldValOpt = node.value.load()
                    match (oldValOpt) {
                        case Some(box) =>
                            if (!predicate(box.value)) {
                                return None
                            }
                            if (node.value.compareAndSwap(oldValOpt, None)) {
                                physicallyRemove(node)
                                // 检查代际是否变化，若变化则跳过 size_ 递减
                                if (epoch.load() == curEpoch) {
                                    size_.fetchSub(1)
                                }
                                return Some(box.value)
                            }
                            continue   // CAS 失败，重试
                        case None =>
                            // 节点已被其他线程逻辑删除，重试让 findNode 自动清理
                            continue
                    }
                case None => return None
            }
        }
        None<V>
    }
    // ---------- 删除 ----------
    public func remove(key: K): Option<V> {
        while (true) {
            let curEpoch = epoch.load()   // 捕获当前代际
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let oldValOpt = node.value.load()
                    if (oldValOpt.isSome()) {
                        if (node.value.compareAndSwap(oldValOpt, None)) {
                            physicallyRemove(node)   // 逻辑删除成功，物理摘除
                            // 检查代际是否变化，若变化则跳过 size_ 递减
                            if (epoch.load() == curEpoch) {
                                size_.fetchSub(1)
                            }
                            return oldValOpt?.value
                        }
                        // CAS 失败，继续重试
                        continue
                    } else {
                        // 节点已被其他线程逻辑删除，无需显式调用 physicallyRemove
                        // 直接 continue，findNode 会在下一次调用时自动清理该节点
                        continue
                    }
                case None => return None
            }
        }
        None<V>
    }
    public func removeIf(predicate: (K, V) -> Bool): Unit {
        let curEpoch = epoch.load()   // 捕获当前代际
        var currOpt = head.next[0].load()
        while (true) {
            match (currOpt) {
                case Some(curr) =>
                    if (isHead(curr)) {
                        currOpt = curr.next[0].load()
                        continue
                    }
                    let valOpt = curr.value.load()
                    match (valOpt) {
                        case Some(box) =>
                            match (curr.key) {
                                case Some(k) =>
                                    if (predicate(k, box.value)) {
                                        tryRemoveNode(curr, curEpoch)
                                    }
                                case None =>
                                    tryRemoveNode(curr, curEpoch)
                            }
                        case None =>
                            helpPhysicallyRemove(curr)
                    }
                    currOpt = curr.next[0].load()   // 单向遍历，无需维护 pred
                case None => break
            }
        }
    }


    // ---------- 辅助方法 ----------
    public func contains(key: K): Bool {
        return get(key).isSome()
    }

    public prop size: Int64 {
        get() {
            size_.load()
        }
    }

    public func isEmpty(): Bool {
        return size == 0
    }
    
    public func entryView(key: K, fn: (MapEntryView<K, V>) -> Unit): ?V {
        while (true) {
            let curEpoch = epoch.load()   // 捕获当前代际
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let oldVal = node.value.load()
                    if (oldVal.isNone()) {
                        physicallyRemove(node)
                        // 键不存在（逻辑删除），走插入路径
                        let view = ConcurrentSkipListEntryViewImpl(key, None<V>)
                        fn(view)
                        let v = view.value
                        match (v) {
                            case Some(x) =>
                                let res = addIfAbsent(key, x)
                                if (res.isSome()) {
                                    continue
                                }
                                return v
                            case _ => return v
                        }
                    }
                    // 键存在：在 CAS 循环中原子地更新
                    // 基于当前 load 到的值构建 view，确保 fn 看到的值和 CAS 期望值一致
                    let view = ConcurrentSkipListEntryViewImpl(key, oldVal?.value)
                    fn(view)
                    let newVal = view.value
                    match (newVal) {
                        case Some(x) =>
                            let newBox = Box<V>(x)
                            if (node.value.compareAndSwap(oldVal, newBox)) {
                                return oldVal?.value
                            }
                            continue
                        case None =>
                            if (node.value.compareAndSwap(oldVal, None)) {
                                physicallyRemove(node)
                                // 检查代际是否变化，若变化则跳过 size_ 递减
                                if (epoch.load() == curEpoch) {
                                    size_.fetchSub(1)
                                }
                                return oldVal?.value
                            }
                            continue
                    }
                case None =>
                    // 键不存在
                    let view = ConcurrentSkipListEntryViewImpl(key, None<V>)
                    fn(view)
                    let v = view.value
                    match (v) {
                        case Some(x) =>
                            let res = addIfAbsent(key, x)
                            if (res.isSome()) {
                                continue
                            }
                            return v
                        case _ => return v
                    }
            }
        }
        None<V>
    }
    public func entryView(key: K, fn: (K, ?V) -> ?V): ?V {
        this.entryView(key) {
            entry => entry.value = fn(key, entry.value)
        }
    }
}

// Map 接口要求的方法
extend<K, V> ConcurrentSkipListMap<K, V> <: ConcurrentMap<K, V> where K <: Comparable<K> {
    public func putIfAbsent(key: K, value: V): ?V {
        addIfAbsent(key, value)
    }
    public func contains(all!: Collection<K>): Bool {
        for (k in all where !contains(k)) {
            return false
        }
        true
    }
    public func keys(): EquatableCollection<K> {
        SkipListKeyCollection<K, V>(this)
    }

    public func values(): Collection<V> {
        SkipListValueCollection<K, V>(this)
    }

    public func iterator(): Iterator<(K, V)> {
        return EntryIterator<K, V>(head)
    }
    public func put(key: K, value: V): ?V {
        add(key, value)
    }
    public func add(all!: Collection<(K, V)>): Unit {
        for ((k, v) in all) {
            add(k, v)
        }
    }

    // 无条件替换
    public func replace(key: K, value: V): Option<V> {
        while (true) {
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let currVal = node.value.load()
                    if (currVal.isNone()) {
                        helpPhysicallyRemove(node)
                        return None  // 键不存在，不替换
                    }
                    if (node.value.compareAndSwap(currVal, Box<V>(value))) {
                        return currVal?.value
                    }
                case None => return None
            }
        }
        None<V>
    }
    public func replace(key: K, eval: (V) -> V): ?V {
        while (true) {
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let currVal = node.value.load()
                    if (currVal.isNone()) {
                        helpPhysicallyRemove(node)
                        return None
                    }
                    if (let Some(oldVal) <- currVal?.value && node.value.compareAndSwap(currVal, Box<V>(eval(oldVal)))) {
                        return oldVal
                    }
                case None => return None
            }
        }
        None<V>
    }
    public func replace(key: K, predicate: (V) -> Bool, eval: (V) -> V): ?V {
        while (true) {
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let currVal = node.value.load()
                    if (currVal.isNone()) {
                        helpPhysicallyRemove(node)
                        return None
                    }
                    if (let Some(oldVal) <- currVal?.value) {
                        if (!predicate(oldVal)) {
                            return None
                        }
                        if (node.value.compareAndSwap(currVal, Box<V>(eval(oldVal)))) {
                            return oldVal
                        }
                    }
                case None => return None
            }
        }
        None<V>
    }
    public func remove(all!: Collection<K>): Unit {
        for (key in all) {
            remove(key)
        }
    }
    public operator func [](key: K): V {
        return get(key).getOrThrow()
    }
    public operator func [](key: K, value!: V): Unit {
        add(key, value)
    }
}

private class EntryIterator<K, V> <: Iterator<(K, V)> where K <: Comparable<K> {
    private var current: Option<Node<K, V>>

    public init(head: Node<K, V>) {
        this.current = head.next[0].load()
    }

    public func next(): Option<(K, V)> {
        while (let Some(node) <- current) {
            current = node.next[0].load()
            if (let Some(v) <- node.value.load()) {
                match (node.key) {
                    case Some(k) => return Some((k, v.value))
                    case _ => continue
                }
            }
        }
        None
    }
}

class SkipListKeyCollection<K, V> <: EquatableCollection<K> where K <: Comparable<K> {
    SkipListKeyCollection(private let map: ConcurrentSkipListMap<K, V>) {}
    public func contains(item: K): Bool {
        return map.contains(item)
    }
    public func contains(all!: Collection<K>): Bool {
        for (k in all where !contains(k)) {
            return false
        }
        true
    }
    public prop size: Int64 {
        get() {
            return map.size
        }
    }
    public func isEmpty(): Bool {
        return map.isEmpty()
    }
    public func iterator(): Iterator<K> {
        return map.iterator().map {tpl => tpl[0]}
    }
}

class SkipListValueCollection<K, V> <: Collection<V> where K <: Comparable<K> {
    SkipListValueCollection(private let map: ConcurrentSkipListMap<K, V>) {}
    public prop size: Int64 {
        get() {
            return map.size
        }
    }
    public func isEmpty(): Bool {
        return map.isEmpty()
    }
    public func iterator(): Iterator<V> {
        return map.iterator().map {tpl => tpl[1]}
    }
}

class ConcurrentSkipListEntryViewImpl<K, V> <: MapEntryView<K, V> where K <: Comparable<K> {
    private let k: K
    var v: ?V

    init(key: K, initialValue: ?V) {
        this.k = key
        this.v = initialValue
    }

    public prop key: K {
        get() {
            k
        }
    }

    public mut prop value: ?V {
        get() {
            v
        }
        set(value) {
            this.v = value
        }
    }
}