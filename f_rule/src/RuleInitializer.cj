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
package fountain::f_rule

import fountain::f_app.Initializer
import fountain::f_app.InitializerCollection
import fountain::f_rule.runtime.RuleRuntime

/**
 * `f_rule` 的 `f_app` 初始化项（与 `f_health` / `f_egraph` 同型）。
 *
 * `initialize()` 只保证共享编译器可用；规则集由应用显式构建与注入，不在初始化阶段加载。
 * 依赖 `fountain::f_egraph` 是因为规则流程（M4）会注册到 `f_egraph` 的事件分发器上，
 * 且两者共用同一个 `Compiler`。
 */
public struct RuleInitializer <: Initializer {
    static init() {
        InitializerCollection.register(RuleInitializer())
    }

    /** 包内可见：应用只应通过 `InitializerCollection` 使用本类型，测试需直接构造。 */
    init() {}

    public prop name: String {
        get() {
            "fountain::f_rule"
        }
    }

    public prop dependencies: Array<String> {
        get() {
            ["fountain::f_egraph"]
        }
    }

    public func initialize(): Unit {
        let _ = RuleRuntime.compiler()
    }
}
