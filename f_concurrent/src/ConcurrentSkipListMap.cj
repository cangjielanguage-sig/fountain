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
import std.random.*
import std.collection.concurrent.ConcurrentMap
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

public class ConcurrentSkipListMap<K, V> where K <: Comparable<K> {
    private let zeroValue: K = unsafeZeroValue<K>()
    let MAX_LEVEL: Int64 = 16
    var headRef: AtomicReference<Node<K, V>>
    var size_: AtomicInt64

    private static func compare(a: ?K, b: ?K): Ordering {
        match((a, b)){
            case (Some(x), Some(y)) => x.compare(y)
            case (None, Some(y)) => LT
            case (Some(x), None) => GT
            case _ => EQ
        }
    }

    public init() {
        // 创建头哨兵节点（键为占位值，比较时特殊处理）
        this.headRef = AtomicReference(Node<K, V>.createHead(MAX_LEVEL))
        this.size_ = AtomicInt64(0)   // 初始化计数器
    }
    prop head: Node<K, V> {
        get() { headRef.load() }
    }
    private func randomLevel(): Int64 {
        var level: Int64 = 0
        while (Random().nextFloat64() < 0.5 && level < MAX_LEVEL) {
            level += 1
        }
        return level
    }

    // 判断一个节点是否为头哨兵
    private func isHead(node: Node<K, V>): Bool {
        node.isHead
    }

