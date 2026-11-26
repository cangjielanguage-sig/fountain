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

import std.collection.ArrayList
import std.sync.Mutex
import fountain::f_jit.Compiler
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{FactSpaceRegistry, FieldType}
import fountain::f_rule.rule.{Rule, RuleSet, TableSource}
import fountain::f_rule.runtime.RuleRuntime

/**
 * 惰性行来源（`doc/07` §6.4）。
 *
 * 流式 XLSX 表只保留表头与表属性，数据行在读的时候现取，`DecisionTable.rows`
 * 保持为空——这样 10 万行的表也不会把行材料化。
 */
public interface TableRowSource {
    /** 新开一个数据行迭代器；每次调用都从第一行数据开始。 */
    func rows(): Iterator<TableRow>
}

/**
 * 决策表模型（`doc/07-decision-table.md` §1）。
 *
 * 一张表绑定一个 `factSpace` 与一个 `factType`；`factType` 未声明时按空间内
 * 唯一类型推断（设计 D9）。`hitPolicy` 只影响结果聚合，不进入单条规则。
 */
public class DecisionTable <: TableSource {
    public let id: String
    public let name: String
    public let version: String
    public let factSpace: String
    /** 空串表示未声明，编译时按空间类型推断。 */
    public let factType: String
    public let hitPolicy: HitPolicy
    public let columns: Array<Column>
    public let rows: Array<TableRow>
    /** 行未声明 salience 时使用的缺省值。 */
    public let salience: Int64
    /** `Priority` / `OutputOrder` 使用的输出列顺序。 */
    public let outputOrder: Array<String>
    /**
     * 载体声明的列类型（XLSX 类型行或按单元格推断，`doc/07` §6.3）。
     *
     * 与 [columns] 等长；`None` 表示载体没有给出信息（CSV 载体全为 `None`）。
     * 它只用于编译期与字段声明比对（冲突时以字段声明为准并 WARN），
     * 不参与取值解析。
     */
    public let columnTypes: Array<?FieldType>
    /** 惰性行来源；非 `None` 时 [rows] 为空，数据行走 [rowIterator]。 */
    private let rowSource_: ?TableRowSource
    private let modeMutex_: Mutex
    private var mode_: TableMode

    init(id: String, name: String, version: String, factSpace: String, factType: String,
        hitPolicy: HitPolicy, columns: Array<Column>, rows: Array<TableRow>, salience: Int64,
        outputOrder: Array<String>, columnTypes!: Array<?FieldType> = Array<?FieldType>(),
        rowSource!: ?TableRowSource = None) {
        this.id = id
        this.name = name
        this.version = version
        this.factSpace = factSpace
        this.factType = factType
        this.hitPolicy = hitPolicy
        this.columns = columns
        this.rows = rows
        this.salience = salience
        this.outputOrder = outputOrder
        this.columnTypes = columnTypes
        this.rowSource_ = rowSource
        this.modeMutex_ = Mutex()
        this.mode_ = TableMode.Unbound
    }

    /** 当前执行路径；两条路径硬互斥（`doc/11-assembly.md` §4.5）。 */
    public prop mode: TableMode {
        get() {
            synchronized(modeMutex_) {
                mode_
            }
        }
    }

    /** 装配路径占用实例；已被聚合路径使用时抛 `TABLE_MODE_CONFLICT`。 */
    func markAssembled(): Unit {
        synchronized(modeMutex_) {
            match (mode_) {
                case Executed =>
                    throw RuleException(
                        RuleErrorCode.TABLE_MODE_CONFLICT,
                        "决策表 ${id} 已用于聚合路径（TableExecutor），不能再装配进规则集；" +
                        "两条路径互斥，请新建表实例"
                    )
                case _ => mode_ = TableMode.Assembled
            }
        }
    }

    /** 聚合路径占用实例；已被装配路径使用时抛 `TABLE_MODE_CONFLICT`。 */
    func markExecuted(): Unit {
        synchronized(modeMutex_) {
            match (mode_) {
                case Assembled =>
                    throw RuleException(
                        RuleErrorCode.TABLE_MODE_CONFLICT,
                        "决策表 ${id} 已装配进规则集，不能再用于 TableExecutor；" +
                        "两条路径互斥，请新建表实例"
                    )
                case _ => mode_ = TableMode.Executed
            }
        }
    }

