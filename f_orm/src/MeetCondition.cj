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

public class MeetCondition {
    //condition: Bool, sqlFrag: String, argInSql!: Bool, value!: () -> ToString
    private var _argInSql = false
    private var _value: () -> Any = {=> ''}
    public MeetCondition(private let condition: Bool, private let partial: String, private let executor: SqlExecutor) {}

    public prop argInSql: MeetCondition {
        get() {
            _argInSql = true
            this
        }
    }
    public func value(value: () -> Any): MeetCondition {
        this._value = value
        this
    }
    public func value(value: Any): MeetCondition {
        this._value = {=> value}
        this
    }
    public func done(): String {
        if (condition) {
            if (_argInSql) {
                match (_value()) {
                    case x: ToString => ' ${partial} ${x} ${Condition.delimiter} '
                    case x =>
                        executor.add(_value())
                        ' ${partial} ? ${Condition.delimiter} '
                }
            } else {
                executor.add(_value())
                ' ${partial} ? ${Condition.delimiter} '
            }
        } else {
            ''
        }
    }
}
