/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

import std.collection.{Set, Map, EquatableCollection}

public class EmptyArray<T> {
    public static let INSTANCE = Array<T>()
    private init() {}
}
public class EmptySet<T> <: Set<T> where T <: Equatable<T> {
    public static let INSTANCE = EmptySet<T>()

    private init() {}

    public func iterator(): Iterator<T> {
        EmptyIterator<T>.INSTANCE
    }
    public func isEmpty(): Bool {
        true
    }
    public prop size: Int64 {
        get() {
            0
        }
    }

    /**
     * 如果该集合包含指定元素，则返回 true
     * 参数 element - 需要判断的元素
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    public func contains(element: T): Bool {
        false
    }

    /**
     * 检查该集合是否为其他集合的子集
     * 参数 other - 其他集合
     * 返回值 Bool - 如果它是子集，则返回 true，否则返回 false
     */
    public func subsetOf(other: Set<T>): Bool {
        true
    }

    /**
     * 检查该集合是否包含其他集合
     * 参数 elements - 其他集合
     * 返回值 Bool - 如果包含，则返回 true；否则，返回 false
     */
    public func containsAll(elements: Collection<T>): Bool {
        if (elements.isEmpty()) {
            true
        } else {
            false
        }
    }

    /**
     * 添加元素操作。如果元素已经存在，则不会添加它
     * 参数 element - 要添加的元素
     */
    public func put(element: T): Bool {
        false
    }

    /**
     * 添加 Collection 中的所有元素至此 Set 中，如果元素存在，则不添加
     * 参数 elements - 需要被添加的元素的集合
     */
    public func putAll(elements: Collection<T>): Unit {
        ()
    }

    /**
     * 从该结合中移除指定元素（如果存在）
     * 参数 element - 要删除的元素
     */
    public func remove(element: T): Bool {
        false
    }

    /**
     * 移除此 Set 中那些也包含在指定 Collection 中的所有元素
     * 参数 elements - 传入 Collection<T>
     */
    public func removeAll(elements: Collection<T>): Unit {
        ()
    }

    /**
     * 传入 lambda 表达式，如果满足 true 条件，则删除对应的元素
     * 参数 predicate - 传入一个 lambda 表达式进行判断
     */
    public func removeIf(predicate: (T) -> Bool): Unit {
        ()
    }

    /**
     * 清除所有键值对
     */
    public func clear(): Unit {
        ()
    }

    /**
     * 只保留重复的 T
     * 参数 elements - 要保存的元素集合
     */
    public func retainAll(elements: Set<T>): Unit {
        ()
    }

    /**
     * 克隆 Set
     * 返回新的 Set
     */
    public func clone(): Set<T> {
        this
    }
}
public class EmptyIterator<T> <: Iterator<T> {
    public static let INSTANCE = EmptyIterator<T>()
    private init() {}
    public func next(): Option<T> {
        None<T>
    }
}
public class EmptyIterable<T> <: Iterable<T> {
    public static let INSTANCE = EmptyIterable<T>()
    private init() {}
    public func iterator(): Iterator<T> {
        EmptyIterator<T>.INSTANCE
    }
}
public class EmptyMap<K, V> <: Map<K, V> & Bucket<K, V> where K <: Equatable<K> {
    public static let INSTANCE = EmptyMap<K, V>()

    private init() {}

    /**
     * 根据 key 得到 Map 中映射的值
     * 参数 key - 传递 key，获取 value
     * 返回值 Option<V> - key 对应的值是用 Option 封装的
     */
    public func get(key: K): Option<V> {
        None<V>
    }

    /**
     * 判断是否包含指定键的映射
     * 参数 key - 传递要判断的 key
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    public func contains(key: K): Bool {
        false
    }

    /**
     * 判断是否包含指定集合键的映射
     * 参数 keys - 传递待判断的 keys
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    public func containsAll(keys: Collection<K>): Bool {
        if (keys.isEmpty()) {
            true
        } else {
            false
        }
    }

    /**
     * 将指定的值与此映射中指定的键关联
           120
     * 如果映射以前包含键的映射，则旧值将被替换
     * 参数 key - 要放置的键
     * 参数 value - 要分配的值
     * 返回值 Option<V> - 如果赋值之前 key 存在，旧的 value 用 Option 封装；
     * 否则，返回 Option<V>.None
     */
    public func put(key: K, value: V): Option<V> {
        None<V>
    }

    /**
     * 传递指定元素进行遍历，并按顺序赋值
     * 如果映射以前包含键的映射，则旧值将被替换
     * 参数 element - 传递给遍历赋值的元素
     */
    public func putAll(elements: Collection<(K, V)>): Unit {
        ()
    }

