/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_concurrent

public class ConcurrentHashSetIterator<T> <: Iterator<T>{
    public ConcurrentHashSetIterator(public let itr: Iterator<(T, T)>){}
    public func next(): ?T{
        itr.next()?[0]
    }
}
public class ConcurrentHashSet<T> <: Set<T> where T <: Hashable & Equatable<T> {
    private let store: ConcurrentHashMap<T, T>
    public init() {
        store = ConcurrentHashMap<T, T>()
    }
    public init(capacity: Int64){
        store = ConcurrentHashMap<T, T>(capacity)
    }
    public init(elements: Collection<T>){
        this()
        for(v in elements){
            store[v] = v
        }
    }
    public init(elements: Array<T>){
        this()
        for(v in elements){
            store[v] = v
        }
    }
    public prop size: Int64 {
        get() {
            store.size
        }
    }
    public func isEmpty(): Bool {
        return store.isEmpty()
    }
    public func iterator(): Iterator<T> {
        ConcurrentHashSetIterator<T>(store.iterator())
    }
    public func add(value: T): Bool {
        store.add(value, value).isNone()
    }
    public func add(all!: Collection<T>): Unit {
        for(v in all){
            add(v)
        }
    }
    public func contains(value: T): Bool {
        store.contains(value)
    }
    public func contains(all!: Collection<T>): Bool {
        for (v in all where !this.contains(v)) {
            return false
        }
        return true
    }
    public func retain(all!: Set<T>): Unit {
        for((k, _) in store where !all.contains(k)){
            store.remove(k)
        }
    }
    public func subsetOf(other: ReadOnlySet<T>): Bool {
        for (v in this where !other.contains(v)) {
            return false
        }
        return true
    }
    public func remove(value: T): Bool {
        store.remove(value).isSome()
    }
    public func remove(all!: Collection<T>): Unit {
        for (v in all) {
            store.remove(v)
        }
    }
    public func removeIf(predicate: (T) -> Bool): Unit {
        let keys = ArrayList<T>()
        for((k, v) in store where predicate(v)) {
            keys.add(k)
        }
        for(k in keys){
            store.remove(k)
        }
    }
    public func clear(): Unit {
        removeIf{_ => true}
    }
    public func retainAll(values: Set<T>): Unit {
        for (v in this where !values.contains(v)) {
            remove(v)
        }
    }
    public func clone(): ConcurrentHashSet<T> {
        ConcurrentHashSet<T>(this)
    }
}
extend<T> ConcurrentHashSet<T> <: Equatable<ConcurrentHashSet<T>> where T <: Hashable & Equatable<T> {
    public operator func ==(other: ConcurrentHashSet<T>): Bool {
        if(this.size != other.size){
            return false
        }
        let itr1 = this.iterator()
        let itr2 = other.iterator()
        var i = 0
        while(let (Some(x), Some(y)) <- (itr1.next(), itr2.next()) && x == y){
            i++
        }
        i == this.size
    }
}
extend<T> ConcurrentHashSet<T> <: ToString where T <: Hashable & Equatable<T> & ToString{
    public func toString(): String {
        let builder = StringGenerator()
        builder.append('[')
        var i = 0
        for(v in this){
            if(i > 0){
                builder.append(', ')
            }
            builder.append(v)
            i++
        }
        builder.append(']')
        builder.toString()
    }
}