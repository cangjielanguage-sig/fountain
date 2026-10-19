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

import std.sync.Mutex
import std.time.DateTime

/*
    maxLife: 超时时间
    once: true 从birth开始计算超时时间，false 从最后访问时间开始算超时时间
    lastUsed: 最后使用时间
    ref: 访问次数
    三个时间戳统一存 Unix 纳秒（Int64）：算术与比较都在 Int64 上做，不再为比较构造/比较 DateTime 对象
 */

/**淘汰比较的取值切片：age 与五级 tie-break 所需的量（时间戳均为 Unix 纳秒）*/
struct PrioritySnap {
    let age: Float64
    let birth: Int64
    let lastUsed: Int64
    let lastChecked: Int64
    let ref: Int64
    let usedUtilLastChecked: Int64

    PrioritySnap(age: Float64, birth: Int64, lastUsed: Int64, lastChecked: Int64, ref: Int64,
        usedUtilLastChecked: Int64) {
        this.age = age
        this.birth = birth
        this.lastUsed = lastUsed
        this.lastChecked = lastChecked
        this.ref = ref
        this.usedUtilLastChecked = usedUtilLastChecked
    }
}

public open class Priority<V> <: Comparable<Priority<V>> where V <: Object {
    let lock = Mutex()
    var index = -1
    private var ref = 1 //缓存数据的访问次数（读写都在 lock 内）
    private let birth: Int64 //缓存数据的创建时间（Unix 纳秒）
    private var lastChecked: Int64 //缓存数据的最后检查时间（Unix 纳秒）
    private var usedUtilLastChecked = 1 //缓存数据截至上次检查时间的访问次数
    private var lastUsed: Int64 //缓存数据上次使用时间（Unix 纳秒）
    private var maxLife_: Duration //缓存数据的最大生存期，每条数据的生存期可以不同
    private let checkDurationNanos: Int64 //checkDuration 的纳秒形式（age 计算用，构造时算一次）
    private var once_ = false //控制缓存数据的生存时间，true从出生开始算，false从上次使用时间开始算
    let key: String
    private var value: V
    /*淘汰比较快照：checkOverSize 进堆前调一次 snapshot（取锁算好），堆内 compareSnapshot 只读它*/
    private var snap = PrioritySnap(0.0, 0, 0, 0, 0, 0)
    private var snapReady = false