    /**
     * 从此映射中删除指定键的映射（如果存在）
     * 参数 key - 传入要删除的 key
     * 返回值 Option<V> - 被移除映射的 V 用 Option 封装
     */
    public func remove(key: K): Option<V> {
        None<V>
    }

    /**
     * 从此映射中删除指定集合的映射（如果存在）
     * 参数 keys - 传人要删除的集合
     */
    public func removeAll(keys: Collection<K>): Unit {
        ()
    }

    /**
     * 传入 lambda 表达式，如果满足条件，则删除对应的键值
     * 参数 predicate - 传递一个 lambda 表达式进行判断
     */
    public func removeIf(predicate: (K, V) -> Bool): Unit {
        ()
    }

    /**
     * 清除所有键值对
     */
    public func clear(): Unit {
        ()
    }

    /**
     * 克隆 Map
     * 返回值 Map<K, V> - 返回一个 Map<K, V>
     */
    public func clone(): Map<K, V> {
        this
    }

    /**
     * 运算符重载集合，如果键存在，返回键对应的值，如果不存在，抛出异常。
     * 参数 key - 传递值进行判断
     * 返回值 V - 与键对应的值
     */
    public operator func [](key: K): V {
        None<V>.getOrThrow()
    }

    /**
     * 运算符重载集合，如果键存在，新 value 覆盖旧 value，如果键不存在，
     * 添加此键值对
     * 参数 key - 传递值进行判断
     * 参数 value - 传递要设置的值
     */
    public operator func [](key: K, value!: V): Unit {
        ()
    }

    /**
     * 返回 Map 中所有的 key，并将所有 key 存储在一个 Keys 容器中
     * 返回值 Keys<K> - 保存所有返回的 key
     */
    public func keys(): EquatableCollection<K> {
        EmptyEquatableCollection<K>.INSTANCE
    }

    /**
     * 返回 Map 中所有的 value，并将所有 value 存储在一个 Values 容器中
     * 返回值 Values<V> - 保存所有返回的 value
     */
    public func values(): Collection<V> {
        EmptyCollection<V>.INSTANCE
    }

    /**
     * 返回 Map 中所有的元素个数
     * 返回值 Int64 - 元素个数
     */
    public prop size: Int64 {
        get() {
            0
        }
    }

    /**
     * 检查 Map 是否为空
     * 返回值 Bool - 如果是，则返回 true; 否则，返回 false
     */
    public func isEmpty(): Bool {
        true
    }

    /**
     * 返回 Map 的迭代器
     * 返回值 Iterator<(K,V)> - Map 的迭代器
     */
    public func iterator(): Iterator<(K, V)> {
        EmptyIterator<(K, V)>.INSTANCE
    }
    public func toArray(): Array<(K, V)> {
        []
    }
}
public class EmptyEquatableCollection<K> <: EquatableCollection<K> where K <: Equatable<K> {
    public static let INSTANCE = EmptyEquatableCollection<K>()
    private init() {}

    /**
     * 返回 Keys 的迭代器
     * 返回值 Iterator<K> - Keys 的迭代器
     */
    public func iterator(): Iterator<K> {
        EmptyIterator<K>.INSTANCE
    }

    /**
     * 返回 Keys 中所有的元素个数
     * 返回值 Int64 - 元素个数
     */
    public prop size: Int64 {
        get() {
            0
        }
    }

    /**
     * 检查 Keys 是否为空
     * 返回值 Bool - 如果是，则返回 true; 否则，返回 false
     */
    public func isEmpty(): Bool {
        true
    }

    /**
     * 判断 Keys 是否包含指定元素
     * 参数 element - K
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    public func contains(element: K): Bool {
        false
    }

    /**
     * 判断 Keys 是否包含指定集合的元素
     * 参数 elements - 待判断的集合 elements
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    public func containsAll(elements: Collection<K>): Bool {
        if (elements.isEmpty()) {
            true
        } else {
            false
        }
    }
}

public class EmptyCollection<T> <: Collection<T> {
    public static let INSTANCE = EmptyCollection<T>()
    private init() {}

    /**
     * 返回对象的长度。
     * 返回值 Int64 - 列表的容量
     */
    public prop size: Int64 {
        get() {
            0
        }
    }

    /**
     * 判断对象是否为空
     * 返回值 Bool - 若为空返回 true，否则返回 false
     */
    public func isEmpty(): Bool {
        true
    }

    /**
     * 将对象转为数组类型
     * 返回值 Array<T> - 转换后的数组
     */
    public func toArray(): Array<T> {
        EmptyArray<T>.INSTANCE
    }
    public func iterator(): Iterator<T> {
        EmptyIterator<T>.INSTANCE
    }
}
