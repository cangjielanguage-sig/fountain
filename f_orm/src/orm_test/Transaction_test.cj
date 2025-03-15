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

public class TransactionTest <: Transaction {
    private var state = 0

    /**
     * 数据库事务隔离级别。
     */
    public mut prop isoLevel: TransactionIsoLevel {
        get() {
            Unspecified
        }
        set(value) {
            println("transaction isoLevel = ${value}")
        }
    }

    /**
     * 数据库事务访问模式。
     */
    public mut prop accessMode: TransactionAccessMode {
        get() {
            ReadWrite
        }
        set(value) {
            println("transaction accessMode = ${value}")
        }
    }

    /**
     * 数据库事务延迟模式。
     */
    public mut prop deferrableMode: TransactionDeferrableMode {
        get() {
            NotDeferrable
        }
        set(value) {
            println("transaction deferrableMode = ${value}")
        }
    }

    /**
     * 开始数据库事务。
     * 异常SqlException - 提交事务时服务器端发生错误。
     * 异常SqlException - 事务已提交或回滚或连接已断开。
     */
    public func begin(): Unit {
        if (state != 0) {
            throw TransactionException("begun")
        }
        println("transaction begin")
        state = 1
    }

    /**
     * 提 交 数 据 库 事 务 。
     * 异 常 SqlException - 提 交 事 务 时 服 务 器 端 发 生 错 误 。
     * 异 常 SqlException - 事 务 已 提 交 或 回 滚 或 连 接 已 断 开 。
     */
    public func commit(): Unit {
        match (state) {
            case 0 => throw TransactionException("not begun")
            case 1 => state = 2
            case _ => throw TransactionException("finished")
        }
        println("transaction commit")
    }

    public func rollback(): Unit {
        match (state) {
            case 0 => throw TransactionException("not begun")
            case 1 => state = 2
            case _ => throw TransactionException("finished")
        }
        println("transaction rollback")
    }

    /**
     * 在 事 务 中 创 建 一 个 指 定 名 称 的 保 存 点 ， 可 用 于 回 滚 事 务 的 一 部 分 。
     * 异 常 SqlException - 提 交 事 务 时 服 务 器 端 发 生 错 误 。
     * 异 常 SqlException - 事 务 已 提 交 或 回 滚 或 连 接 已 断 开 。
     */
    public func save(savePointName: String): Unit {}

    /**
     * 回 滚 事 务 至 指 定 保 存 点 名 称 。
     * 异 常 SqlException - 提 交 事 务 时 服 务 器 端 发 生 错 误 。
     * 异 常 SqlException - 事 务 已 提 交 或 回 滚 或 连 接 已 断 开 。
     */
    public func rollback(savePointName: String): Unit {}

    /**
     * 销 毁 先 前 在 当 前 事 务 中 定 义 的 保 存 点 。 这 允 许 系 统 在 事 务 结 束 之 前 回 收 一 些 资 源 。
     * 异 常 SqlException - 提 交 事 务 时 服 务 器 端 发 生 错 误 。
     * 异 常 SqlException - 事 务 已 提 交 或 回 滚 或 连 接 已 断 开 。
     */
    public func release(savePointName: String): Unit {}
}