    protected init(key: String, value: V, maxLife: Duration, checkDuration: Duration, once: Bool) {
        let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        this.key = key
        this.value = value
        this.maxLife_ = maxLife
        this.checkDurationNanos = checkDuration.toNanoseconds()
        this.once_ = once
        this.birth = now
        this.lastChecked = now
        this.lastUsed = now
    }
    /**
     * 实时比较（公开语义不变）：两侧各取一次锁读当前值后走同一套排序规则。
     * 淘汰堆不走这里 —— 它用 compareSnapshot 读「进堆前算好的快照」。
     */
    public open func compare(other: Priority<V>): Ordering {
        let now = DateTime.now()
        orderOf(lockSnap(now), other.lockSnap(now))
    }
    /**排序规则（compare 与 compareSnapshot 共用）：a 更该保留 ⇒ GT，a 更该先淘汰 ⇒ LT*/
    private static func orderOf(a: PrioritySnap, b: PrioritySnap): Ordering {
        //age 越大 = 越久没被使用；|ageSub| ≤ 1：两个候选年龄接近 ⇒ 交给常规比较
        //ageSub > 1：a 更老 ⇒ 更小 ⇒ 在最小堆里先被淘汰（保护新生）
        //其余：a 更新、且年龄差超过一个生命周期 ⇒ 更大 ⇒ 保留（保护新生）
        let ageSub = a.age - b.age
        if (ageSub > 1.0) {
            return LT
        } else if (ageSub < -1.0) {
            return GT
        }
        //①本周期内的访问次数：用得多 ⇒ 更大 ⇒ 在最小堆里更晚被淘汰
        var ordering = (a.ref - a.usedUtilLastChecked).compare(b.ref - b.usedUtilLastChecked)
        //②都没被用过（或一样新鲜）：距上次检查越久没被用 ⇒ 越小
        ordering = match (ordering) {
            case EQ => (a.lastUsed - a.lastChecked).compare(b.lastUsed - b.lastChecked)
            case _ => return ordering
        }
        //③最后使用时间：更晚被使用的更大
        ordering = match (ordering) {
            case EQ => a.lastUsed.compare(b.lastUsed)
            case _ => return ordering
        }
        //④历史访问总量：用得多 ⇒ 更大（与①同向）
        ordering = match (ordering) {
            case EQ => a.ref.compare(b.ref)
            case _ => ordering
        }
        //⑤出生时间：出生更晚 ⇒ 更大（保护新生）
        match (ordering) {
            case EQ => a.birth.compare(b.birth)
            case _ => ordering
        }
    }
    /**取一次锁，把「以 current 为基准时刻」的比较切片算出来*/
    private func lockSnap(current: DateTime): PrioritySnap {
        synchronized(lock) {
            let base = if (once_) {
                birth
            } else {
                lastUsed
            }
            PrioritySnap(Float64(current.toUnixTimeStamp().toNanoseconds() - base) / Float64(checkDurationNanos),
                birth, lastUsed, lastChecked, ref, usedUtilLastChecked)
        }
    }
    /**进堆前调一次：取锁写好比较快照；之后堆内比较（compareSnapshot）只读普通字段*/
    protected func snapshot(current: DateTime): Unit {
        snap = lockSnap(current)
        snapReady = true
    }
    /**按快照比较：仅淘汰堆使用（配合 snapshot）；未快照时兜底就地补一次，不进热路径*/
    protected func compareSnapshot(other: Priority<V>): Ordering {
        if (!snapReady) {
            snapshot(DateTime.now())
        }
        if (!other.snapReady) {
            other.snapshot(DateTime.now())
        }
        orderOf(snap, other.snap)
    }
    protected prop age: Float64 {
        get() {
            lockSnap(DateTime.now()).age
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
            synchronized(lock) {
                once_
            }
        }
        set(value) {
            synchronized(lock) {
                once_ = value
            }
        }
    }
    /**条目的出生时间（Unix 纳秒；birth 不可变，无需加锁）*/
    protected prop birthNanos: Int64 {
        get() {
            birth
        }
    }
    /**条目的最后使用时间（Unix 纳秒）*/
    protected prop lastUsedNanos: Int64 {
        get() {
            synchronized(lock) {
                lastUsed
            }
        }
    }
    /**条目的死亡时间（Unix 纳秒）：once 从 birth 算、否则从 lastUsed 算*/
    protected mut prop deathNanos: Int64 {
        get() {
            synchronized(lock) {
                deathNanosLocked()
            }
        }
        set(value) {
            synchronized(lock) {
                maxLife_ = Duration.nanosecond * (value - (if (once_) {
                    birth
                } else {
                    lastUsed
                }))
            }
        }
    }
    private func deathNanosLocked(): Int64 {
        addLife(if (once_) {
            birth
        } else {
            lastUsed
        }, maxLife_)
    }
    /**base + life（纳秒）；跨 Int64 边界时饱和，避免回绕成过去时刻导致条目被误判过期*/
    private static func addLife(base: Int64, life: Duration): Int64 {
        let n = life.toNanoseconds()
        let sum = base + n
        if (n > 0 && sum < base) {
            return Int64.Max
        } else if (n < 0 && sum > base) {
            return Int64.Min
        }
        sum
    }
    protected func updateLastChecked(current: DateTime) {
        //由定时线程调用；与比较路径互斥
        synchronized(lock) {
            lastChecked = current.toUnixTimeStamp().toNanoseconds()
            usedUtilLastChecked = ref
        }
    }
    protected open func incr() {
        ref++
        lastUsed = DateTime.now().toUnixTimeStamp().toNanoseconds()
    }
    /**
     * 单次加锁完成「判过期 + 记一次使用 + 取值」，供 HeapCache.get 走读路径。
     * 过期判定与 incr 同锁，语义与「先判过期再 load」等价（lastUsed 用同一个 now）。
     */
    protected func loadIfAlive(): Option<V> {
        synchronized(lock) {
            let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
            if (now >= deathNanosLocked()) {
                return None<V>
            }
            ref++
            lastUsed = now
            return Some(value)
        }
    }
    /**
     * 单锁返回「在 now 时刻是否未过期」与该条目的死亡时间（Unix 纳秒，供段级清扫下界使用）。
     * 与 loadIfAlive 共用同一套过期判定（once 从 birth 算、否则从 lastUsed 算）。
     */
    protected func aliveAndDeathNanos(now: DateTime): (Bool, Int64) {
        synchronized(lock) {
            let dead = deathNanosLocked()
            (now.toUnixTimeStamp().toNanoseconds() < dead, dead)
        }
    }
    protected func load(): V {
        synchronized(lock) {
            incr()
            return value
        }
    }
    protected func store(value: V) {
        synchronized(lock) {
            this.value = value
            incr()
        }
    }
}
