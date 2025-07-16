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

import std.math.numeric.{BigInt, Decimal}
import std.time.DateTime
import f_orm.exception.ORMException

/**
 * 所有的DAO接口都要继承本接口
 */
public interface RootDAO {
    /**
     * 本接口函数不必实现，所有DAO都是SqlExecutor的扩展，SqlExecutor已经提供了相同声明的属性，
     * 且SqlExecutor已经实现本接口，故任意DAO接口可以直接调用本属性
     */
    prop executor: SqlExecutor

    func arg(value: Bool): String {
        executor.add(value)
        '?'
    }
    func arg(value: Int8): String {
        executor.add(value)
        '?'
    }
    func arg(value: UInt8): String {
        executor.add(value)
        '?'
    }
    func arg(value: Int16): String {
        executor.add(value)
        '?'
    }
    func arg(value: UInt16): String {
        executor.add(value)
        '?'
    }
    func arg(value: Int32): String {
        executor.add(value)
        '?'
    }
    func arg(value: UInt32): String {
        executor.add(value)
        '?'
    }
    func arg(value: Int64): String {
        executor.add(value)
        '?'
    }
    func arg(value: UInt64): String {
        executor.add(value)
        '?'
    }
    func arg(value: Float16): String {
        executor.add(value)
        '?'
    }
    func arg(value: Float32): String {
        executor.add(value)
        '?'
    }
    func arg(value: Float64): String {
        executor.add(value)
        '?'
    }
    func arg(value: BigInt): String {
        executor.add(value)
        '?'
    }
    func arg(value: Decimal): String {
        executor.add(value)
        '?'
    }
    func arg(value: Rune): String {
        executor.add(value)
        '?'
    }
    func arg(value: String): String {
        executor.add(value)
        '?'
    }
    func arg(value: InputStream): String {
        executor.add(value)
        '?'
    }
    func arg(value: Duration): String {
        executor.add(value)
        '?'
    }
    func arg(value: DateTime): String {
        executor.add(value)
        '?'
    }
    func arg(value: Array<Byte>): String {
        executor.add(value)
        '?'
    }
    func meet(condition: Bool, partial: String): MeetCondition {
        MeetCondition(condition, partial, executor)
    }
    prop choose: ChooseCondition {
        get() {
            ChooseCondition(executor)
        }
    }
    func loop<I, T>(values: I): LoopCondition<I, T> where I <: Iterable<T> {
        Condition.loop<I, T>(values, executor)
    }
    func `set`(partial: () -> String): String {
        Condition.`set`(partial)
    }
    func `where`(partial: () -> String): String {
        Condition.`where`(partial)
    }
    func `where`(delimiter: String, partial: () -> String): String {
        Condition.`where`(delimiter, partial)
    }
    func trim(prefix!: String, suffix!: String, partial!: () -> String): String {
        Condition.trim(prefix: prefix, suffix: suffix, partial: partial)
    }
}
