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
    private let annotations = ConcurrentHashMap<TypeInfo, ?Annotation>()
    public let name: String
    public ReadableField(
        name: String,
        public let classTypeInfo: ClassTypeInfo,
        public let fieldTypeInfo: TypeInfo,
        private let getter: (Any) -> Data
    ) {
        this.name = if (name[0] == b'`') {
            name[1..name.size - 1]
        } else {
            name
        }
    }
    public func tryFindAnnotation<A>(): ?A where A <: Annotation {
        let annotationType = TypeInfo.of<A>()
        let annotation = annotations.computeIfAbsent(annotationType){
            func getAnnotation(name: String): ?Annotation {
                let a = try{
                    classTypeInfo.getInstanceProperty(name).findAnnotation<A>()
                } catch (_){
                    classTypeInfo.getInstanceVariable(name).findAnnotation<A>()
                }
                if(let Some(x: Annotation) <- a){
                    x
                }else{
                    None<Annotation>
                }
            }
            try{
                try{
                    if(let Some(x) <- getAnnotation(name)){
                        x
                    }else{
                        getAnnotation('`${name}`')
                    }
                }catch(_){
                    getAnnotation('`${name}`')
                }
            }catch(_){
                None<Annotation>
            }
        }
        match(annotation){
            case Some(a: A) => a
            case _ => None<A>
        }
    }
    public prop validator: Validator {
        get(){
            tryFindAnnotation<Validator>() ?? DummyValidator.instance
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
