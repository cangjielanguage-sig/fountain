/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_cache

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicBool
import std.ref.*
import fountain::f_collection.*

private struct WeakKey <: Hashable & Equatable<WeakKey> {
    private let key: WeakRef<Box<String>>
    private init(key: String, policy: CleanupPolicy){
        this.key = WeakRef<Box<String>>(Box<String>(key), policy)
    }
    static func deferred(key: String){
        WeakKey(key, DEFERRED)
    }
    public func hashCode(): Int64 {
        key.value?.hashCode() ?? 0
    }
    public operator func ==(other: WeakKey){
        match((key.value, other.key.value)){
            case (Some(x), Some(y)) => x.value == y.value
            case _ => false
        }
    }
    func isNone(){
        key.value.isNone()
    }
    func getKey(): ?String {
        key.value?.value
    }
}
public class WeakHeapCache<T> <: Resource where T <: Object {
    private let cache = ConcurrentHashMap<WeakKey, WeakRef<T>>()
    private let closedFlag = AtomicBool(false)
    /**内部清扫线程的句柄：close() 时向它发送取消请求，用例可通过 threadHandles() 等它结束*/
    private var cleanerTask: Option<Future<Unit>> = None
    /**清扫周期：close() 的取消请求最迟在下一轮循环被感知*/
    private static let CLEAN_INTERVAL = Duration.second
    public init() {
        cleanerTask = Some(spawn {
            //每轮检查一次取消请求：close() 发 cancel 后最多一个 CLEAN_INTERVAL 内退出
            while (!Thread.currentThread.hasPendingCancellation) {
                cache.removeIf{k, v => k.isNone() || v.value.isNone()}
                sleep(CLEAN_INTERVAL)
            }
        })
    }
    /**关闭校验：关闭后调用任何公开操作都抛 IllegalStateException（isClosed/close 除外）*/
    private func ensureOpen(): Unit {
        if (closedFlag.load()) {
            throw IllegalStateException('weak heap cache is closed')
        }
    }
    /**
     * 停止内部清扫线程并主动清空缓存；**清空且清扫线程结束后才返回**，可重复调用。
     * 关闭之后再调用任何操作（`get`/`set`/`size`/…）都会抛 `IllegalStateException`。
     */
    public func close(): Unit {
        if (closedFlag.load()) {
            return
        }
        closedFlag.store(true)
        //主动清空：不再依赖清扫线程的下一轮
        cache.removeIf {_, _ => true}
        if (let Some(f) <- cleanerTask) {
            f.cancel()
            //等清扫线程退出（最长一个 CLEAN_INTERVAL）：close 返回即「清理完成」
            try {
                f.get()
            } catch (e: Exception) {
                //兜底：close 不应因内部线程而失败
            }
        }
    }
    public func isClosed(): Bool {
        closedFlag.load()
    }
    /**仅供同包用例使用：内部线程句柄（WeakHeapCache = 1 个清扫线程），用来等待它结束*/
    func threadHandles(): ArrayList<Future<Unit>> {
        let handles = ArrayList<Future<Unit>>()
        if (let Some(f) <- cleanerTask) {
            handles.add(f)
        }
        handles
    }
    private func weakRef(value: T) {
        WeakRef(value, DEFERRED)
    }
    public func set(key: String, value: T): ?T {
        ensureOpen()
        try {
            if (let Some(r) <- cache.get(WeakKey.deferred(key)) && let Some(v) <- r.value) {
                return v
            }
            None<T>
        } finally {
            cache[WeakKey.deferred(key)] = weakRef(value)
        }
    }
    public func getOrCompute(key: String, fn: () -> ?T): ?T {
        ensureOpen()
        cache.entryView(WeakKey.deferred(key)) {
            entry => if (let Some(r) <- entry.value && let Some(v) <- r.value) {
            } else {
                entry.value = if (let Some(v) <- fn()) {
                    weakRef(v)
                } else {
                    None
                }
            }
        }?.value ?? None<T>
    }
    public func get(key: String): ?T {
        ensureOpen()
        cache.entryView(WeakKey.deferred(key)){view => 
            if(let Some(r) <- view.value && let Some(v) <- r.value){
                r
            }else{
                None<WeakRef<T>>
            }
        }?.value ?? None
    }
    public func getOrDefault(key: String, default: T): T {
        ensureOpen()
        get(key) ?? default
    }
    public func getOrStore(key: String, value: T): T {
        ensureOpen()
        getOrCompute(key) {value} ?? value
    }
    public func remove(key: String): ?T {
        ensureOpen()
        cache.remove(WeakKey.deferred(key))?.value ?? None<T>
    }
    public func removeIf(predicate: (String, T) -> Bool): Unit {
        ensureOpen()
        cache.removeIf {
            k, r => if (let (Some(k), Some(v)) <- (k.getKey(), r.value)) {
                predicate(k, v)
            } else {
                true
            }
        }
    }
    public prop size: Int64 {
        get() {
            ensureOpen()
            cache.size
        }
    }
    public func clear(): Unit {
        ensureOpen()
        cache.removeIf {_, _ => true}
    }
}
