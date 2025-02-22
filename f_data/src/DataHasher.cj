/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_data

import std.time.{DateTime, MonoTime}
import std.math.numeric.{Decimal, BigInt}
import std.collection.concurrent.ConcurrentHashMap
import std.collection.*
import f_collection.{TreeSet, LinkedHashMap, LinkedHashSet}
import f_concurrent.ConcurrentHashSet

public struct DataHasher{
    private var hasher = DefaultHasher()
    public mut func write(value: Bool): Unit {
        hasher.write(value)
    }
    public mut func write(value: Float16): Unit {
        hasher.write(value)
    }
    public mut func write(value: Float32): Unit {
        hasher.write(value)
    }
    public mut func write(value: Float64): Unit {
        hasher.write(value)
    }
    public mut func write(value: Int8): Unit {
        hasher.write(value)
    }
    public mut func write(value: Int16): Unit {
        hasher.write(value)
    }
    public mut func write(value: Int32): Unit {
        hasher.write(value)
    }
    public mut func write(value: Int64): Unit {
        hasher.write(value)
    }
    public mut func write(value: UInt8): Unit {
        hasher.write(value)
    }
    public mut func write(value: UInt16): Unit {
        hasher.write(value)
    }
    public mut func write(value: UInt32): Unit {
        hasher.write(value)
    }
    public mut func write(value: UInt64): Unit {
        hasher.write(value)
    }
    public mut func write(value: IntNative): Unit {
        hasher.write(value.hashCode())
    }
    public mut func write(value: UIntNative): Unit {
        hasher.write(value.hashCode())
    }
    public mut func write(value: Rune): Unit {
        hasher.write(value)
    }
    public mut func write(value: String): Unit {
        hasher.write(value)
    }
    public mut func write(value: Duration): Unit {
        hasher.write(value.hashCode())
    }
    public mut func write(value: DateTime): Unit {
        hasher.write(value.hashCode())
    }
    public mut func write(value: MonoTime): Unit {
        hasher.write(value.hashCode())
    }
    public mut func write(value: BigInt): Unit {
        hasher.write(value.hashCode())
    }
    public mut func write(value: Decimal): Unit {
        hasher.write(value.hashCode())
    }

    private mut func write<T>(value: Collection<T>): Unit {
        if(let x: Hashable <- value){
            hasher.write(x.hashCode())
        }
        var hashable = true
        for(v in value){
            match(v){
                case x: Hashable => hasher.write(x.hashCode())
                case x: ToString => hasher.write(x.toString())
                case _ => 
                    hashable = false
                    break
            }
        }
        if(!hashable && let x: ToString <- value){
            hasher.write(x.toString())
        }
    }
    public mut func write<T>(value: Array<T>): Unit {
        let c: Collection<T> = value
        write<T>(c)
    }
    public mut func write<T>(value: ArrayList<T>): Unit {
        let c: Collection<T> = value
        write<T>(c)
    }
    public mut func write<T>(value: LinkedList<T>): Unit {
        let c: Collection<T> = value
        write<T>(c)
    }
    public mut func write<T>(value: HashSet<T>): Unit where T <: Hashable & Equatable<T>{
        let c: Collection<T> = value
        write<T>(c)
    }
    public mut func write<T>(value: TreeSet<T>): Unit where T <: Comparable<T> {
        let c: Collection<T> = value
        write<T>(c)
    }
    public mut func write<T>(value: LinkedHashSet<T>): Unit where T <: Hashable & Equatable<T>{
        let c: Collection<T> = value
        write<T>(c)
    }
    public mut func write<T>(value: ConcurrentHashSet<T>): Unit where T <: Hashable & Equatable<T>{
        let c: Collection<T> = value
        write<T>(c)
    }
    private mut func write<K, V>(value: Map<K, V>): Unit where K <: Equatable<K>{
        if(let x: Hashable <- value){
            hasher.write(x.hashCode())
        }
        var hashable = true
        for((k,v) in value){
            match((k, v)){
                case (x: Hashable, y: Hashable) => 
                    hasher.write(x.hashCode())
                    hasher.write(y.hashCode())
                case (x: Hashable, y: ToString) =>
                    hasher.write(x.hashCode())
                    hasher.write(y.toString())
                case (x: ToString, y: Hashable) =>
                    hasher.write(x.toString())
                    hasher.write(y.hashCode())
                case (x: ToString, y: ToString) =>
                    hasher.write(x.toString())
                    hasher.write(y.toString())
                case _ => ()
            }
        }
    }
    public mut func write<K, V>(value: HashMap<K, V>): Unit where K <: Hashable & Equatable<K>{
        let m: Map<K, V> = value
        write<K, V>(m)
    }
    public mut func write<K, V>(value: TreeMap<K, V>): Unit where K <: Comparable<K>{
        let m: Map<K, V> = value
        write<K, V>(m)
    }
    public mut func write<K, V>(value: LinkedHashMap<K, V>): Unit where K <: Hashable & Equatable<K>{
        let m: Map<K, V> = value
        write<K, V>(m)
    }
    public mut func write<K, V>(value: ConcurrentHashMap<K, V>): Unit where K <: Hashable & Equatable<K>{
        if(let x: Hashable <- value){
            hasher.write(x.hashCode())
        }
        var hashable = true
        for((k, v) in value){
            match((k, v)){
                case (x: Hashable, y: Hashable) => 
                    hasher.write(x.hashCode())
                    hasher.write(y.hashCode())
                case (x: Hashable, y: ToString) =>
                    hasher.write(x.hashCode())
                    hasher.write(y.toString())
                case (x: Hashable, _) => 
                    hasher.write(x.hashCode())
                    hasher.write('_')
            }
        }
    }
    public mut func write(value: Any): Unit{
        match(value){
            case x: Hashable => hasher.write(x.hashCode())
            case x: ToString => hasher.write(x.toString())
            case _ => ()
        }
    }
    public func finish(): Int64 {
        hasher.finish()
    }
}
