/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

public class MutableField <: ReadableField {
    public MutableField(name: String, typeInfo: TypeInfo, getter: (Any) -> Data,
        private let setter: (Any, Data, UInt64) -> Bool) {
        super(name, typeInfo, getter)
    }

    public func set(instance: Any, data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Bool {
        setter(instance, data, flag)
    }
    public static func new<O, F>(name: String, getter: (O) -> ?F, setter: (O, ?F) -> Unit): MutableField where O <: ObjectData<O>,
        F <: DataFields<F> {
        let fieldType = TypeInfos.get<F>()
        MutableField(name, fieldType, newGetter<O, F>(getter),
            {
                o, data, flag => if (data is DataNone) {
                    if ((flag & IGNORE_NONE) != 0) {
                        false
                    } else {
                        match (o) {
                            case x: O => setter(x, None<F>)
                            case _ => throw DataException(
                                "type of current instance does not match, expected ${TypeInfos.get<O>()}, but receives ${TypeInfo.of(o)}"
                            )
                        }
                        true
                    }
                } else if (let Some(v: F) <- convert<F>(data, flag: flag)) {
                    match (o) {
                        case x: O =>
                            setter(x, v)
                            true
                        case _ => throw DataException(
                            "type of current instance does not match, expected ${TypeInfos.get<O>()}, but receives ${TypeInfo.of(o)}"
                        )
                    }
                } else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) {
                    throw DataException("data ${data} cannot be converted to ${fieldType}")
                } else {
                    true
                }
            })
    }
    public static func new<O, F>(name: String, getter: (O) -> F, setter: (O, F) -> Unit): MutableField where O <: ObjectData<O>,
        F <: DataFields<F> {
        let fieldType = TypeInfos.get<F>()
        MutableField(name, fieldType, newGetter<O, F>(getter),
            {
                o, data, flag => if (data is DataNone) {
                    if ((flag & IGNORE_NONE) != 0) {
                        false
                    } else {
                        throw DataException('data none for field ${name} of ${TypeInfos.get<O>()}')
                    }
                } else if (let Some(v: F) <- convert<F>(data, flag: flag)) {
                    match (o) {
                        case x: O =>
                            setter(x, v)
                            true
                        case _ => throw DataException(
                            "type of current instance does not match, expected ${TypeInfos.get<O>()}, but receives ${TypeInfo.of(o)}"
                        )
                    }
                } else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) {
                    throw DataException("data ${data} cannot be converted to ${fieldType}")
                } else {
                    true
                }
            })
    }
}
