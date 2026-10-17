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
package fountain::f_jit

// 门面/桥层：用户面 API 的再导出点（见 doc/plan-m1.md §0.4、S0.1 / S6.11）。
//
// 下面是 S0.1 的 `public import` 占位：骨架阶段各子包还没有可导出的声明，先把「根包依赖全部子包、
// 子包之间不成环」这条依赖方向钉住（仓颉禁止包间循环依赖，见 design D2）。
// 用户面清单的最终形态由 S6.11 收口：`JitContext` / `Engine` / `JitValue` / `CompileCache` /
// `AdapterRegistry` / `CompilePipeline` 等执行期内部类型一律不进用户面。
public import fountain::f_jit.base.*
public import fountain::f_jit.bytecode.*
public import fountain::f_jit.compiler.*
public import fountain::f_jit.runtime.*
public import fountain::f_jit.backend.*
