/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_cache

public let DEFAULT_HEAP_CACHE_MAX_LIFE = Duration.second * 5
public let DEFAULT_HEAP_CACHE_MAX_SIZE = Int64.Max
public let DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL = 128
public let DEFAULT_HEAP_CHECK_CHECK_DURATION = Duration.second
public open class HeapCacheBuilder<V> where V <: Object {
    private var maxLife = DEFAULT_HEAP_CACHE_MAX_LIFE
    private var concurrencyLevel = DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL
    private var maxSize = DEFAULT_HEAP_CACHE_MAX_SIZE
    private var checkDuration = DEFAULT_HEAP_CHECK_CHECK_DURATION
    private var evictionCallback: (String, V) -> Unit = {k, v => ()}

    public func setMaxLife(maxLife: Duration): HeapCacheBuilder<V> {
        if (maxLife < Duration.Zero) {
            throw IllegalArgumentException("maxLife must not be less than zero. however current is ${maxLife}")
        }
        this.maxLife = maxLife
        return this
    }
    public func setConcurrencyLevel(concurrencyLevel: Int64): HeapCacheBuilder<V> {
        if (concurrencyLevel <= 0) {
            throw IllegalArgumentException(
                "concurrencyLevel must be greater than zero. however current is ${concurrencyLevel}")
        }
        this.concurrencyLevel = concurrencyLevel
        return this
    }
    public func setMaxSize(maxSize: Int64): HeapCacheBuilder<V> {
        if (maxSize <= 0) {
            throw IllegalArgumentException("maxSize must be greater than zero. however current is ${maxSize}")
        }
        this.maxSize = maxSize
        this
    }
    public func setEvictionCallback(callback: (String, V) -> Unit): HeapCacheBuilder<V> {
        this.evictionCallback = callback
        this
    }
    public func setCheckDuration(checkDuration: Duration): HeapCacheBuilder<V> {
        if(checkDuration <= Duration.Zero) {
            throw IllegalArgumentException("checkDuration must be greater Duration.Zero")
        }
        this.checkDuration = checkDuration
        this
    }
    public open func build(): HeapCache<V> {
        return HeapCache<V>(concurrencyLevel: concurrencyLevel,
                            maxLife: maxLife, maxSize: maxSize,
                            checkDuration: checkDuration,
                            evictionCallback: evictionCallback)
    }
}
