/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm.orm_test

import std.collection.ArrayList

public class StatementTest <: Statement {
    public StatementTest(private let sql: String) {
        println("statement ${sql}")
    }
    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {
    }
    /**
     * 预 执 行 sql 语 句 中 ， 占 位 的 参 数 个 数
     */
    public prop parameterColumnInfos: Array<ColumnInfo> {
        get() {
            var count = 0
            var idx = 0
            let list = ArrayList<ColumnInfo>()
            while (true) {
                match (sql.indexOf("?", idx)) {
                    case Some(i) => ColumnInfoTest("", "SqlVarchar")
                    case _ => break
                }
            }
            return list.toArray()
        }
    }

    /**
     * 设 置 预 执 行 sql 语 句 选 项
     *
     */
    public func setOption(key: String, value: String): Unit {}

    /**
     * 执 行 sql 语 句 ， 得 到 更 新 结 果
     * 返 回 值 UpdateResult - 更 新 结 果 。
     * 异 常 SqlException -执 行 过 程 中 发 生 了 异 常 ， 比 如 网 络 中 断 ， 服 务 器 超 时 ， 参 数 个 数 不 正 确
     */
    public func update(params: Array<SqlDbType>): UpdateResult {
        if (params.size != parameterColumnInfos.size) {
            throw ORMException("params size ： ${params.size}，parameterCount：${parameterColumnInfos.size}")
        }
        UpdateResultTest()
    }

    /**
     * 执 行 sql 语 句 ， 得 到 查 询 结 果
     * 返 回 值 QueryResult - 查 询 结 果 。
     * 异 常 SqlException -执 行 过 程 中 发 生 了 异 常 ， 比 如 网 络 中 断 ， 服 务 器 超 时 ， 参 数 个 数 不 正 确
     */
    public func query(params: Array<SqlDbType>): QueryResult {
        QueryResultTest()
    }
}
public class UpdateResultTest <: UpdateResult {
    public prop rowCount: Int64 {
        get() {
            1
        }
    }
    public prop lastInsertId: Int64 {
        get() {
            1
        }
    }
}
