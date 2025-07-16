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

import std.collection.ArrayList
import f_orm.exception.ORMException

public class ChooseCondition {
    private static let emptyPartial: () -> (String, Any) = {=> ('', '')}
    private let conditions = ArrayList<(() -> Bool, () -> (String, Any))>()
    private var _otherwise: () -> (String, Any) = emptyPartial
    private var pair = true
    private var _argInSql: Bool = false
    public ChooseCondition(private let executor: SqlExecutor) {}
    public prop argInSql: ChooseCondition {
        get() {
            _argInSql = true
            this
        }
    }
    public func condition(condition: () -> Bool): ChooseCondition {
        if (pair) {
            pair = false
            conditions.add((condition, emptyPartial))
            this
        } else {
            throw ORMException('condition and sql partial generation function arg not paring')
        }
    }
    public func partial(partial: () -> (String, Any)): ChooseCondition {
        if (pair) {
            throw ORMException('condition and sql partial generation function arg not paring')
        } else {
            pair = true
            let idx = conditions.size - 1
            let (c, _) = conditions[idx]
            conditions[idx] = (c, partial)
            this
        }
    }
    private func callee(partial: () -> Any): () -> (String, Any) {
        {=> ('', partial())}
    }
    public func partial(partial: () -> Any): ChooseCondition {
        this.partial(callee(partial))
    }
    public func otherwise(partial: () -> (String, Any)): ChooseCondition {
        _otherwise = partial
        this
    }
    public func otherwise(partial: () -> Any): ChooseCondition {
        otherwise(callee(partial))
    }
    public func done(): String {
        if (!pair) {
            throw ORMException('condition and sql partial generation function arg not paring')
        }
        func gen(partial: () -> (String, Any)) {
            let (frag, arg) = partial()
            if (frag.size > 0) {
                if (_argInSql) {
                    match (arg) {
                        case x: ToString => ' ${frag} ${x} ${Condition.delimiter} '
                        case x =>
                            executor.add(arg)
                            ' ${frag} ? ${Condition.delimiter} '
                    }
                } else {
                    executor.add(arg)
                    ' ${frag} ? ${Condition.delimiter} '
                }
            } else if (_argInSql) {
                match (arg) {
                    case x: ToString => ' ${x} ${Condition.delimiter} '
                    case x =>
                        executor.add(arg)
                        ' ? ${Condition.delimiter} '
                }
            } else {
                executor.add(arg)
                ' ? ${Condition.delimiter} '
            }
        }
        for ((cond, partial) in conditions where cond()) {
            return gen(partial)
        }
        gen(_otherwise)
    }
}
