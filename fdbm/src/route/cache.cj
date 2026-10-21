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
package fountain::fdbm.route

import std.sync.{AtomicBool, Mutex}
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_log.LoggerFactory
import fountain::f_store.Store
import fountain::fdbm.exception.FdbmException

/**
 * 分库缓存（设计 §6.3）：`f_store` 落地，键 `<logical>.<table>.<column>:<value>`。
 *
 * 容量只影响**新键写入**（超限停写并记一次 WARN），已有键照常命中；`f_store` 没有淘汰 API。
 */
protected class PartitionCache <: Resource {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.route.PartitionCache')

    private let store: Store
    private let expire: ?Duration
    private let capacity: Int64
    private let lock = Mutex()
    private var count_: Int64 = 0
    private let closed_ = AtomicBool(false)
    private var capacityWarned: Bool = false

    public init(path: String, expire: ?Duration, size: Int64) {
        this.store = Store(path)
        this.expire = expire
        this.capacity = size
        // 重启后计数不能归零，否则容量上限形同失效
        let iterator = store.prefix(Array<Byte>())
        var existing: Int64 = 0
        while (let Some(_) <- iterator.next()) {
            existing += 1
        }
        iterator.close()
        this.count_ = existing
    }

    public func get(logical: String, table: String, column: String, value: String): ?String {
        synchronized(lock) {
            // 关闭与读写必须共用同一把锁：否则检查通过后 close() 关掉 store，读写会抛非 CACHE 异常（G15）
            if (closed_.load()) {
                throw FdbmException(DbdErrorCode.CACHE, 'partition cache is closed')
            }
            match (store.get(keyOf(logical, table, column, value))) {
                case Some(bytes) => Some(String.fromUtf8(bytes))
                case None => None<String>
            }
        }
    }

    public func put(logical: String, table: String, column: String, value: String,
        physical: String): Unit {
        let key = keyOf(logical, table, column, value)
        synchronized(lock) {
            if (closed_.load()) {
                throw FdbmException(DbdErrorCode.CACHE, 'partition cache is closed')
            }
            if (capacity > 0 && count_ >= capacity && store.get(key).isNone()) {
                if (!capacityWarned) {
                    logger.warn('partition cache reached its capacity ${capacity}; new keys are not cached')
                    capacityWarned = true
                }
                return
            }
            let existing = store.get(key).isSome()
            match (expire) {
                case Some(duration) => store.add(key, physical.toArray(), duration)
                case None => store.add(key, physical.toArray())
            }
            if (!existing) {
                count_ += 1
            }
        }
    }

    public func remove(logical: String, table: String, column: String, value: String): Unit {
        synchronized(lock) {
            if (closed_.load()) {
                throw FdbmException(DbdErrorCode.CACHE, 'partition cache is closed')
            }
            if (store.remove(keyOf(logical, table, column, value)).isSome()) {
                count_ -= 1
            }
        }
    }

    public func count(): Int64 {
        synchronized(lock) {
            count_
        }
    }

    public func close(): Unit {
        synchronized(lock) {
            if (closed_.swap(true)) {
                return
            }
            try {
                store.close()
            } catch (e: Exception) {
                logger.warn('failed to close the partition cache: ${e.message}')
            }
        }
    }

    public func isClosed(): Bool {
        closed_.load()
    }

    private func keyOf(logical: String, table: String, column: String, value: String): Array<Byte> {
        '${logical}.${table}.${column}:${value}'.toArray()
    }
}
