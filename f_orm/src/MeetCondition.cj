/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
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
