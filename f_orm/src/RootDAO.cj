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

    func meet(condition: Bool, partial: String): MeetCondition {
        MeetCondition(condition, partial, executor)
    }
    prop choose: ChooseCondition{
        get(){
            ChooseCondition(executor)
        }
    }
    public func loop<I, T>(values: I): LoopCondition<I, T> where I <: Iterable<T> {
        Condition.loop<I, T>(values, executor)
    }
    public func `set`(partial: () -> String): String {
        Condition.`set`(partial)
    }
    public func `where`(partial: () -> String): String {
        Condition.`where`(partial)
    }
    public func `where`(delimiter: String, partial: () -> String): String {
        Condition.`where`(delimiter, partial)
    }
    public func trim(prefix!: String, suffix!: String, partial!: () -> String): String {
        Condition.trim(prefix: prefix, suffix: suffix, partial: partial)
    }
}