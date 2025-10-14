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
package f_data

public class MutableField <: ReadableField {
    public MutableField(name: String, classTypeInfo: ClassTypeInfo, fieldTypeInfo: TypeInfo, getter: (Any) -> Data,
        private let setter: (Any, Data, UInt64) -> Bool) {
        super(name, classTypeInfo, fieldTypeInfo, getter)
    }

    public func set(instance: Any, data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Bool {
        setter(instance, data, flag)
    }
    public static func new<O, F>(name: String, getter: (O) -> ?F, setter: (O, ?F) -> Unit): MutableField where O <: ObjectData<O>,
        F <: DataFields<F> {
        let fieldType = TypeInfos.get<F>()
        MutableField(name, ClassTypeInfo.of<O>(), fieldType, newGetter<O, F>(getter),
            {
                o, data, flag => if (data is DataNone) {
                    if ((flag & IGNORE_NONE) != 0) {
                        false
                    } else {
                        match (o) {
                            case x: O => setter(x, None<F>)
                            case _ =>
                                let x: Any = o
                                throw DataException(
                                    "type of current instance does not match, expected ${TypeInfos.get<O>()}, but receives ${TypeInfo.of(x)}")
                        }
                        true
                    }
                } else if (let Some(v: F) <- convert<F>(data, flag: flag)) {
                    match (o) {
                        case x: O =>
                            setter(x, v)
                            true
                        case _ =>
                            let x: Any = o
                            throw DataException(
                                "type of current instance does not match, expected ${TypeInfos.get<O>()}, but receives ${TypeInfo.of(x)}")
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
                        case _ =>
                            let x: Any = o
                            throw DataException(
                                "type of current instance does not match, expected ${TypeInfos.get<O>()}, but receives ${TypeInfo.of(x)}")
                    }
                } else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) {
                    throw DataException("data ${data} cannot be converted to ${fieldType}")
                } else {
                    true
                }
            })
    }
}
