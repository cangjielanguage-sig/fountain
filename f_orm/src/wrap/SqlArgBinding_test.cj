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
package fountain::f_orm.wrap

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.database.sql.*
import fountain::f_orm.exception.*

/** 记录 set/setNull 调用的最小 Statement 实现：不做类型转换、不做任何校验，只记账 */
private class RecordingStatement <: Statement {
    let calls = ArrayList<String>()
    public prop parameterColumnInfos: Array<ColumnInfo> {
        get() {
            []
        }
    }
    public func query(params: Array<SqlDbType>): QueryResult {
        throw Exception('recorder: not used')
    }
    public func update(params: Array<SqlDbType>): UpdateResult {
        throw Exception('recorder: not used')
    }
    public func setOption(key: String, value: String): Unit {}
    public func set<T>(index: Int, value: T): Unit {
        calls.add('set<${TypeInfo.of<T>()}>(${index})')
    }
    public func setNull(index: Int): Unit {
        calls.add('setNull(${index})')
    }
    public func update(): UpdateResult {
        throw Exception('recorder: not used')
    }
    public func query(): QueryResult {
        throw Exception('recorder: not used')
    }
    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {}
}

/** 故意把 T 与 value 的类型错开，用于钉住 setValue 兜底必须抛异常（bug-orm.md ORM-N2） */
private class MismatchSqlArg <: SqlArg {
    public MismatchSqlArg(index: Int64) {
        super(index)
    }
    public func set(statement: Statement): Unit {
        setValue<Int64>(statement, 'not-an-int64')
    }
    public func toString(): String {
        'mismatch'
    }
    public func hashCode(): Int64 {
        0
    }
    public operator func ==(other: SqlArg): Bool {
        refEq(this, other)
    }
}

/**
 * 参数绑定的「出口」契约（bug-orm.md ORM-N2）。
 *
 * `SqlExecutor → SqlArgs.set(statement) → SqlArg.set(statement) → Statement.set<T>/setNull` 是 ORM 把值交给驱动的
 * **唯一通道**：某个 `SqlArg` 不调 `Statement.set`，那么任何驱动实现都拿不到这个值（与驱动是否有逻辑无关，
 * 所以这里用自制记录器，不依赖 MOCKDB）。用例逐个类型钉住：
 *
 * 1. 每个受支持类型经 `SqlArgs` 绑定后，必须**恰好一次**调用 `Statement.set<T>`，且 T 是该参数交出去时声明的类型
 *    （`Float16` 升为 `Float32`、`BigInt` 转 `String` 是既定约定）；
 * 2. 空值走 `setNull`（`?T` 在 `SqlExecutor.add(arg: ?T)` 层就被拆开：`Some`→`add(x)`、`None`→`addNull()`，
 *    到 `SqlArgs` 这层只剩「值」与 `addNull` 两种形态）；
 * 3. T 与值类型不匹配时必须抛 `SqlArgException`——兜底若只构造异常不 `throw`，「参数根本没交给驱动」就会变成
 *    静默行为（`Float32SqlArg` 曾因 `setValue<Float64>(…, Float32值)` 静默丢参）。
 *
 * 未列入：`InputStream`（需要造流实现）与 `Array<Byte>`（`set` 调用形式是直传、不涉及类型转换）。
 */
@Test
public class SqlArgBindingTest {
    /** 期望恰好一次调用，且该调用的类型片段与 expected 相符；不符则返回诊断串 */
    private static func expectOnce(tag: String, expected: String, args: SqlArgs): String {
        let stmt = RecordingStatement()
        args.set(stmt)
        if (stmt.calls.size != 1 || !stmt.calls[0].contains(expected)) {
            return '${tag}: 期望 1 次含[${expected}]，实得 ${stmt.calls.size} 次 ${stmt.calls}; '
        }
        ''
    }

    @TestCase
    public func testEverySupportedTypeBindsExactlyOnce(): Unit {
        let f16: Float16 = 1.5
        let f32: Float32 = 1.5
        let f64: Float64 = 1.5
        let dur: Duration = Duration.second
        let dt: DateTime = DateTime.now()
        let big = BigInt(true, 1)
        var bad = ''

        func check(tag: String, expected: String, bind: (SqlArgs) -> Unit): Unit {
            let args = SqlArgs()
            bind(args)
            bad += expectOnce(tag, expected, args)
        }
        check('Bool', 'Bool', {a => a.add(true)})
        check('Int8', 'Int8', {a => a.add(Int8(1))})
        check('UInt8', 'UInt8', {a => a.add(UInt8(1))})
        check('Int16', 'Int16', {a => a.add(Int16(1))})
        check('UInt16', 'UInt16', {a => a.add(UInt16(1))})
        check('Int32', 'Int32', {a => a.add(Int32(1))})
        check('UInt32', 'UInt32', {a => a.add(UInt32(1))})
        check('Int64', 'Int64', {a => a.add(Int64(1))})
        check('UInt64', 'UInt64', {a => a.add(UInt64(1))})
        // Float16 → Float32、BigInt → String 是既定约定（驱动不支持的窄类型在 SqlArg 侧先转换）
        check('Float16→Float32', 'Float32', {a => a.add(f16)})
        check('Float32', 'Float32', {a => a.add(f32)})
        check('Float64', 'Float64', {a => a.add(f64)})
        check('BigInt→String', 'String', {a => a.add(big)})
        check('Rune', 'Rune', {a => a.add(r'a')})
        check('String', 'String', {a => a.add('x')})
        check('Duration', 'Duration', {a => a.add(dur)})
        check('DateTime', 'DateTime', {a => a.add(dt)})
        check('addNull→setNull', 'setNull', {a => a.addNull()})
        @Assert('', bad)
    }

    @TestCase
    public func testMismatchedValueMustThrow(): Unit {
        var threw = false
        try {
            MismatchSqlArg(0).set(RecordingStatement())
        } catch (e: SqlArgException) {
            threw = true
        }
        @Assert(true, threw)
    }
}
