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

import f_base.*

abstract sealed class ReadableField {
    private let annotations = ConcurrentHashMap<TypeInfo, Annotation>()
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
    public prop validator: Validator {
        get(){
            let validatorType = TypeInfo.of<Validator>()
            (annotations.computeIfAbsent(validatorType){
                func getValidator(name: String){
                    try{
                        cti.getInstanceProperty(name).findAnnotation<Validator>() ?? DummyValidator.instance
                    } catch (_){
                        cti.getInstanceVariable(name).findAnnotation<Validator>() ?? DummyValidator.instance
                    }
                }
                let cti = (typeInfo as ClassTypeInfo).getOrThrow()
                try{
                    getValidator(name)
                }catch(_){
                    getValidator('`${name}`')
                }
            } as Validator) ?? DummyValidator.instance
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
