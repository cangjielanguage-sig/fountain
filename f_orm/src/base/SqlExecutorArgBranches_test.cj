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
package fountain::f_orm.base

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.database.sql.*
import fountain::f_mockdb.*
import fountain::f_orm.wrap.*
import fountain::f_orm.exception.*

private func isStringArg(a: Any): Bool {
    match (a) {
        case _: String => true
        case _ => false
    }
}

/**
 * 按值绑定（`Any` 入口）时每个类型分支都必须照旧命中（bug.md §2.13/§2.14）。
 *
 * 背景：`SqlExecutor.add<T>`、`RootDAO.arg<I,T>`、`RootDAO.arg(Any)` 三处的 40+ 分支 `match`
 * 在 2026-10-05 按绑定频率重排过（纯顺序调整）。本用例给出运行期护栏：
 *
 * 1. `arg(Any)`：受支持类型必须命中具体分支并返回 `'?'`——若分支缺失会走 `case _ => throw SqlArgException`，
 *    因此「不抛异常」即证明该类型的分支仍在；
 * 2. `add(Any)`：绑定后 mock 必须收到**恰好 1 个**参数，且该参数不是 `toString()` 兜底产生的 `String`
 *    （`add<T>` 的兜底是 `add(x.toString())`）——若某类型分支缺失，参数会变成 `String` 而被断言抓到。
 *    `String`/`?String` 两类是天然盲区（取值与兜底同形），故排除在「非 String」断言之外；
 * 3. 反向例：既不在受支持清单、又实现了 `ToString` 的值（`TransactionStatus.Unknown`），`arg(Any)` 必须抛
 *    `SqlArgException`，`add(Any)` 必须落到 `add<T>` 的 `toString()` 兜底（mock 收到 `'Unknown'`）。
 *
 * 覆盖范围：Bool/Int8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Float64/Rune/String/
 * Duration/DateTime/Array<Byte> 及 `?Bool/?Int64/?String/?DateTime`（含 `None`）。BigInt/Decimal/Float16
 * 等其余分支的「仍在」由同一机制的机械核对保证（`case` 行多重集：改动前后一致，仅去掉 2 行恒不可达的重复）。
 * Float32 原本因 ORM-N2（静默丢参）摘出，修复后已加回；绑出口的一次性调用由 wrap 层 `SqlArgBindingTest` 钉住。
 *
 * 每个类型用各自 SQL 文本：executor 与结果缓存按线程复用，共用文本会互相命中缓存。
 */
@Test
public class SqlExecutorArgBranchesTest {
    /** mock 行为：把本次执行收到的参数收进 `captured`；查询路径会读结果集列信息，夹具须一并给出 */
    private func captureArgs(captured: ArrayList<Any>, execs: ArrayList<String>): Unit {
        MOCKDB.execution = {sql: String, args: ArrayList<Any> =>
            execs.add(sql)
            for (a in args) {
                captured.add(a)
            }
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlBigInt')
        }
    }

    @TestCase
    public func testEverySupportedTypeStaysOnItsOwnBranch(): Unit {
        let captured = ArrayList<Any>()
        let execs = ArrayList<String>()
        captureArgs(captured, execs)
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        let bin: Array<Byte> = [UInt8(1), UInt8(2)]
        let nInt64: ?Int64 = None<Int64>
        // (标签, 值)；标签进 SQL 文本，避开结果缓存
        let cases: Array<(String, Any)> = [
            ('bool', true),
            ('int8', Int8(1)),
            ('uint8', UInt8(1)),
            ('int16', Int16(1)),
            ('uint16', UInt16(1)),
            ('int32', Int32(1)),
            ('uint32', UInt32(1)),
            ('int64', Int64(1)),
            ('uint64', UInt64(1)),
            ('float32', Float32(1.5)),
            ('float64', 1.5),
            ('rune', r'a'),
            ('string', 'x'),
            ('duration', Duration.second),
            ('datetime', DateTime.now()),
            ('arraybyte', bin),
            ('nbool', Some(true)),
            ('nint64', Some(Int64(1))),
            ('nstring', Some('x')),
            ('ndatetime', Some(DateTime.now())),
            ('nnull', nInt64)
        ]
        var bad = ''
        try {
            for ((tag, v) in cases) {
                // 1. arg(Any)：命中具体分支才返回 '?'，兜底会抛 SqlArgException
                let argSql = ex.arg(v)
                if (argSql != '?') {
                    bad += '${tag}(arg=${argSql}) '
                }
                // arg(Any) 命中分支时会顺手把参数绑进 executor（`arg(x)` 内部调 `executor.add`），
                // 先复位再跑下面的查询，否则这次查询会多带一个参数
                ex.clearSql()
                // 2. add(Any)：必须绑定 1 个参数；非 String 类型不得落进 toString() 兜底
                // 夹具是静态槽（同一进程其他用例会各自改写），每轮重设一次，把「被别人占用」的窗口压到最小
                captureArgs(captured, execs)
                captured.clear()
                execs.clear()
                ex.setSql('select ? as t_${tag}').add(v).first<Int64>()
                if (captured.size != 1) {
                    // execs=0 说明本次没执行（多半命中了结果缓存）；否则给出夹具看到的 SQL
                    let seen = if (execs.isEmpty()) {
                        'NONE'
                    } else {
                        execs[0]
                    }
                    bad += '${tag}(args=${captured.size},execs=${execs.size},sql=${seen}) '
                } else if (tag != 'string' && tag != 'nstring' && isStringArg(captured[0])) {
                    bad += '${tag}(fellback) '
                }
            }
            @Assert('', bad)
            // 3. 反向例：不在受支持清单里、但实现了 ToString 的值（取仓库现成的枚举）
            let unsupported: Any = TransactionStatus.Unknown
            var threw = false
            try {
                ex.arg(unsupported)
            } catch (e: SqlArgException) {
                threw = true
            }
            @Assert(true, threw)
            ex.clearSql()
            captureArgs(captured, execs)
            captured.clear()
            execs.clear()
            ex.setSql('select ? as t_unsupported').add(unsupported).first<Int64>()
            if (captured.size != 1) {
                bad += 'unsupported(args=${captured.size},execs=${execs.size}) '
            } else {
                match (captured[0]) {
                    case s: String => if (s != 'Unknown') {
                        bad += 'unsupported(val=${s}) '
                    }
                    case _ => bad += 'unsupported(not-string) '
                }
            }
            @Assert('', bad)
        } finally {
            ex.close()
        }
    }
}
