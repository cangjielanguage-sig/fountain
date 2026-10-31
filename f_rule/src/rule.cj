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

/**
 * `f_rule` 包根：规则引擎门面。
 *
 * 门面只做重导出，具体实现落在子包，避免根包反向依赖导致包循环：
 * `rule` 提供模型与装配器，`agenda` 提供议程与动作，`rete` 提供匹配网络，
 * `engine` 提供引擎与会话门面，`flow` 提供流程编排（依赖 `engine`）。
 */

public import fountain::f_rule.rule.RuleSetBuilder
public import fountain::f_rule.rule.{DefaultConflictResolver, Rule, RuleSet}
public import fountain::f_rule.runtime.RuleRuntime
public import fountain::f_rule.agenda.{Agenda, Bindings, FireMode, Activation}
public import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle, FactSchema, FactSpace, TypedFact}
public import fountain::f_rule.condition.{Operator, Pattern}
public import fountain::f_rule.engine.{FiredRule, FireResult, RuleEngine, RuleSession}
public import fountain::f_rule.flow.*
