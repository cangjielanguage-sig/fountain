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
package fountain::f_llm.store

import std.collection.*
import std.convert.*
import std.sync.*

import fountain::f_store.Store
import fountain::f_util.UUID

/**
 * 租约值：`f_util.UUID` 的**时间型 UUID**（v7，前 48 位是毫秒时间戳）。
 *
 * 直接存 UUID 本身，时间戳从 UUID 里解析——不额外拼前缀，避免出现两种编码格式。
 */
public class TimeUuid {
    private init() {
    }

    /** 生成时间型 UUID（f_util 的 v6：重排后的 v1，时间戳在最前面） */
    public static func create(): String {
        UUID.unixTimeBased().toString()
    }

    /**
     * 从 UUID 里解析秒级时间戳；非法值返回 0（视为「从未执行」）。
     *
     * v7 的高 48 位就是毫秒时间戳，直接按十六进制解析前 12 个字符——
     * 比走 `UUID.timestamp` 更直接，也不受不同版本解码差异影响。
     */
    public static func timestampOf(value: String): Int64 {
        // 先把 UUID 拆成 32 个十六进制半字节（跳过 '-'）
        let nibbles = ArrayList<Int64>()
        for(byte in value.trimAscii().toArray()){
            if(byte == 45u8){
                continue
            }
            let digit = hexDigitOf(byte)
            if(digit < 0){
                return 0
            }
            nibbles.add(digit)
        }
        if(nibbles.size != 32){
            return 0
        }
        // v7 布局：前 6 字节是毫秒时间戳，第 7 字节高 4 位是版本号（=7）
        if(nibbles[12] != 7){
            return 0
        }
        var high48: Int64 = 0
        for(index in 0..12){
            high48 = high48 * 16 + nibbles[index]
        }
        // f_util 的 unixTimeBased 把时间戳右移了 16 位写入前 6 字节，解码时补回来；
        // 因此秒级精度有 ≤66s 误差——对「按天判重」足够，取整后不会跨天漂移。
        let millis = high48 << 16
        millis / 1000
    }

    private static func hexDigitOf(byte: UInt8): Int64 {
        if(byte >= 48u8 && byte <= 57u8){
            return Int64(byte) - 48
        }
        if(byte >= 97u8 && byte <= 102u8){
            return Int64(byte) - 87
        }
        if(byte >= 65u8 && byte <= 70u8){
            return Int64(byte) - 55
        }
        -1
    }

    /** 第几天（epoch 秒 / 86400）：判断「是否今天的租约」用它 */
    public static func dayOf(value: String): Int64 {
        let stamp = timestampOf(value)
        if(stamp <= 0){
            return 0
        }
        stamp / 86400
    }
}

/**
 * 每日执行租约：多进程环境下保证「同一天只有一个进程真正跑演进任务」。
 *
 * 语义是**日期级乐观锁**：读当前值 → 若不是今天的，就生成新值并按旧值做 CAS 覆盖；
 * CAS 成功即抢到本轮执行权，失败（别人先改）就放弃。
 *
 * 为什么按天而不是分布式锁：任务一天只跑一次，冲突窗口极小，
 * 用一个可比较的值 + 条件写就能保证互斥，不需要额外的锁服务。
 */
public interface EvolutionLease {
    /** SQL 实现建表用；local/内存实现无需准备 */
    func ensureSchema(): Unit {
        ()
    }

    /** 启动时调用：没有租约值就写一个；返回当前值 */
    func ensure(now: Int64): String

    /** 当前租约值（空串表示还没有） */
    func current(): String

    /**
     * 尝试领取今天这一轮：成功返回新租约值，失败（别人已领取或 CAS 冲突）返回空串。
     */
    func acquire(now: Int64): String
}

/** 内存实现：单进程测试用 */
public class InMemoryEvolutionLease <: EvolutionLease {
    private let mutex = Mutex()
    private var value: String = ''

    public init() {
    }

    public func ensure(now: Int64): String {
        let box = LeaseBox()
        synchronized(mutex){
            if(value.isEmpty()){
                value = TimeUuid.create()
            }
            box.value = value
        }
        box.value
    }

    public func current(): String {
        let box = LeaseBox()
        synchronized(mutex){
            box.value = value
        }
        box.value
    }

    public func acquire(now: Int64): String {
        let box = LeaseBox()
        synchronized(mutex){
            if(!value.isEmpty() && TimeUuid.dayOf(value) == now / 86400){
                // 今天已经被领取过
                ()
            }else{
                value = TimeUuid.create()
                box.value = value
            }
        }
        box.value
    }
}

/**
 * f_store 实现（本地部署）：租约存一个键。
 *
 * 单进程场景没有并发写者，读-比-写即可；跨进程共用一个 f_store 目录的情况
 * 不在支持范围内（那本就是「本地存储」的语义）。
 */
public class FStoreEvolutionLease <: EvolutionLease {
    private static const KEY = 'f_llm:evo-lease:evolution'

    private let store: Store
    private let mutex = Mutex()

    public init(path: String) {
        this.store = Store(path)
    }

    /** 容器用：路径取 `llm_metaStorePath` */
    public init() {
        this.store = Store(DeployPaths.resolve(StoreSettings.load().metaStorePath))
    }

    public func ensure(now: Int64): String {
        let box = LeaseBox()
        synchronized(mutex){
            let current = read()
            if(current.isEmpty()){
                let created = TimeUuid.create()
                store.add(KEY.toArray(), created.toArray())
                box.value = created
            }else{
                box.value = current
            }
        }
        box.value
    }

    public func current(): String {
        let box = LeaseBox()
        synchronized(mutex){
            box.value = read()
        }
        box.value
    }

    public func acquire(now: Int64): String {
        let box = LeaseBox()
        synchronized(mutex){
            let previous = read()
            if(!previous.isEmpty() && TimeUuid.dayOf(previous) == now / 86400){
                // 今天已经被领取过
                ()
            }else{
                let created = TimeUuid.create()
                store.add(KEY.toArray(), created.toArray())
                box.value = created
            }
        }
        box.value
    }

    private func read(): String {
        match(store.get(KEY.toArray())){
            case Some(bytes) => String.fromUtf8(bytes)
            case None => ''
        }
    }
}

class LeaseBox {
    public var value: String = ''
}
