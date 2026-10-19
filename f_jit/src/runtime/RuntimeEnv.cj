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
    /** 绝对截止时刻（epoch 纳秒）；`< 0` = 无期限。 */
    public static var deadlineNanos: Int64 = -1

    /** 置一个绝对截止时刻（epoch 纳秒）。 */
    public static func setDeadline(nanos: Int64): Unit {
        deadlineNanos = nanos
    }

    /** 清除期限（默认状态）。 */
    public static func clearDeadline(): Unit {
        deadlineNanos = -1
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
    public static var fnTableBase: Int64 = 0

    public static func setFnTableBase(base: Int64): Unit {
        fnTableBase = base
    }

    public static func reset(): Unit {
        fnTableBase = 0
    }
}