    public static func builder(id: String): DecisionTableBuilder {
        DecisionTableBuilder(id)
    }

    /** 单模式表的绑定名；没有条件列时取缺省 `o`。 */
    public prop binding: String {
        get() {
            for (column in columns) {
                if (column.kind == ColumnKind.When) {
                    return column.binding
                }
            }
            "o"
        }
    }

    public func columnsOf(kind: ColumnKind): Array<Column> {
        let out = ArrayList<Column>()
        for (column in columns) {
            if (column.kind == kind) {
                out.add(column)
            }
        }
        out.toArray()
    }

    /** 是否走惰性行来源（流式 XLSX 表）；此时 [rows] 为空。 */
    public prop streaming: Bool {
        get() {
            rowSource_.isSome()
        }
    }

    /**
     * 数据行迭代器。
     *
     * 整表路径遍历 [rows]；流式路径在每次调用时现读现给（`doc/07` §6.4），
     * 因此不要同时持有两个迭代器。
     */
    public func rowIterator(): Iterator<TableRow> {
        match (rowSource_) {
            case Some(source) => source.rows()
            case None => rows.iterator()
        }
    }

    /** 第 [index] 列的载体声明类型；越界或未声明返回 `None`。 */
    public func columnTypeAt(index: Int64): ?FieldType {
        if (index < 0 || index >= Int64(columnTypes.size)) {
            return None<FieldType>
        }
        columnTypes[index]
    }

    /**
     * 解析 `when.*` 作用的事实类型。
     *
     * 显式 `factType` 优先；未声明时空间必须恰好有一个类型，否则 `TABLE_INVALID`。
     */
    public func resolvedFactType(registry: FactSpaceRegistry): String {
        let space = match (registry.get(factSpace)) {
            case Some(found) => found
            case None =>
                throw RuleException(
                    RuleErrorCode.UNKNOWN_FACT_SPACE,
                    "决策表 ${id} 引用了未声明的事实空间 ${factSpace}"
                )
        }
        if (factType != "") {
            if (!space.hasType(factType)) {
                throw RuleException(
                    RuleErrorCode.UNKNOWN_TYPE,
                    "空间 ${factSpace} 未注册类型 ${factType}"
                )
            }
            return factType
        }
        let types = space.typeTags()
        if (types.size == 1) {
            return types[0]
        }
        if (types.size == 0) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_TYPE,
                "空间 ${factSpace} 没有任何已注册类型，决策表 ${id} 无法推断 factType"
            )
        }
        throw RuleException(
            RuleErrorCode.TABLE_INVALID,
            "空间 ${factSpace} 注册了 ${types.size} 个类型，决策表 ${id} 需要显式声明 factType"
        )
    }

    /**
     * 编译为规则（`doc/07-decision-table.md` §7）。
     *
     * 无 `expr` 列时不需要 `f_jit` 注册；有 `expr` 列时建议用
     * `RuleSetBuilder.table()` 或带 `compiler` 的重载，以复用应用的共享编译器。
     */
    public func compile(ruleSet: RuleSet): Array<Rule> {
        compileInto(ruleSet.registry)
    }

    public func compile(ruleSet: RuleSet, compiler: Compiler): Array<Rule> {
        markAssembled()
        TableCompiler(this, ruleSet.registry, compiler, agendaPath: true).compile().rules
    }

    /**
     * 编译成规则（`TableSource`，`doc/11-assembly.md` §4.1）。
     *
     * 使用进程级共享编译器，脚本条件与代码规则命中同一份类型注册表。
     */
    public func compileInto(registry: FactSpaceRegistry): Array<Rule> {
        markAssembled()
        TableCompiler(this, registry, RuleRuntime.compiler(), agendaPath: true).compile().rules
    }

    public func toString(): String {
        "DecisionTable(${id}, ${rows.size} rows, ${hitPolicy})"
    }
}
