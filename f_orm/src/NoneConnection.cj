/*
   Copyright (c) 2022 WuJingrun（吴京润）
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

import std.collection.*
import f_exception.IllegalAccessException

class NoneConnection <: Connection {
    public static const instance = NoneConnection()
    private const init() {}

    public prop state: ConnectionState {
        get() {
            Closed
        }
    }
    public func getMetaData(): Map<String, String> {
        throw IllegalAccessException()
    }
    public func prepareStatement(sql: String): Statement {
        throw IllegalAccessException()
    }
    public func createTransaction(): Transaction {
        throw IllegalAccessException()
    }
    public func isClosed(): Bool {
        true
    }
    public func close(): Unit {}
}
