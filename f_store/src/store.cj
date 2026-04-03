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
package fountain::f_store

import std.env.{getWorkingDirectory, atExit}
import std.fs.{Path, canonicalize}
import std.io.ByteBuffer
import std.sync.AtomicBool
import std.core.Iterator as StdIterator
import badgercj.db.*
import badgercj.db.Iterator as BadgerIterator
import fountain::f_base.*
import fountain::f_codec.default.*
import fountain::f_codec.exception.*
import fountain::f_data.*

/**
 * badger-cj 的薄封装
 */
public class Store <: Resource {
    private let closed = AtomicBool(false)
    private let db: Badger
    /**
     * 使用当前路径初始化
     */
    public init(){
        this(getWorkingDirectory())
    }
    /**
     * @param path 存储路径，默认是空串，表示保存在当前路径. 
     */
    public init(path: String) {
        this(if (path.isEmpty()) {
            getWorkingDirectory()
        } else {
            Path(path)
        })
    }
    /**
     * @param path 存储路径
     */
    public init(path: Path) {
        db = Badger.open(Config(dir: canonicalize(path).toString()))
        atExit(this.close)
    }
    public func flush(){
        db.flushMemTable()
    }
    public func isClosed(): Bool {
        closed.load()
    }
    public func close(): Unit {
        if(closed.compareAndSwap(false, true)){
            db.close()
        }
    }
    private func encode<T>(value: T): Array<Byte> where T <: DataFields<T> {
        let input = ByteBuffer()
        DefaultCodec().encode(value).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        input.bytes()
    }
    private func decode<T>(key: String, value: Array<Byte>): T where T <: DataFields<T> {
        (ByteBuffer(value) |> DefaultCodec().decode<T>) ?? throw CodecException(key)
    }
    /**
     * 判断键是否存在.
     */
    public func contains(key: String): Bool {
        get(key).isSome()
    }
    /**
     * 获取值.
     * @param key 键.
     */
    public func get(key: String): ?Array<Byte> {
        db.get(key.unsafeBytes())?.value
    }
    
    /**
     * 获取数据，如果存在键值对，则尝试把数据解码为T的实例
     * @param key 键.
     */
    public func getData<T>(key: String): ?T where T <: DataFields<T> {
        if(let Some(x) <- get(key)){
            decode<T>(key, x)
        }else{
            None
        }
    }
    /*
     * 更新
     * @param fn 闭包，详细见badge-cj文档
     */
    public func update<T>(fn: (Transaction) -> T): T {
        db.update<T>(fn)
    }
    /**
     * 设置值.
     * @param key 键.
     * @param value 值.
     */
    public func set(key: String, value: Array<Byte>): Unit {
        update{tx => 
            tx.set(key.unsafeBytes(), value)
        }
    }
    
