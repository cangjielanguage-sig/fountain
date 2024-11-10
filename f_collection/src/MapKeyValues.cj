/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_collection

import std.collection.{Map, EquatableCollection}
import f_base.ExtendOption

class MapKeyIterator<K, V> <: Iterator<K> {
    MapKeyIterator(private let entryIterator: Iterator<(K, V)>) {}
    public func next(): Option<K> {
        entryIterator.next()?[0]
    }
}
class MapKeys<K, V> <: EquatableCollection<K> where K <: Equatable<K> {
    MapKeys(private let map: Map<K, V>) {}

    /**
     * 返回对象的长度。
     * 返回值 Int64 - 列表的容量
     */
    public prop size: Int64 {
        get() {
            return map.size
        }
    }

    /**
     * 判断对象是否为空
     * 返回值 Bool - 若为空返回 true，否则返回 false
     */
    public func isEmpty(): Bool {
        return map.isEmpty()
    }

    /**
     * 将对象转为数组类型
     * 返回值 Array<T> - 转换后的数组
     */
    public func toArray(): Array<K> {
        let itr = iterator()
        return Array<K>(size){_ => 
            itr.next().getOrThrow()
        }
    }

    /**
     * 返回实例类型的迭代器
     * 返回值 Iterator<E> - 返回实例类型的迭代器。
     */
    public func iterator(): Iterator<K> {
        return MapKeyIterator(map.iterator())
    }
    /**
     * 判断 Keys 是否包含指定元素
     * 参数 element - T
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    public func contains(element: K): Bool {
        return map.contains(element)
    }

    /**
     * 判断 Keys 是否包含指定集合的元素
     * 参数 elements - 待判断的集合 elements
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    public func containsAll(elements: Collection<K>): Bool {
        return map.containsAll(elements)
    }
}
class MapValueIterator<K, V> <: Iterator<V> {
    MapValueIterator(private let entryIterator: Iterator<(K, V)>) {}
    public func next(): Option<V> {
        entryIterator.next()?[1]
    }
}
class MapValues<K, V> <: Collection<V> where K <: Equatable<K> {
    private var map: Map<K, V>
    init(map: Map<K, V>) {
        this.map = map
    }

    /**
     * 返回 Values 的迭代器
     * 返回值 Iterator<T> - Values 的迭代器
     */
    public func iterator(): Iterator<V> {
        return MapValueIterator(map.iterator())
    }

    /**
     * 返回 Values 的元素个数
     * 返回值 Int64 - 元素的个数
     */
    public prop size: Int64 {
        get() {
            return map.size
        }
    }

    /**
       130
       3.2.8 class ArrayListIterator
       此类主要实现 ArrayList 的迭代器功能。
       3.2.9 class HashMapIterator
       此类主要实现 HashMap 的迭代器功能。
     * 判断 Values 是否为空
     * 返回值 Bool - 如果为空，则返回 true, 否则，返回 false
     */
    public func isEmpty(): Bool {
        return map.isEmpty()
    }

    /**
     * 清除所有 Values 中的元素
     */
    public func clear(): Unit {
        map.clear()
    }
    public func toArray(): Array<V>{
        let itr = iterator()
        Array<V>(size){_ => 
            itr.next().getOrThrow()
        }
    }
}