    // 核心查找：返回目标节点及其各层前驱/后继
    func findNode(key: K): FindResult<K, V> {
        var preds = Array<Option<Node<K, V>>>(MAX_LEVEL + 1) {_ => None}
        var succs = Array<Option<Node<K, V>>>(MAX_LEVEL + 1) {_ => None}

        var pred: Node<K, V> = head
        var curr: Option<Node<K, V>> = None

        for (level in MAX_LEVEL..=0 : -1) {
            curr = pred.next[level].load()
            while (true) {
                match (curr) {
                    case Some(node) =>
                        // 跳过哨兵节点的比较
                        if (!isHead(node) && node.key < key) {
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

        match (curr) {
            case Some(node) =>
                if (!isHead(node) && node.key == key) {
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
            // 使用 compare 函数，避免直接比较 Option 与 K
            if (!isHead(node) && compare(node.key, Some(key)) == LT) {
                pred = node
                curr = node.next[level].load()
            } else {
                break
            }
        }
        return pred
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
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let oldVal = node.value.load()
                    match(mode){
                        case Anyway | IfPresent => 
                            if (node.value.compareAndSwap(oldVal, genbox())) {
                                // 🔧 修复：如果旧值为 None，说明节点之前被逻辑删除，需补偿计数
                                if (oldVal.isNone()) {
                                    size_.fetchAdd(1)
                                }
                                return oldVal?.value
                            } else if(mode == IfPresent){
                                continue
                            }
                        case IfAbsent => return oldVal?.value
                    }
                case None where mode == IfPresent => return None
                case None =>
                    let level = randomLevel()
                    let newNode = Node(key, genbox(), level)
                    // 1) 先插入底层（level 0）
                    if (!tryInsertAtLevel(newNode, 0, result.preds[0].getOrThrow())) {
                        continue   // 底层插入失败，重试整个 add
                    }
                    // 底层插入成功，增加计数
                    size_.fetchAdd(1)

                    // 2) 插入更高层（尽力而为，失败则重试该层）
                    for (lvl in 1..=level) {
                        // 如果节点已被逻辑删除，则放弃高层插入
                        if (newNode.value.load().isNone()) {
                            break
                        }
                        var inserted = false
                        while (!inserted) {
                            let pred = findPredecessorAtLevel(key, lvl)
                            inserted = tryInsertAtLevel(newNode, lvl, pred)
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
        var currentPred = pred   // 使用可变局部变量，以便在循环内推进
        while (true) {
            let succ = currentPred.next[lvl].load()
            match (succ) {
                case Some(n) =>
                    if (!isHead(n)) {
                        let cmp = compare(n.key, newNode.key)
                        if (cmp == LT) {
                            // 后继键严格小于新键，说明前驱已过时
                            return false
                        } else if (cmp == EQ) {
                            // 发现相同键的节点
                            if (refEq(n, newNode)) {
                                // 已经插入过了
                                return true
                            } else {
                                // 遇到其他同键节点（例如已逻辑删除的残留），跳过它继续尝试
                                currentPred = n
                                continue
                            }
                        }
                        // cmp == GT：后继键大于新键，可以尝试插入
                    }
                case None => ()
            }
            newNode.next[lvl].store(succ)
            if (currentPred.next[lvl].compareAndSwap(succ, Some(newNode))) {
                return true
            }
            // CAS 失败，继续循环（succ 会被重新加载）
        }
        // 逻辑上不可达，但满足编译器要求
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
                    while (retries < 3) {   // 最多重试 3 次，避免死循环
                        let pred = findPredecessorAtLevel(k, lvl)
                        let succ = pred.next[lvl].load()
                        match (succ) {
                            case Some(n) where refEq(n, node) =>
                                let nodeNext = node.next[lvl].load()
                                if (pred.next[lvl].compareAndSwap(succ, nodeNext)) {
                                    break   // 摘除成功，进入下一层
                                }
                                // CAS 失败，重试
                                retries += 1
                            case _ =>
                                // 该层后继不是目标节点，跳过此层
                                break
                        }
                    }
                }
            case None => return
        }
    }

    // 尝试删除节点
    private func tryRemoveNode(node: Node<K, V>): Bool {
        let oldValOpt = node.value.load()
        match (oldValOpt) {
            case Some(v) =>
                if (node.value.compareAndSwap(oldValOpt, None)) {
                    physicallyRemove(node)
                    size_.fetchSub(1)
                    return true
                }
                return false
            case None =>
                physicallyRemove(node)
                return false
        }
    }

    // 帮助物理删除
    private func helpPhysicallyRemove(node: Node<K, V>): Unit {
        physicallyRemove(node)
    }

    // 清空
    public func clear(): Unit {
        headRef.store(Node<K, V>.createHead(MAX_LEVEL))
        size_.store(0)   // 重置计数
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
                                size_.fetchSub(1)
                                return Some(box.value)
                            }
                            continue   // CAS 失败，重试
                        case None =>
                            physicallyRemove(node)
                            return None
                    }
                case None => return None
            }
        }
        None<V>
    }
    // ---------- 删除 ----------
    public func remove(key: K): Option<V> {
        while (true) {
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let oldValOpt = node.value.load()
                    if (oldValOpt.isSome()) {
                        if (node.value.compareAndSwap(oldValOpt, None)) {
                            physicallyRemove(node)   // 逻辑删除成功，物理摘除
                            size_.fetchSub(1)
                            return oldValOpt?.value
                        }
                        // CAS 失败，继续重试（重新查找节点）
                        continue
                    } else {
                        // 节点已被其他线程逻辑删除，帮助物理清理后返回 None
                        physicallyRemove(node)
                        return None
                    }
                case None => return None
            }
        }
        None<V>
    }
    public func removeIf(predicate: (K, V) -> Bool): Unit {
        var pred = head
        var currOpt = pred.next[0].load()
        while (true) {
            match (currOpt) {
                case Some(curr) =>
                    if (isHead(curr)) {
                        pred = curr
                        currOpt = curr.next[0].load()
                        continue
                    }
                    let valOpt = curr.value.load()
                    match (valOpt) {
                        case Some(box) =>
                            match (curr.key) {
                                case Some(k) =>
                                    if (predicate(k, box.value)) {
                                        if (tryRemoveNode(curr)) {
                                            currOpt = pred.next[0].load()
                                        } else {
                                            helpPhysicallyRemove(curr)
                                            currOpt = curr.next[0].load()
                                        }
                                    } else {
                                        pred = curr
                                        currOpt = curr.next[0].load()
                                    }
                                case None =>
                                    tryRemoveNode(curr)
                                    currOpt = curr.next[0].load()   // 修复：移动指针
                            }
                        case None =>
                            helpPhysicallyRemove(curr)
                            currOpt = curr.next[0].load()           // 修复：移动指针
                    }
                case None => break
            }
        }
    }

    // 物理删除（逐层摘除）
    private func doRemoveEachLevel(key: K, node: Node<K, V>) {
        for (lvl in node.level..=0 : -1) {
            while (true) {
                // 实时查找当前层的前驱节点
                let pred = findPredecessorAtLevel(key, lvl)
                let succ = pred.next[lvl].load()
                match (succ) {
                    case Some(n) where refEq(n, node) =>
                        let nodeNext = node.next[lvl].load()
                        if (pred.next[lvl].compareAndSwap(succ, nodeNext)) {
                            break   // 该层摘除成功
                        }
                        // CAS 失败，继续循环，重新获取 pred
                    case _ =>
                        break   // 该层后继不是目标节点，跳过此层
                }
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
        let view = ConcurrentSkipListEntryViewImpl(this, key)
        fn(view)
        let v = view.value
        match(v){
            case Some(x) => add(key, x)
            case _ => remove(key)
        }
        v
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
                    if (let Some(oldVal) <- currVal?.value && predicate(oldVal) && node
                        .value
                        .compareAndSwap(currVal, Box<V>(eval(oldVal)))) {
                        return oldVal
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
    private let map: ConcurrentSkipListMap<K, V>
    private let k: K
    var v: ?V

    init(map: ConcurrentSkipListMap<K, V>, key: K) {
        this.map = map
        this.k = key
        this.v = map.get(key)
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