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
package fountain::f_egraph.loader

import std.collection.ArrayList

/**
 * 流程脚本加载器。
 *
 * `load()` 的每个元素是**一个流程**的 f_jit 编排脚本（语句序列，执行前包裹为 `{ => ... }`，
 * 不追加哨兵表达式）：脚本内实例化 `ImmediateFlow`/`AsyncFlow`、用 `compile(...)` 生成
 * `ClosureTask`，并调用 `registerStart`/`registerEnd`/`registerError`/`registerTask` 完成注册，
 * 末行调用 `removeExceptCurrentTag()` 清理同 category 的旧 tag（末条语句必须是 `Unit` 表达式）。
 *
 * 契约见 `f_egraph/doc/spec/f-egraph-jit-flow-init/design.md` §6；7 条约束见 §6.2；
 * 旧 DSL 到脚本的映射见 §6.4。空脚本视为配置错误，初始化时抛 `GraphException`。
 */
public interface FlowLoader {
    func load(): ArrayList<String>
}