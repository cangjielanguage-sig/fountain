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

public interface TransactionHook {
    func beforeTx(): Unit {}
    func beforeCommit(readOnly: Bool): Unit {}
    func afterCommit(): Unit {}
    func afterThrowing(e: Exception): Unit {}
    func beforeRollback(e: Exception): Unit {}
    func afterRollback(e: Exception): Unit {}
    func afterComplete(status: TransactionStatus): Unit {}
    /**
     * 用于决定钩子的执行顺序
     */
    prop order: Int64 {
        get() {
            Int64.Max
        }
    }
}
