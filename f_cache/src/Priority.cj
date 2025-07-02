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

import std.sync.{AtomicInt64, AtomicBool, AtomicReference, Mutex}
import std.time.DateTime

/*
    maxLife: 超时时间
    once: true 从birth开始计算超时时间，false 从最后访问时间开始算超时时间
    lastUsedTime: 最后使用时间
    ref: 访问次数
 */
public open class Priority<V> <: Comparable<Priority<V>> where V <: Object {
    let lock = Mutex()
    var index = -1
    private let ref = AtomicInt64(1) //缓存数据的使用次数
    private let birth = DateTime.now() //缓存数据的创建时间
    private var lastChecked = birth //缓存数据的最后使用时间
    private var usedUtilLastChecked = ref.load() //缓存数据截至上次检查时间的使用次数
    private var lastUsed = birth //缓存数据上次使用时间
    private var maxLife_: Duration //缓存数据的最大生存期，每条数据的生存期可以不同
    private let once_ = AtomicBool(false) //控制缓存数据的生存时间，true从出生开始算，false从上次使用时间开始算
    let key: String
    private let value: AtomicReference<V>

    protected init(key: String, value: V, maxLife: Duration, once: Bool) {
        this.key = key
        this.value = AtomicReference<V>(value)
        this.maxLife_ = maxLife
        this.once_.store(once)
    }
    public open func compare(other: Priority<V>): Ordering {
        let lastUsed = this.lastUsedTime
        let otherLastUsed = other.lastUsedTime
        func cmp(): Ordering {
            let duration = (lastUsed - lastCheckedTime).toSeconds()
            let otherDuration = (otherLastUsed - other.lastCheckedTime).toSeconds()

            var ordering: Ordering = (usedCount - usedCountUtilLastChecked).compare(
                other.usedCount - other.usedCountUtilLastChecked)
            ordering = match (ordering) {
                case EQ => duration.compare(otherDuration)
                case _ => return ordering
            }
            ordering = match (ordering) {
                case EQ => lastUsed.compare(otherLastUsed)
                case _ => return ordering
            }
            match (ordering) {
                case EQ => this.birth.compare(other.birth)
                case _ => ordering
            }
        }
        let age = this.age
        let otherAge = other.age
        let ageSub = age - otherAge
        //参与比较的都是在数据段头的，
        //在数据段头同时最后访问时间还在最近一个生命周期之内，要么是整个数据段都是刚刚出生，要么是整个数据段使用都很频繁
        if (ageSub >= -1.0 && ageSub <= 1.0) {
            cmp() //两个待比较数据都在最近一个生命周期内刚访问过
        } else if (age <= 1.0 && otherAge > 1.0) { //两个待比较数据的最后访问时间距今的时间差超过一个生命周期，保护新生
            GT
        } else if (age > 1.0 && otherAge <= 1.0) {
            LT
        } else { //两个待比较数据的最后访问时间距今都超过了一个生命周期，成年了不需要保护了
            cmp()
        }
    }
    protected prop age: Float64 {
        get() {
            synchronized(lock) {
                (DateTime.now() - if (once_.load()) {
                    birth
                } else {
                    lastUsed
                }) / maxLife_
            }
        }
    }
    protected mut prop maxLife: Duration {
        get() {
            synchronized(lock) {
                maxLife_
            }
        }
        set(value) {
            synchronized(lock) {
                maxLife_ = value
            }
        }
    }
    protected mut prop once: Bool {
        get() {
            once_.load()
        }
        set(value) {
            once_.store(value)
        }
    }
    protected prop lastUsedTime: DateTime {
        get() {
            synchronized(lock) {
                lastUsed
            }
        }
    }
    protected prop lastCheckedTime: DateTime {
        get() {
            lastChecked
        }
    }
    protected prop usedCount: Int64 {
        get() {
            ref.load()
        }
    }
    protected prop usedCountUtilLastChecked: Int64 {
        get() {
            usedUtilLastChecked
        }
    }
    protected prop birthTime: DateTime {
        get() {
            birth
        }
    }
    protected mut prop deathTime: DateTime {
        get() {
            synchronized(lock) {
                if (once) {
                    birth + maxLife_
                } else {
                    lastUsed + maxLife_
                }
            }
        }
        set(value) {
            synchronized(lock) {
                if (once) {
                    maxLife_ = value - birth
                } else {
                    maxLife_ = value - lastUsed
                }
            }
        }
    }
    protected func updateLastChecked(current: DateTime) {
        lastChecked = current
        usedUtilLastChecked = ref.load()
    }
    protected open func incr() {
        ref.fetchAdd(1)
        lastUsed = DateTime.now()
    }
    protected func load(): V {
        synchronized(lock) {
            incr()
            return value.load()
        }
    }
    protected func store(value: V) {
        synchronized(lock) {
            this.value.store(value)
            incr()
        }
    }
}
