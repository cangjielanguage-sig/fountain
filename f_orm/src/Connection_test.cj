/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

import std.collection.Map
import f_base.EmptyMap

public class ConnectionTest <: Connection {
    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {
    }
    /**
     * 描 述 与 数 据 源 连 接 的 当 前 状 态
     */
    public prop state: ConnectionState {
        get() {
            Connected
        }
    }

    /**
     * 返 回 连 接 到 的 数 据 源 元 数 据
     */
    public func getMetaData(): Map<String, String> {
        EmptyMap<String, String>.INSTANCE
    }

    /**
     * 通 过 传 入 的 sql 语 句 ， 返 回 一 个 预 执 行 的 Statement 对 象 实 例
     * 参 数 sql - 预 执 行 的 sql 语 句 ，sql 语 句 的 参 数 只 支 持 ? 符 号 占 位 符
     * 返 回 值 Statement - 一 个 可 以 执 行 sql 语 句 的 实 例 对 象
     * 异 常 SqlException - 语 法 错 误 ， sql 语 句 包 含 不 认 识 的 字 符
     */
    public func prepareStatement(sql: String): Statement {
        StatementTest(sql)
    }

    /**
     * 创 建 事 务 对 象
     * 异 常 SqlException - 已 经 处 于 事 务 状 态 ， 不 支 持 并 行 事 务 。
     */
    public func createTransaction(): Transaction {
        TransactionTest()
    }
}
