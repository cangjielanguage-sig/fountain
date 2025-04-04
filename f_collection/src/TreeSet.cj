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

import std.collection.{Set, TreeMap, ReadOnlySet, ArrayList}
import f_base.OverSizePolicy

public class TreeSet<T> <: Set<T> where T <: Comparable<T> {
    private let map: TreeMap<T, Unit>
    public init() {
        map = TreeMap<T, Unit>()
    }
    public init(elements: Collection<T>){
        this()
        for(e in elements){
            map.add(e, ())
        }
    }
    public init(elements: Array<T>){
        this()
        for(e in elements){
            map.add(e, ())
        }
    }
    public init(size: Int64, initElement: (Int64) -> T) {
        map = TreeMap<T, Unit>(size){i => (initElement(i), ())}
    }
    public func clear(): Unit{
        map.clear()
    }
    public func clone(): Set<T>{
        let c: Collection<T> = map.keys()
        TreeSet<T>(c)
    }
    public func isEmpty(): Bool {
        map.isEmpty()
    }
    public func iterator(): Iterator<T>{
        map.keys().iterator()
    }
    public prop size: Int64 {
        get(){
            map.size
        }
    }
    public func contains(value: T): Bool {
        map.contains(value)
    }
    public func contains(all!: Collection<T>): Bool {
        map.contains(all: all)
    }
    public func subsetOf(other: ReadOnlySet<T>): Bool {
        for(v in map.keys() where !other.contains(v)){
            return false
        }
        return true
    }
    public func retain(all!: Set<T>): Unit {
        map.removeIf{k,_ => !all.contains(k)}
    }
    public func add(element: T): Bool{
        map.add(element, ()).isNone()
    }
    public func add(all!: Collection<T>): Unit {
        for(e in all){
            map.add(e, ())
        }
    }
    public func remove(element: T): Bool{
        map.remove(element).isSome()
    }
    public func remove(all!: Collection<T>): Unit {
        map.remove(all: all)
    }
    public func removeIf(predicate: (T) -> Bool): Unit {
        map.removeIf{k, _ => predicate(k)}
    }
    public func retainAll(elements: Set<T>): Unit{
        removeIf{v => !elements.contains(v)}
    }
    public func forward(mark: T, inclusive!: Bool = false): Iterator<T> {
        map.forward(mark, inclusive: inclusive).map{kv => kv[0]}
    }
    public func backward(mark: T, inclusive!: Bool = false): Iterator<T> {
        map.backward(mark, inclusive: inclusive).map{kv => kv[0]}
    }
    public prop first: ?T {
        get(){
            map.first?[0]
        }
    }
    public prop last: ?T{
        get(){
            map.last?[0]
        }
    }
    public func removeFirst(): ?T{
        map.removeFirst()?[0]
    }
    public func removeLast(): ?T{
        map.removeLast()?[0]
    }
}

extend<T> TreeSet<T> <: Equatable<TreeSet<T>> where T <: Comparable<T> {
    public operator func ==(other: TreeSet<T>): Bool {
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
extend<T> TreeSet<T> <: ToString where T <: Comparable<T> & ToString{
    public func toString(): String {
        let builder = StringBuilder()
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