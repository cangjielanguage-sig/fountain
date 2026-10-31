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
package fountain::f_rule.exception

/**
 * 规则引擎统一错误码。
 *
 * 前 14 个码来自 `doc/01-architecture.md` §6，其余为文档其他章节实际使用但未列入的码
 * （`doc/10-roadmap.md` D12）。`toString()` 返回**稳定的大写蛇形名**：日志、决策表错误定位、
 * 下游按文本告警都依赖它，因此改名等同于破坏兼容性。
 *
 * 枚举值可直接用作 `HashMap` 键：`==` 按变体判等，`hashCode` 由稳定名派生，两者自洽。
 */
public enum RuleErrorCode <: ToString & Hashable & Equatable<RuleErrorCode> {
    /** 同一规则集内规则 id 重复。 */
    | DUPLICATE_RULE
    /** 同一事实实例被重复 `assert`。 */
    | DUPLICATE_FACT
    /** 规则没有任何模式。 */
    | EMPTY_PATTERN
    /** 规则引用了未声明的事实库空间。 */
    | UNKNOWN_FACT_SPACE
    /** 规则集没有任何事实库空间。 */
    | EMPTY_FACT_SPACE_SET
    /** 同一规则的模式或 join 跨事实库空间。 */
    | CROSS_SPACE_JOIN
    /** 决策流扇出的两个分支落在同一事实库空间。 */
    | SAME_SPACE_FANOUT
    /** 同一空间内 `typeTag` 被不一致的 schema 重复注册。 */
    | DUPLICATE_TYPE
    /** 模式引用了未注册的 `typeTag`。 */
    | UNKNOWN_TYPE
    /** 约束引用了未注册字段。 */
    | UNKNOWN_FIELD
    /** 决策表输出引用了未声明的绑定名。 */
    | UNKNOWN_BINDING
    /** 算子与操作数类型不兼容。 */
    | TYPE_MISMATCH
    /** 对象当前状态不允许该操作（如冻结后 `set`、绑定名重复）。 */
    | ILLEGAL_STATE
    /** 决策表结构/单元格非法。 */
    | TABLE_INVALID
    /** `Unique` 命中策略下零命中。 */
    | TABLE_NO_MATCH
    /** `Unique`/`Any` 命中策略下多命中。 */
    | TABLE_MULTI_MATCH
    /** 网络/空间集合已冻结后仍尝试注册规则或空间。 */
    | NETWORK_FROZEN
    /** `Agenda.fire` 超过循环上限。 */
    | CYCLE_LIMIT
    /** 脚本条件编译失败。 */
    | SCRIPT_COMPILE
    /** 脚本条件引用的形参在模式绑定中找不到。 */
    | SCRIPT_BINDING_MISSING
    /** 决策流扇出后缺少汇合点。 */
    | FANOUT_WITHOUT_JOIN
    /** 扇出任务没有任何产出分支。 */
    | EMPTY_FANOUT
    /** 重入 `fire`。 */
    | REENTRANT_FIRE
    /** 动作执行抛异常。 */
    | ACTION_FAILED
    /** 未绑定 `FlowContext` 时读取流程上下文。 */
    | NO_CONTEXT
    /** 引擎/会话已关闭。 */
    | CLOSED

    public func toString(): String {
        match (this) {
            case DUPLICATE_RULE => "DUPLICATE_RULE"
            case DUPLICATE_FACT => "DUPLICATE_FACT"
            case EMPTY_PATTERN => "EMPTY_PATTERN"
            case UNKNOWN_FACT_SPACE => "UNKNOWN_FACT_SPACE"
            case EMPTY_FACT_SPACE_SET => "EMPTY_FACT_SPACE_SET"
            case CROSS_SPACE_JOIN => "CROSS_SPACE_JOIN"
            case SAME_SPACE_FANOUT => "SAME_SPACE_FANOUT"
            case DUPLICATE_TYPE => "DUPLICATE_TYPE"
            case UNKNOWN_TYPE => "UNKNOWN_TYPE"
            case UNKNOWN_FIELD => "UNKNOWN_FIELD"
            case UNKNOWN_BINDING => "UNKNOWN_BINDING"
            case TYPE_MISMATCH => "TYPE_MISMATCH"
            case ILLEGAL_STATE => "ILLEGAL_STATE"
            case TABLE_INVALID => "TABLE_INVALID"
            case TABLE_NO_MATCH => "TABLE_NO_MATCH"
            case TABLE_MULTI_MATCH => "TABLE_MULTI_MATCH"
            case NETWORK_FROZEN => "NETWORK_FROZEN"
            case CYCLE_LIMIT => "CYCLE_LIMIT"
            case SCRIPT_COMPILE => "SCRIPT_COMPILE"
            case SCRIPT_BINDING_MISSING => "SCRIPT_BINDING_MISSING"
            case FANOUT_WITHOUT_JOIN => "FANOUT_WITHOUT_JOIN"
            case EMPTY_FANOUT => "EMPTY_FANOUT"
            case REENTRANT_FIRE => "REENTRANT_FIRE"
            case ACTION_FAILED => "ACTION_FAILED"
            case NO_CONTEXT => "NO_CONTEXT"
            case CLOSED => "CLOSED"
        }
    }

    /** 由稳定名派生，保证与 `==` 自洽且 26 个变体互不相同。 */
    public func hashCode(): Int64 {
        "fountain::f_rule.exception.RuleErrorCode.${this}".hashCode()
    }

    public operator func ==(other: RuleErrorCode): Bool {
        match ((this, other)) {
            case (DUPLICATE_RULE, DUPLICATE_RULE) => true
            case (DUPLICATE_FACT, DUPLICATE_FACT) => true
            case (EMPTY_PATTERN, EMPTY_PATTERN) => true
            case (UNKNOWN_FACT_SPACE, UNKNOWN_FACT_SPACE) => true
            case (EMPTY_FACT_SPACE_SET, EMPTY_FACT_SPACE_SET) => true
            case (CROSS_SPACE_JOIN, CROSS_SPACE_JOIN) => true
            case (SAME_SPACE_FANOUT, SAME_SPACE_FANOUT) => true
            case (DUPLICATE_TYPE, DUPLICATE_TYPE) => true
            case (UNKNOWN_TYPE, UNKNOWN_TYPE) => true
            case (UNKNOWN_FIELD, UNKNOWN_FIELD) => true
            case (UNKNOWN_BINDING, UNKNOWN_BINDING) => true
            case (TYPE_MISMATCH, TYPE_MISMATCH) => true
            case (ILLEGAL_STATE, ILLEGAL_STATE) => true
            case (TABLE_INVALID, TABLE_INVALID) => true
            case (TABLE_NO_MATCH, TABLE_NO_MATCH) => true
            case (TABLE_MULTI_MATCH, TABLE_MULTI_MATCH) => true
            case (NETWORK_FROZEN, NETWORK_FROZEN) => true
            case (CYCLE_LIMIT, CYCLE_LIMIT) => true
            case (SCRIPT_COMPILE, SCRIPT_COMPILE) => true
            case (SCRIPT_BINDING_MISSING, SCRIPT_BINDING_MISSING) => true
            case (FANOUT_WITHOUT_JOIN, FANOUT_WITHOUT_JOIN) => true
            case (EMPTY_FANOUT, EMPTY_FANOUT) => true
            case (REENTRANT_FIRE, REENTRANT_FIRE) => true
            case (ACTION_FAILED, ACTION_FAILED) => true
            case (NO_CONTEXT, NO_CONTEXT) => true
            case (CLOSED, CLOSED) => true
            case _ => false
        }
    }
}
