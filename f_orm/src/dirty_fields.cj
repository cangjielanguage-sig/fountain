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

import std.collection.HashSet
import std.collection.concurrent.ConcurrentHashMap
import std.reflect.TypeInfo
import f_orm.exception.DirtyFieldException

private let dirtyFields = ConcurrentHashMap<TypeInfo, ThreadLocal<HashSet<String>>>()

private func f_orm_register<T>(): Unit where T <: QueryMappersInit<T> & ObjectData<T> {
    let typeInfo = TypeInfo.of<T>()
    dirtyFields[typeInfo] = ThreadLocal<HashSet<String>>()
}

public func f_orm_setDirtyField<T>(field: String): Unit where T <: QueryMappersInit<T> & ObjectData<T> {
    if(let Some(local) <- dirtyFields.get(TypeInfo.of<T>())){
        if(let Some(set) <- local.get()){
            set
        }else{
            let set = HashSet<String>()
            local.set(set)
            set
        }.add(field)
    } else {
        f_orm_register<T>()
        f_orm_setDirtyField<T>(field)
    }
}
func f_orm_getDirtyFields<T>(): HashSet<String> where T <: QueryMappersInit<T> & ObjectData<T> {
    if(let Some(local) <- dirtyFields.get(TypeInfo.of<T>()) && let Some(set) <- local.get()){
        set
    }else{
        HashSet<String>()
    }
}
func f_orm_clear<T>(): Unit where T <: QueryMappersInit<T> & ObjectData<T> {
    dirtyFields.get(TypeInfo.of<T>())?.set(None)
}
func f_orm_clearAll(): Unit {
    for((_, local) in dirtyFields){
        local.set(None)
    }
}