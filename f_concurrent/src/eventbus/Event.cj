/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_concurrent.eventbus

import std.sync.{AtomicUInt64, AtomicBool, AtomicInt64, AtomicReference}
import f_base.*

/**
 * 如果一个业务流程有许多步，每一步可以定义成一个事件，把这些事件注册到concurrent.eventbus.EventBus
 */
public abstract class Event <: Hashable & Equatable<Event> & ToString {
    private static let ORDINAL_GEN = AtomicUInt64(1)
    public let ordinal = ORDINAL_GEN.fetchAdd(1)
    public prop name: String
    private var data = AtomicReference<Box<?Any>>(Box<?Any>(None<Any>))
    let arrangedThreadId_ = AtomicInt64(0)
    let workerId_ = AtomicInt64(-1)
    private var deliverResult_ = AtomicBool(true)

    mut prop arrangedThreadId: Int64 {
        get() {
            arrangedThreadId_.load()
        }
        set(value) {
            arrangedThreadId_.store(value)
        }
    }
    mut prop workerId: Int64 {
        get() {
            workerId_.load()
        }
        set(value) {
            workerId_.store(value)
        }
    }
    public mut prop deliverResult: Bool {
        get() {
            deliverResult_.load()
        }
        set(value) {
            deliverResult_.store(value)
        }
    }
    public func getData<T>(): ?T {
        match (data.load().value) {
            case Some(x) => x as T
            case _ => None<T>
        }
    }
    public func setData(value: Any) {
        data.store(Box<?Any>(Some(value)))
    }
    public func setNoneData() {
        if (let Some(_) <- data.load().value) {
            data.store(Box<?Any>(None<Any>))
        }
    }
    public open prop startEvent: Bool {
        get() {
            false
        }
    }
    public open func hashCode(): Int64 {
        name.hashCode()
    }
    public operator func ==(e: Event): Bool {
        name == e.name
    }
    public func toString(): String {
        name
    }
}
