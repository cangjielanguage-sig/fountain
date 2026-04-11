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
    public let key: K
    public let value: AtomicOptionReference<Box<V>>
    public let next: Array<AtomicOptionReference<Node<K, V>>>
    public let level: Int64

    init(key: K, value: ?V, level: Int64) {
        this.key = key
        this.value = AtomicOptionReference<Box<V>>(if (let Some(x) <- value) {
            Box<V>(x)
        } else {
            None
        })
        this.level = level
        this.next = Array<AtomicOptionReference<Node<K, V>>>(level + 1) {
            _ => AtomicOptionReference<Node<K, V>>()
        }
    }

    // 仅用于创建头节点的特殊构造器，key 为占位值
    private init(headKey: K, level: Int64) {
        this.key = headKey
        this.value = AtomicOptionReference<Box<V>>()
        this.level = level
        this.next = Array<AtomicOptionReference<Node<K, V>>>(level + 1) {
            _ => AtomicOptionReference<Node<K, V>>()
        }
    }

    public static func createHead(level: Int64): Node<K, V> {
        // 使用全零值占位（实际比较逻辑会跳过对头节点的键比较）
        return Node<K, V>(unsafeZeroValue<K>(), level)
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
    let MAX_LEVEL: Int64 = 16
    var head: Node<K, V>
    var size_: AtomicInt64

    private static func compare(a: ?K, b: ?K): Ordering {
        match((a, b)){
            case (Some(x), Some(v)) => x.compare(v)
            case (None, Some(_)) => LT
            case (Some(_), None) => GT
            case _ => EQ
        }
    }

    public init() {
        // 创建头哨兵节点（键为占位值，比较时特殊处理）
        this.head = Node<K, V>.createHead(MAX_LEVEL)
        this.size_ = AtomicInt64(0)
    }

    private func randomLevel(): Int64 {
        var level: Int64 = 0
        while (Random().nextFloat64() < 0.5 && level < MAX_LEVEL) {
            level += 1
        }
        return level
    }

    // 判断一个节点是否为头哨兵（头节点键视为 -∞）
    private func isHead(node: Node<K, V>): Bool {
        // 头节点是唯一的且 level == MAX_LEVEL
        return node.level == MAX_LEVEL
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

    // ---------- 插入/更新 ----------
    public func add(key: K, value: V): Option<V> {
        while (true) {
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let oldVal = node.value.load()
                    if (node.value.compareAndSwap(oldVal, Some(Box<V>(value)))) {
                        return oldVal?.value
                    }
                // CAS 失败，重试
                case None =>
                    let level = randomLevel()
                    let newNode = Node<K, V>(key, value, level)

                    for (lvl in 0..=level) {
                        while (true) {
                            let pred = result.preds[lvl].getOrThrow()
                            let succ = pred.next[lvl].load()

                            // 验证 pred 是否仍然指向预期的后继
                            if (let Some(node) <- succ && !isHead(node) && compare(node.key, key) == LT) {
                                break // pred 已过期，重新查找外层
                            }

                            let currentSucc = pred.next[lvl].load()
                            match((succ?.key, currentSucc?.key)){
                                case (Some(x), Some(y)) where compare(x, y) != EQ => continue
                                case (Some(_), None) | (None, Some(_)) => continue
                                case _ => ()
                            }

                            newNode.next[lvl].store(succ)
                            if (pred.next[lvl].compareAndSwap(succ, Some(newNode))) {
                                break // 当前层插入成功
                            }
                        }
                    }

                    size_.fetchAdd(1)
                    return None
            }
        }
        None<V>
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

    // ---------- 删除 ----------
    public func remove(key: K): Option<V> {
        while (true) {
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    let oldVal = node.value.load()
                    if (node.value.compareAndSwap(oldVal, None)) {
                        // 物理删除：从各层链表中摘除
                        for (lvl in node.level..=0 : -1) {
                            while (true) {
                                let pred = result.preds[lvl].getOrThrow()
                                let succ = pred.next[lvl].load()

                                match (succ) {
                                    case Some(n) =>
                                        if (!isHead(n) && n.key < key) {
                                            break
                                        }
                                    case None => ()
                                }

                                let nodeNext = node.next[lvl].load()
                                if (pred.next[lvl].compareAndSwap(succ, nodeNext)) {
                                    break
                                }
                            }
                        }
                        size_.fetchSub(1)
                        return oldVal?.value
                    }
                // CAS 失败，重试
                case None => return None
            }
        }
        None<V>
    }
    public func remove(key: K, predicate: (V) -> Bool): Option<V> {
        while (true) {
            let result = findNode(key)
            match (result.node) {
                case Some(node) =>
                    // 读取当前值（Option<V>）
                    let oldValOpt = node.value.load()
                    match (oldValOpt) {
                        case Some(box) =>
                            // 检查谓词是否满足
                            if (!predicate(box.value)) {
                                // 不满足条件，放弃删除
                                return Option.None
                            }
                            // 满足谓词，尝试逻辑删除
                            if (node.value.compareAndSwap(oldValOpt, Option.None)) {
                                // 物理删除：从各层链表中摘除
                                for (lvl in (node.level)..=0) {
                                    while (true) {
                                        let pred = result.preds[lvl].getOrThrow()
                                        let succ = pred.next[lvl].load()

                                        match (succ) {
                                            case Some(n) =>
                                                if (!isHead(n) && n.key < key) {
                                                    break
                                                }
                                            case None => ()
                                        }

                                        let nodeNext = node.next[lvl].load()
                                        if (pred.next[lvl].compareAndSwap(succ, nodeNext)) {
                                            break
                                        }
                                    }
                                }
                                size_.fetchSub(1)
                                return Option.Some(box.value)
                            }
                        // CAS 失败，重试外层循环
                        case None =>
                            // 节点已被逻辑删除
                            return Option.None
                    }
                case None =>
                    // 键不存在
                    return Option.None
            }
        }
        None<V>
    }

    public func removeIf(predicate: (K, V) -> Bool): Unit {
        var pred: Node<K, V> = head
        var currOpt = pred.next[0].load()

        while (true) {
            match (currOpt) {
                case Some(curr) =>
                    // 跳过哨兵节点（实际上底层链表不应出现，但安全处理）
                    if (isHead(curr)) {
                        pred = curr
                        currOpt = curr.next[0].load()
                        continue
                    }

                    let valOpt = curr.value.load()
                    match (valOpt) {
                        case Some(box) =>
                            if (predicate(curr.key, box.value)) {
                                // 尝试删除当前节点
                                if (tryRemoveNode(curr, pred)) {
                                    // 删除成功，curr 已从链表中摘除，currOpt 更新为 pred 的后继
                                    currOpt = pred.next[0].load()
                                    continue
                                }
                                // 删除失败（并发竞争），重新尝试删除同一个节点
                                // 注意：此时 pred 可能已失效，但 curr 仍为当前节点，继续尝试
                                continue
                            } else {
                                // 不满足谓词，继续遍历
                                pred = curr
                                currOpt = curr.next[0].load()
                            }
                        case None =>
                            // 节点已被其他线程逻辑删除，帮助其物理删除并跳过
                            helpPhysicallyRemove(curr, pred)
                            pred = curr
                            currOpt = curr.next[0].load()
                    }
                case None =>
                    // 遍历结束
                    break
            }
        }
    }

    // 尝试删除指定节点（调用者保证该节点当前未被逻辑删除）
    // 返回 true 表示删除成功，false 表示因并发冲突需要重试
    private func tryRemoveNode(node: Node<K, V>, pred: Node<K, V>): Bool {
        let oldValOpt = node.value.load()
        match (oldValOpt) {
            case Some(v) =>
                // 尝试逻辑删除
                if (!node.value.compareAndSwap(oldValOpt, Option.None)) {
                    return false
                }
                // 逻辑删除成功，进行物理删除
                physicallyRemove(node, pred)
                size_.fetchSub(1)
                return true
            case None =>
                // 节点已被逻辑删除（可能在我们检查后发生），帮助物理删除
                physicallyRemove(node, pred)
                return false
        }
    }

    // 帮助完成物理删除（可由多个线程并发执行）
    private func helpPhysicallyRemove(node: Node<K, V>, pred: Node<K, V>): Unit {
        // 仅当节点值确实为 None 时才进行物理摘除
        if (node.value.load().isNone()) {
            physicallyRemove(node, pred)
        }
    }

    // 物理删除：将节点从各层链表中摘除
    // 为提高效率，这里重新调用 findNode 获取各层最新前驱，以确保彻底摘除
    private func physicallyRemove(node: Node<K, V>, knownPred: Node<K, V>): Unit {
        let key = node.key
        // 重新查找以获取各层精确前驱（findNode 是 O(log N) 操作）
        let result = findNode(key)
        // 如果节点已不在链表中（findNode 返回的 node 不是它），说明已被其他线程摘除
        match (result.node) {
            case Some(n) =>
                if (!refEq(n, node)) {
                    return
                }
            case None => return
        }

        // 逐层摘除
        for (lvl in (node.level)..=0) {
            while (true) {
                let pred = result.preds[lvl].getOrThrow()
                let succ = pred.next[lvl].load()

                match (succ) {
                    case Some(n) =>
                        if (!isHead(n) && n.key < key) {
                            break
                        }
                    case None => ()
                }

                let nodeNext = node.next[lvl].load()
                if (pred.next[lvl].compareAndSwap(succ, nodeNext)) {
                    break
                }
            }
        }
    }

    // ---------- 辅助方法 ----------
    public func containsKey(key: K): Bool {
        return get(key).isSome()
    }

    public prop size: Int64 {
        get() {
            return size_.load()
        }
    }

    public func isEmpty(): Bool {
        return size == 0
    }
    
    public func entryView(key: K, fn: (MapEntryView<K, V>) -> ?V): ?V {
        let view = ConcurrentSkipListEntryViewImpl(this, key)
        let v = fn(view)
        match(view.value){
            case Some(x) => add(key, x)
            case _ => remove(key)
        }
        v

    }
    public func entryView(key: K, fn: (MapEntryView<K, V>) -> Unit): ?V {
        func viewfn(view: MapEntryView<K, V>): ?V {
            let v = view.value
            fn(view)
            v
        }
        entryView(key, viewfn)
    }
    public func entryView(key: K, fn: (K, ?V) -> ?V): ?V {
        this.entryView(key) {
            entry => entry.value = fn(key, entry.value)
        }
    }
}

// Map 接口要求的方法
extend<K, V> ConcurrentSkipListMap<K, V> <: ConcurrentMap<K, V> where K <: Comparable<K> {
    public func clear(): Unit {
        // 简单实现：重新初始化头节点
        this.head = Node<K, V>(unsafeZeroValue<K>(), None<V>, MAX_LEVEL)
        this.size_.store(0)
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
    // 仅当键不存在时插入
    public func addIfAbsent(key: K, value: V): Option<V> {
        while (true) {
            let result = findNode(key)
            match (result.node) {
                case Some(node) => return node.value.load()?.value
                case None =>
                    let prev = add(key, value)
                    if (prev.isNone()) {
                        return None
                    }
                    // 插入失败（键刚好被其他线程插入），返回现有值
                    return get(key)
            }
        }
        None<V>
    }
    public func putIfAbsent(key: K, value: V): Option<V> {
        addIfAbsent(key, value)
    }
    public func contains(key: K): Bool {
        findNode(key).node.isSome()
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
        while(let Some(node) <- current){
            current = node.next[0].load()
            if(let Some(v) <- node.value.load()){
                return (node.key, v.value)
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