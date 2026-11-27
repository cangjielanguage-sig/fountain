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

import std.collection.ArrayList
import std.collection.HashMap

/**
 * 线程私有的运行期状态（`optimize-runtime-tls`）。
 *
 * 旧实现是 5 份独立的 `ThreadLocal`：deadline、fnTableBase、窗口栈、迭代器表、异常旁路。
 * std `ThreadLocal` 的每次访问约 300 ns，一次调用要付 14 次（约 4.4 µs，占调用成本一半）。
 * 本类把 5 份状态装进**同一个** TLS 载荷：调用方取一次 `RuntimeEnv.current()`，
 * 之后全是字段读写（纳秒级）。
 *
 * **隔离性不变**：对象本身仍只存在于当前线程的 `ThreadLocal<RuntimeState>` 里；
 * 跨线程不可见，重入共享同一对象但按栈式协议保存/恢复。
 *
 * **懒建**：`wins` 的环境窗口由 `HandleTable` 首次使用时补；`faults` 由首次
 * `HostFault.record` 建 —— 健康路径零额外分配。
 */
public class RuntimeState {
    /** 当前调用的绝对截止时刻（epoch ns；`< 0` = 无期限）。 */
    public var deadlineNanos: Int64 = -1

    /** 当前单元的函数入口表基址（`CALL_FUNC` 间接跳转用）。 */
    public var fnTableBase: Int64 = 0

    /** 本线程的窗口栈（栈底 = 环境窗口；由 `HandleTable` 初始化和使用）。 */
    internal let wins: ArrayList<Win> = ArrayList<Win>()

    /** 本线程的迭代器表（调用级；`IterTable` 使用）。 */
    internal let iters: IterState = IterState()

    /** 本线程的异常旁路表（按 ctx 地址索引；首次记录异常时建）。 */
    internal var faults: ?HashMap<UInt64, FaultEntry> = None

    /** 本线程上次命中的空闲分片（`HandleTable.popFree` 的提示；-1 = 未命中过）。 */
    internal var freeHint: Int64 = -1
}
