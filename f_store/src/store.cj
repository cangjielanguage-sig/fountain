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
    public func flush(): Unit {
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
    /**
     * 获取键对应的字符串.
     * @param key 键
     * @return 得到的值以UTF8解码
     */
    public func getString(key: String): ?String {
        if(let Some(x) <- get(key)){
            String.fromUtf8(x)
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
     * 保存数据。保存value的UTF8字节
     */
    public func set(key: String, value: String): Unit {
        set(key, value.unsafeBytes())
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
     * 批量设置键值对，保存fn函数返回字符串的UTF8字节
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func set(key: String, fn: () -> String): Unit {
        set(key, fn())
    }
    /**
     * 设置键值对，如果键不存在则设置，如果键存在则返回键对应的值.
     */
    public func setIfAbsent(key: String, value: Array<Byte>): Array<Byte> {
        update<Array<Byte>>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                x
            }else{
                tx.set(keyBytes, value)
                value
            }
        }
    }
    /**
     * 如果键不存在就设置新值并返回None，如果键存在则什么也不做并返回键对应的旧值。
     * @param key 键值对.
     * @param value 值.
     * @return 
     */
    public func setIfAbsent<T>(key: String, value: T): T where T <: DataFields<T> {
        decode<T>(key, computeIfAbsent(key){
            encode<T>(value)
        })
    }
    /**
     * 如果键不存在就设置新值并返回None，如果键存在则什么也不做并返回键对应的旧值。
     * 以value的UTF8字节保存数据
     * @param key 键值对.
     * @param value 值.
     * @return 
     */
    public func setIfAbsent(key: String, value: String): String {
        computeIfAbsent(key){value.unsafeBytes()} |> String.fromUtf8
    }
    /**
     * 设置键值对，如果键存在则设置值并返回键对应的旧值，否则什么也不做并返回None。
     */
    public func setIfPresent(key: String, value: Array<Byte>): ?Array<Byte> {
        update<?Array<Byte>>{tx => 
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                tx.set(keyBytes, value)
                x
            }else{
                None
            }
        }
    }
    /**
     * 设置数据，如果键存在则设置新值并返回键对应的旧值，否则什么也不做并返回None。
     * @param key 键.
     * @param value 新值.
     */
    public func setIfPresent<T>(key: String, value: T): ?T where T <: DataFields<T> {
        if(let Some(bytes) <- computeIfPresent(key){encode<T>(value)}){
            decode<T>(key, bytes)
        }else{
            None
        }
    }
    /**
     * 设置数据，如果键存在则设置新值并返回键对应的旧值，否则什么也不做并返回None。
     * 保存value的UTF8字节
     * @param key 键.
     * @param value 新值.
     */
    public func setIfPresent(key: String, value: String): ?String {
        if(let Some(bytes) <- computeIfPresent(key){value.unsafeBytes()}){
            String.fromUtf8(bytes)
        }else{
            None
        }
    }
    /**
     * 计算键值对，如果键不存在则设置并返回键对应的新值，如果键存在则返回键对应的旧值。
     */
    public func computeIfAbsent(key: String, fn: () -> Array<Byte>): Array<Byte> {
        update<Array<Byte>>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                x
            }else{
                let x = fn()
                tx.set(keyBytes, x)
                x
            }
        }
    }
    /**
     * 计算数据，如果键不存在则设置并返回键对应新值，如果键存在则返回键对应的旧值。
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent<T>(key: String, fn: () -> T): T where T <: DataFields<T> {
        update<T>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                decode<T>(key, x)
            }else{
                let x = fn()
                tx.set(keyBytes, encode<T>(x))
                x
            }
        }
    }
    /**
     * 计算数据，如果键不存在则设置并返回键对应新值，如果键存在则返回键对应的旧值。
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent(key: String, fn: () -> String): String {
        update<String>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                String.fromUtf8(x)
            }else{
                let x = fn()
                tx.set(keyBytes, x.unsafeBytes())
                x
            }
        }
    }
    /**
     * 计算键值对，如果键不存在则什么也不做并返回None，如果键存在则更新新值返回键对应的旧值。
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent(key: String, fn: () -> Array<Byte>): ?Array<Byte> {
        update<?Array<Byte>>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                let y = fn()
                tx.set(keyBytes, y)
                x
            }else{
                None
            }
        }
    }
    /**
     * 计算键值对，如果键不存在则什么也不做并返回None，如果键存在则更新新值返回键对应的旧值。
     */
    public func computeIfPresent<T>(key: String, fn: () -> T): ?T where T <: DataFields<T> {
        if(let Some(bytes) <- computeIfPresent(key){encode<T>(fn())}){
            decode<T>(key, bytes)
        }else{
            None
        }
    }
    /**
     * 计算键值对，如果键不存在则什么也不做并返回None，如果键存在则更新新值返回键对应的旧值。
     */
    public func computeIfPresent(key: String, fn: () -> String): ?String {
        if(let Some(bytes) <- computeIfPresent(key){fn().unsafeBytes()}){
            String.fromUtf8(bytes)
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
     * 批量设置TTL.
     * @param 迭代器返回的元组依次是键、值和生命周期。
     */
    public func ttl(iterable: Iterable<(String, Array<Byte>, Duration)>): Unit {
        update{tx => 
            for((k, v, life) in iterable){
                Entry.new(k.unsafeBytes(), v).withTTL(life) |> tx.setEntry
            }
        }
    }
    /**
     * 批量设置TTL.
     * @param 迭代器返回的元组依次是键、值和生命周期。
     */
    public func ttl<T>(iterable: Iterable<(String, T, Duration)>): Unit where T <: DataFields<T> {
        ttl(iterable.iterator().map{tuple => (tuple[0], encode<T>(tuple[1]), tuple[2])})
    }
    /**
     * 批量设置TTL.
     * @param 迭代器返回的元组依次是键、值和生命周期。
     */
    public func ttl<T>(iterable: Iterable<(String, String, Duration)>): Unit {
        ttl(iterable.iterator().map{tuple => (tuple[0], tuple[1].unsafeBytes(), tuple[2])})
    }
    
    private func setEntry(tx: Transaction, key: Array<Byte>, value: Array<Byte>, life: Duration){
        Entry.new(key, value).withTTL(life) |> tx.setEntry
    }
    /**
     * 设置TTL.
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttl(key: String, value: Array<Byte>, life: Duration): Unit {
        update{tx => setEntry(tx, key.unsafeBytes(), value, life)}
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
     * 获取TTL.
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttl(key: String, value: String, life: Duration): Unit {
        ttl(key, value.unsafeBytes(), life)
    }
    /**
     * 设置TTL.
     * @param key 键.
     * @param life 生命周期.
     */
    public func ttl(key: String, life: Duration): ?Array<Byte> {
        update<?Array<Byte>>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, x, life)
                x
            }else{
                None
            }
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfAbsent(key: String, value: Array<Byte>, life: Duration): Array<Byte> {
        update<Array<Byte>>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, x, life)
                x
            }else{
                setEntry(tx, keyBytes, value, life)
                value
            }
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfAbsent<T>(key: String, value: T, life: Duration): T where T <: DataFields<T> {
        update<T>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, x, life)
                decode<T>(key, x)
            }else{
                setEntry(tx, keyBytes, encode<T>(value), life)
                value
            }
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfAbsent(key: String, value: String, life: Duration): String {
        update<String>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, x, life)
                String.fromUtf8(x)
            }else{
                setEntry(tx, keyBytes, value.unsafeBytes(), life)
                value
            }
        }
    }
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfPresent(key: String, value: Array<Byte>, life: Duration): ?Array<Byte> {
        update<?Array<Byte>>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, value, life)
                x
            }else{
                None
            }
        }
    }
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfPresent<T>(key: String, value: T, life: Duration): ?T where T <: DataFields<T> {
        if(let Some(x) <- computeIfPresent(key, life){encode<T>(value)}){
            decode<T>(key, x)
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
    public func ttlIfPresent(key: String, value: String, life: Duration): ?String {
        if(let Some(x) <- computeIfPresent(key, life){value.unsafeBytes()}){
            String.fromUtf8(x)
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
        update<Array<Byte>>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, x, life)
                x
            }else{
                let x = fn()
                setEntry(tx, keyBytes, x, life)
                x
            }
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent<T>(key: String, life: Duration, fn: () -> T): T where T <: DataFields<T> {
        update<T>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, x, life)
                decode<T>(key, x)
            }else{
                let x = fn()
                setEntry(tx, keyBytes, encode<T>(x), life)
                x
            }
        }
    }
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent(key: String, life: Duration, fn: () -> String): String {
        update<String>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, x, life)
                String.fromUtf8(x)
            }else{
                let x = fn()
                setEntry(tx, keyBytes, x.unsafeBytes(), life)
                x
            }
        }
    }
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent(key: String, life: Duration, fn: () -> Array<Byte>): ?Array<Byte> {
        update<?Array<Byte>>{tx =>
            let keyBytes = key.unsafeBytes()
            if(let Some(x) <- tx.get(keyBytes)){
                setEntry(tx, keyBytes, fn(), life)
                x
            }else{
                None
            }
        }
    }
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent<T>(key: String, life: Duration, fn: () -> T): ?T where T <: DataFields<T> {
        if(let Some(x) <- computeIfPresent(key, life){encode<T>(fn())}){
            decode<T>(key, x)
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
    public func computeIfPresent(key: String, life: Duration, fn: () -> String): ?String {
        if(let Some(x) <- computeIfPresent(key, life){fn().unsafeBytes()}){
            String.fromUtf8(x)
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
    private func convert(fn: (Transaction, String, String) -> Unit): (Transaction, String, Array<Byte>) -> Unit  {
        {t, k, bytes => fn(t, k, String.fromUtf8(bytes))}
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
     * 只读迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，T是当前迭代的值.
     */
    public func readOnlyIterate(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, String) -> Unit): Unit {
        readOnlyIterate(prefix: prefix, reverse: reverse, fn: convert(fn))
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
     * 可写迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，T是当前迭代的值.
     */
    public func updateIterate(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, String) -> Unit): Unit {
        updateIterate(prefix: prefix, reverse: reverse, fn: convert(fn))
    }
    /**
     * 删除指定前缀的键.
     * @param prefix 键前缀.
     */
    public func deletePrefix(prefix: String): Int64 {
        let count = Box<Int64>(0)
        updateIterate(prefix: prefix){tx, key, _: Array<Byte> =>
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
     * 删除满足条件的键.
     * @param prefix 键前缀.
     * @param fn 删除闭包，Transaction是当前Transaction，String是当前键，T是当前值，返回true则删除.
     */
    public func deletePrefix(prefix!: String = '', fn!: (Transaction, String, String) -> Bool): Unit {
        deletePrefix(prefix: prefix){tx, key, bytes => fn(tx, key, String.fromUtf8(bytes))}
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
    /**
     * 迭代指定键前缀的键值对
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @return 迭代器，迭代器的元素是(String, String)，元组的第一个值是键，第二个是值，值以UTF8解码.
     */
    public func scanString(prefix!: String = '', reverse!: Bool = false): StdIterator<(String, String)> {
        BadgerTupleIterator(db, prefix, reverse).map{tuple => (tuple[0], String.fromUtf8(tuple[1]))}
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