    /**
     * 设置数据。把value序列化为字节数组后保存。
     */
    public func set<T>(key: String, value: T): Unit where T <: DataFields<T> {
        set(key, encode<T>(value))
    }
    /**
     * 批量设置键值对.
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func set<T>(key: String, fn: () -> T): Unit where T <: DataFields<T> {
        set(key, fn())
    }
    /**
     * 设置键值对，如果键不存在则设置，如果键存在则返回键对应的值.
     */
    public func setIfAbsent(key: String, value: Array<Byte>): ?Array<Byte> {
        if(let Some(x) <- get(key)){
            x
        }else{
            set(key, value)
            None
        }
    }
    /**
     * 如果键不存在就设置新值并返回None，如果键存在则什么也不做并返回键对应的旧值。
     * @param key 键值对.
     * @param value 值.
     * @return 
     */
    public func setIfAbsent<T>(key: String, value: T): ?T where T <: DataFields<T> {
        if(let Some(x) <- setIfAbsent(key, encode<T>(value))){
            decode<T>(key, x)
        }else{
            None
        }
    }
    /**
     * 设置键值对，如果键存在则设置值并返回键对应的旧值，否则什么也不做并返回None。
     */
    public func setIfPresent(key: String, value: Array<Byte>): ?Array<Byte> {
        if(let Some(x) <- get(key)){
            set(key, value)
            x
        }else{
            None
        }
    }
    /**
     * 设置数据，如果键存在则设置新值并返回键对应的旧值，否则什么也不做并返回None。
     * @param key 键.
     * @param value 新值.
     */
    public func sestIfPresent<T>(key: String, value: T): ?T where T <: DataFields<T> {
        if(let Some(x) <- getData<T>(key)){
            set(key, encode<T>(value))
            x
        }else{
            None
        }
    }
    /**
     * 计算键值对，如果键不存在则设置并返回键对应的新值，如果键存在则返回键对应的旧值。
     */
    public func computeIfAbsent(key: String, fn: () -> Array<Byte>): Array<Byte> {
        if(let Some(x) <- get(key)){
            x
        }else{
            let x = fn()
            set(key, x)
            x
        }
    }
    /**
     * 计算数据，如果键不存在则设置并返回键对应新值，如果键存在则返回键对应的旧值。
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent<T>(key: String, fn: () -> T): T where T <: DataFields<T> {
        if(let Some(x) <- getData<T>(key)){
            x
        }else{
            let x = fn()
            set(key, x)
            x
        }
    }
    /**
     * 计算键值对，如果键不存在则什么也不做并返回None，如果键存在则更新新值返回键对应的旧值。
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent(key: String, fn: () -> Array<Byte>): ?Array<Byte> {
        if(let Some(x) <- get(key)){
            let y = fn()
            set(key, y)
            x
        }else{
            None
        }
    }
    /**
     * 计算键值对，如果键不存在则什么也不做并返回None，如果键存在则更新新值返回键对应的旧值。
     */
    public func computeIfPresent<T>(key: String, fn: () -> T): ? T where T <: DataFields<T> {
        if(let Some(x) <- getData<T>(key)){
            set<T>(key, fn)
            x
        }else{
            None
        }
    }
    /**
     * 删除.
     * @param key 键.
     */
    public func delete(key: String): Unit {
        update{tx => 
            tx.delete(key.unsafeBytes())
        }
    }
    /**
     * 设置TTL.
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttl(key: String, value: Array<Byte>, life: Duration): Unit {
        update{tx => Entry.new(key.unsafeBytes(), value).withTTL(life) |> tx.setEntry}
    }
    /**
     * 获取TTL.
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttl<T>(key: String, value: T, life: Duration): Unit where T <: DataFields<T> {
        ttl(key, encode<T>(value), life)
    }
    /**
     * 设置TTL.
     * @param key 键.
     * @param life 生命周期.
     */
    public func ttl(key: String, life: Duration): ?Array<Byte> {
        if(let Some(x) <- get(key)){
            ttl(key, x, life)
            x
        }else{
            None
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfAbsent(key: String, value: Array<Byte>, life: Duration): ?Array<Byte> {
        if(let Some(x) <- get(key)){
            ttl(key, x, life)
            x
        }else{
            ttl(key, value, life)
            None
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfAbsent<T>(key: String, value: T, life: Duration): ?T where T <: DataFields<T> {
        if(let Some(x) <- get(key)){
            ttl(key, x, life)
            decode<T>(key, x)
        }else{
            ttl(key, encode<T>(value), life)
            None
        }
    }
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfPresent(key: String, value: Array<Byte>, life: Duration): ?Array<Byte> {
        if(let Some(x) <- get(key)){
            ttl(key, value, life)
            x
        }else{
            None
        }
    }
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfPresent<T>(key: String, value: T, life: Duration): ?T where T <: DataFields<T> {
        if(let Some(x) <- getData<T>(key)){
            ttl(key, encode<T>(value), life)
            x
        }else{
            None
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent(key: String, life: Duration, fn: () -> Array<Byte>): Array<Byte> {
        if(let Some(x) <- get(key)){
            ttl(key, x, life)
            x
        }else{
            let x = fn()
            ttl(key, x, life)
            x
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent<T>(key: String, life: Duration, fn: () -> T): T where T <: DataFields<T> {
        if(let Some(x) <- get(key)){
            ttl(key, x, life)
            decode<T>(key, x)
        }else{
            let x = fn()
            ttl(key, x, life)
            x
        }
    }
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent(key: String, life: Duration, fn: () -> Array<Byte>): ?Array<Byte> {
        if(let Some(x) <- get(key)){
            ttl(key, fn(), life)
            x
        }else{
            None
        }
    }
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent<T>(key: String, life: Duration, fn: () -> T): ?T where T <: DataFields<T> {
        if(let Some(x) <- getData<T>(key)){
            ttl(key, encode<T>(fn()), life)
            x
        }else{
            None
        }
    }
    private func iterateClosure(prefix: String, reverse: Bool, fn: (Transaction, String, Array<Byte>) -> Unit) {
        {tx: Transaction => 
            let opt = IteratorOptions(prefix: prefix.unsafeBytes(), reverse: reverse)
            let iter = tx.newIterator(opt: opt)
            iter.rewind()
            while (iter.valid()) {
                let item = iter.item()
                fn(tx, String.fromUtf8(item.key), item.value)
                iter.next()
            }
        }
    }
    /**
     * 只读迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，Array<Byte>是当前迭代的值.
     */
    public func readOnlyIterate(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, Array<Byte>) -> Unit): Unit {
        iterateClosure(prefix, reverse, fn) |> db.view
    }
    private func convert<T>(fn: (Transaction, String, T) -> Unit): (Transaction, String, Array<Byte>) -> Unit where T <: DataFields<T> {
        {t, k, bytes => fn(t, k, decode<T>(k, bytes))}
    }
    /**
     * 只读迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，T是当前迭代的值.
     */
    public func readOnlyIterate<T>(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, T) -> Unit): Unit where T <: DataFields<T> {
        readOnlyIterate(prefix: prefix, reverse: reverse, fn: convert<T>(fn))
    }
    /**
     * 可写迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，Array<Byte>是当前迭代的值.
     */
    public func updateIterate(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, Array<Byte>) -> Unit): Unit {
        iterateClosure(prefix, reverse, fn) |> update
    }
    /**
     * 可写迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，T是当前迭代的值.
     */
    public func updateIterate<T>(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, T) -> Unit): Unit where T <: DataFields<T> {
        updateIterate(prefix: prefix, reverse: reverse, fn: convert<T>(fn))
    }
    /**
     * 删除指定前缀的键.
     * @param prefix 键前缀.
     */
    public func deletePrefix(prefix: String): Int64 {
        let count = Box<Int64>(0)
        updateIterate(prefix: prefix){tx, key, _ =>
            tx.delete(key.unsafeBytes())
            count.value++
        }
        count.value
    }
    /**
     * 删除满足条件的键.
     * @param prefix 键前缀.
     * @param fn 删除闭包，Transaction是当前Transaction，String是当前键，Array<Byte>是当前值，返回true则删除.
     */
    public func deletePrefix(prefix!: String = '', fn!: (Transaction, String, Array<Byte>) -> Bool): Unit {
        let count = Box<Int64>(0)
        updateIterate(prefix: prefix){tx, key, value =>
            if(fn(tx, key, value)){
                tx.delete(key.unsafeBytes())
                count.value++
            }
        }
        count.value
    }
    /**
     * 删除满足条件的键.
     * @param prefix 键前缀.
     * @param fn 删除闭包，Transaction是当前Transaction，String是当前键，T是当前值，返回true则删除.
     */
    public func deletePrefix<T>(prefix!: String = '', fn!: (Transaction, String, T) -> Bool): Unit where T <: DataFields<T> {
        deletePrefix(prefix: prefix){tx, key, bytes => fn(tx, key, decode<T>(key, bytes))}
    }
    /**
     * 迭代指定键前缀的键值对
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @return 迭代器，迭代器的元素是(String, Array<Byte>)，元组的第一个值是键，第二个是值.
     */
    public func scan(prefix!: String = '', reverse!: Bool = false): StdIterator<(String, Array<Byte>)> {
        BadgerTupleIterator(db, prefix, reverse)
    }
    /**
     * 迭代指定键前缀的键值对
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @return 迭代器，迭代器的元素是(String, T)，元组的第一个值是键，第二个是值.
     */
    public func scanData<T>(prefix!: String = '', reverse!: Bool = false): StdIterator<(String, T)> where T <: DataFields<T> {
        BadgerTupleIterator(db, prefix, reverse).map{tuple => (tuple[0], decode<T>(tuple[0], tuple[1]))}
    }
}
class BadgerTupleIterator <: StdIterator<(String, Array<Byte>)> {
    private let itr: PrefixIterator
    public init(db: Badger, prefix: String, reverse: Bool){
        itr = db.scan(prefix.unsafeBytes(), reverse: reverse, allVersions: false).iterator()
    }
    public func next(): ?(String, Array<Byte>) {
        if(let Some(x) <- itr.next()){
            return (String.fromUtf8(x.key), x.value)
        }else{
            None
        }
    }
}