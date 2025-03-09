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

public class DatasourceTest <: Datasource {
    /**
     * 设 置 连 接 选 项
     */
    public func setOption(key: String, value: String): Unit {
    }
    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {}

    /**
     * 返 回 一 个 可 用 的 连 接
     * 返 回 值 Connection - 数 据 库 连 接 实 例
       (续下页)
       567
       版权所有，禁止扩散
       (接上页)
     */
    public func connect(): Connection {
        ConnectionTest()
    }
}
