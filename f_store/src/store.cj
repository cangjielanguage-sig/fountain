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
import std.sync.AtomicBool
import badgercj.db.*
import badgercj.db.Iterator as BadgerIterator
import fountain::f_base.*

/**
 * badger-cj 的薄封装
 */
public struct Store <: Resource {
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
        this(path: if (path.isEmpty()) {
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
    public func isClosed(): Bool {
        closed.load()
    }
    public func close(): Unit {
        if(closed.compareAndSwap(false, true)){
            db.close()
        }
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
}