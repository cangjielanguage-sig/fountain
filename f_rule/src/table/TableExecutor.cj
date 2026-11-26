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
package fountain::f_rule.table

import std.collection.{ArrayList, HashMap}
import fountain::f_jit.Compiler
import fountain::f_rule.condition.Truth
import fountain::f_rule.fact.{Fact, FactBaseView, FactSpaceRegistry}

/** 单行求值结果：是否命中、命中的事实与逐列 trace。 */
class RowOutcome {
    let matched: Bool
    let fact: ?Fact
    let trace: RowTrace

    init(matched: Bool, fact: ?Fact, trace: RowTrace) {
        this.matched = matched
        this.fact = fact
        this.trace = trace
    }
}

/**
 * 决策表执行器（`doc/07-decision-table.md` §7/§9）。
 *
 * 单模式表直接在事实视图上逐行求值（与议程语义等价，且能给出逐列 trace），
 * 再按 `HitPolicy` 聚合。行序即 `DecisionTable.rows` 顺序，`Collect` 类策略依赖它。
 */
public class TableExecutor {
    private let table_: DecisionTable
    private let compiled_: CompiledTable

    /** 无 `expr` 列时使用；有 `expr` 列请用带 `compiler` 的重载。 */
    public init(table: DecisionTable, registry: FactSpaceRegistry) {
        this(table, registry, Compiler())
    }

    public init(table: DecisionTable, registry: FactSpaceRegistry, compiler: Compiler) {
        table.markExecuted()
        this.table_ = table
        this.compiled_ = TableCompiler(table, registry, compiler).compile()
    }

    /** 在给定事实视图上执行；`trace = true` 时返回逐行逐列判定明细。 */
    public func execute(facts: FactBaseView, trace!: Bool = false): TableResult {
        let candidates = collect(facts)
        let hits = ArrayList<TableHit>()
        let traces = ArrayList<RowTrace>()
        for (row in compiled_.rows) {
            let outcome = evaluate(row, candidates)
            if (outcome.matched) {
                hits.add(TableHit(row.row, outputsOf(row, outcome.fact.getOrThrow()), row.salience))
            }
            if (trace) {
                traces.add(outcome.trace)
            }
        }
        let aggregated = HitAggregator(table_.hitPolicy, outputOrder: table_.outputOrder)
            .aggregate(hits.toArray())
        let hitRows = ArrayList<TableRow>()
        let outputs = ArrayList<HashMap<String, Any>>()
        for (hit in aggregated) {
            hitRows.add(hit.row)
            outputs.add(hit.outputs)
        }
        TableResult(hitRows.toArray(), outputs.toArray(), traces.toArray())
    }

    private func collect(facts: FactBaseView): Array<Fact> {
        let out = ArrayList<Fact>()
        for (handle in facts.scan(compiled_.factType)) {
            match (facts.get(handle)) {
                case Some(fact) => out.add(fact)
                case None => ()
            }
        }
        out.toArray()
    }

    /** 任一条事实满足全部条件即命中；trace 取第一个命中事实，否则取第一个候选。 */
    private func evaluate(row: CompiledRow, candidates: Array<Fact>): RowOutcome {
        var results = Array<Truth>()
        var matched: ?Fact = None
        for (fact in candidates) {
            let perFact = evaluateConditions(row, fact)
            if (allTrue(perFact)) {
                matched = Some(fact)
                results = perFact
                break
            }
            if (results.size == 0) {
                results = perFact
            }
        }
        if (results.size == 0) {
            let unknowns = ArrayList<Truth>()
            for (condition in row.conditions) {
                let _ = condition
                unknowns.add(Truth.False)
            }
            results = unknowns.toArray()
        }
        let columns = ArrayList<ColumnTrace>()
        var index: Int64 = 0
        for (condition in row.conditions) {
            columns.add(ColumnTrace(condition.column.name, results[index]))
            index += 1
        }
        RowOutcome(matched.isSome(), matched,
            RowTrace(row.row.line, row.row.ruleId, columns.toArray(), matched.isSome()))
    }

    private func evaluateConditions(row: CompiledRow, fact: Fact): Array<Truth> {
        let results = ArrayList<Truth>()
        let bindings = HashMap<String, Fact>()
        bindings[compiled_.binding] = fact
        for (condition in row.conditions) {
            match (condition.constraint) {
                case Some(constraint) =>
                    results.add(constraint.eval(fact))
                case None =>
                    match (condition.expression) {
                        case Some(expression) =>
                            if (expression.eval(bindings)) {
                                results.add(Truth.True)
                            } else {
                                results.add(Truth.False)
                            }
                        case None => results.add(Truth.True)
                    }
            }
        }
        results.toArray()
    }

    private func allTrue(results: Array<Truth>): Bool {
        for (result in results) {
            if (!result.isTrue()) {
                return false
            }
        }
        true
    }

    private func outputsOf(row: CompiledRow, fact: Fact): HashMap<String, Any> {
        let outputs = HashMap<String, Any>()
        let bindings = HashMap<String, Fact>()
        bindings[compiled_.binding] = fact
        for (output in row.outputs) {
            match (output.cell.resolve(bindings)) {
                case Some(value) => outputs[output.name] = value
                case None => ()
            }
        }
        outputs
    }
}
