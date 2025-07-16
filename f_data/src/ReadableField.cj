/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

import f_base.*

abstract sealed class ReadableField {
    public let name: String
    public ReadableField(
        name: String,
        public let typeInfo: TypeInfo,
        private let getter: (Any) -> Data
    ) {
        this.name = if (name[0] == b'`') {
            name[1..name.size - 1]
        } else {
            name
        }
    }
    public func get(instance: Any): Data {
        getter(instance)
    }
    protected static func newGetter<O, F>(fn: (O) -> F): (Any) -> Data where O <: ObjectData<O>, F <: DataFields<F> {
        {
            o => match (o) {
                case x: O => fn(x).toData()
                case _ =>
                    let x: Any = o
                    throw DataException(
                        "type of current instance does not match, expected ${TypeInfos.get<O>()}, but receives ${TypeInfo.of(x)}")
            }
        }
    }
    protected static func newGetter<O, F>(fn: (O) -> ?F): (Any) -> Data where O <: ObjectData<O>, F <: DataFields<F> {
        {
            o => match (o) {
                case x: O => fn(x).toData()
                case _ =>
                    let x: Any = o
                    throw DataException(
                        "type of current instance does not match, expected ${TypeInfos.get<O>()}, but receives ${TypeInfo.of(x)}")
            }
        }
    }
}
