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
package fountain::f_jit.runtime

import std.time.DateTime

/**
 * 调用级运行期环境（安全点判据）—— §5 `LOOP_BACK`（`STACK_GUARD` + `interrupt_poll`）与
 * §12.6「无限循环可中断」。
 *
 * `deadline` 由桥在调用前按 `CallContext.deadline` 写入（§8.2）；`interrupt_poll`（H22）只做
 * 「读时钟 → 比对」这一件事，到期即写 `ErrCode.INTERRUPT(-2)`。**ctx 不携带 deadline**（§1 的
 * 64 B 布局已冻结），故它挂在调用级环境上。
 */
public class RuntimeEnv {
    /**
     * 线程私有的运行期状态（`optimize-runtime-tls`）：deadline / fnTableBase / 窗口栈 /
     * 迭代器表 / 异常旁路合并为一个载荷，调用路径只取一次。
     */
    private static let stateTls = ThreadLocal<RuntimeState>()

    /** 取当前线程的状态对象；首次访问时构造。 */
    public static func current(): RuntimeState {
        match (stateTls.get()) {
            case Some(s) => s
            case None =>
                let s = RuntimeState()
                stateTls.set(Some(s))
                s
        }
    }

    public static mut prop deadlineNanos: Int64 {
        get() {
            RuntimeEnv.current().deadlineNanos
        }
        set(v) {
            RuntimeEnv.current().deadlineNanos = v
        }
    }

    /** 置一个绝对截止时刻（epoch 纳秒）。 */
    public static func setDeadline(nanos: Int64): Unit {
        RuntimeEnv.current().deadlineNanos = nanos
    }

    /** 清除期限（默认状态）。 */
    public static func clearDeadline(): Unit {
        RuntimeEnv.current().deadlineNanos = -1
    }

    /**
     * `CallContext.deadline` → 绝对截止纳秒（`None` ⇒ −1 = 无期限）。
     *
     * 极端时刻（超出 `Duration` 纳秒表示）退化为 ±哨兵而不是抛异常：期限只是「尽快停」的
     * 提示，不应让一次调用在建窗阶段就失败。
     */
    public static func deadlineNanosOf(d: ?DateTime): Int64 {
        match (d) {
            case Some(v) =>
                try {
                    v.toUnixTimeStamp().toNanoseconds()
                } catch (_: Exception) {
                    if (v.toUnixTimeStamp() > Duration.Zero) { Int64.Max } else { Int64.Min }
                }
            case None => -1
        }
    }

    /** 当前时刻（epoch 纳秒）。 */
    public static func nowNanos(): Int64 {
        DateTime.nowUTC().toUnixTimeStamp().toNanoseconds()
    }

    /** 期限是否已到（无期限恒 false）。 */
    public static func deadlineExpired(): Bool {
        if (deadlineNanos < 0) {
            false
        } else {
            nowNanos() >= deadlineNanos
        }
    }
}

/**
 * 机器侧资产（backend 写入、runtime 只读）—— §5.3.4 `fn_table`（H57）。
 *
 * `fnTableBase` 是**非 GC 内存**中的函数入口表基址（S5.2 `FnTable`）；纯字节码（解释器）形态
 * 恒为 0 —— H57 由此返回 0，三形态的接口一致、语义由桥按引擎解释。
 */
public class MachineEnv {
    /**
     * 函数入口表基址（H57 `fn_table` 读）。**线程私有**（并行调用 D4）：
     * 每个线程执行的是自己的单元入口，进程级全局会让并发执行串表。
     *
     * 存储已并入 `RuntimeState`（`optimize-runtime-tls`），这里只保留公开访问器。
     */
    public static mut prop fnTableBase: Int64 {
        get() {
            RuntimeEnv.current().fnTableBase
        }
        set(v) {
            RuntimeEnv.current().fnTableBase = v
        }
    }

    public static func setFnTableBase(base: Int64): Unit {
        RuntimeEnv.current().fnTableBase = base
    }

    public static func reset(): Unit {
        RuntimeEnv.current().fnTableBase = 0
    }
}
