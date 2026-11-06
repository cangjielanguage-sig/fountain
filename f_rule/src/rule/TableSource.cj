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
package fountain::f_rule.rule

import fountain::f_rule.fact.FactSpaceRegistry

/**
 * 决策表在规则装配期的抽象（`doc/11-assembly.md` §4.1）。
 *
 * `table` 包依赖 `rule` 包，因此 `RuleSetBuilder` 不能引用 `DecisionTable`。
 * 该接口把「表 → 规则」的能力反转：由表实现，装配器只按接口调用。
 *
 * 只保留「编译」一项能力：表 id、版本、空间都是表编译期的内部输入，
 * 装配器不需要，也不该让 `rule` 包认识这些概念。
 */
public interface TableSource {
    /**
     * 编译成规则。
     *
     * @param registry 已声明的事实空间与类型，用于校验条件/输出列引用的字段
     * @throws RuleException TABLE_INVALID / UNKNOWN_FACT_SPACE / UNKNOWN_FIELD / TYPE_MISMATCH
     */
    func compileInto(registry: FactSpaceRegistry): Array<Rule>
}
