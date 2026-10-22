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
package fountain::f_jit.base

import std.time.DateTime

/**
 * 桥侧调用参数 —— design-m1 §2.3.4、plan-m1 S1.6、规格 §8。
 *
 * | 成员 | 意义 |
 * |---|---|
 * | `args: Array<Int64>` | 入参 cell 数组（Marshal 结果），三态收尾第 2 步 `rawEntry(ctx, &args[0], nargs)` |
 * | `deadline: ?DateTime` | 配合 `interrupt_poll`，到期 → -2（`LOOP_BACK` 安全点查询） |
 *
 * **默认值契约**（spec「公共值类型」）：`deadline=None`。
 *
 * **只装调用级选项（X3）**：`strictFp` 与 `literalCopy` 已移除。前者是**产物属性**，归
 * `CompileOptions.strictFp`（决定 `/` 发 `FDIV` 还是 `FDIV_CHK`）；后者从无消费语义——
 * 字面量是编译期常量，桥层不存在「深拷贝字面量」的时机。
 */
public struct CallContext {
    /**
     * 截止时间：到期后 `interrupt_poll` 写 -2（`None` = 不设期限，默认）。
     *
     * **不可变值语义**：调用级选项在构造时给定、之后只读——需要不同期限就构造新值
     * （struct 逐值复制，成本 = 一个 `?DateTime`）。
     *
     * **为何删掉 `args`**：桥的实参走 `call<T>(args: Array<Any>)` 形参并经 `CallMarshal`
     * 封送，`ctx.args` 从未被任何执行路径读取（全仓 grep 仅测试使用）；保留它会让
     * "ctx 里放什么"有两个真相来源。默认构造即 `CallContext()`。
     */
    public CallContext(public let deadline!: ?DateTime = None) {}
}
