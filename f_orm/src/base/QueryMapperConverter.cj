/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_orm.base

import std.collection.concurrent.ConcurrentHashMap
import std.io.*
import std.reflect.*
import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_collection.*
import fountain::f_data.*

public abstract class QueryMapperConverter {
    private static let converters = ConcurrentHashMap<String, QueryMapperConverter>()

    public static func lookup(name: String): QueryMapperConverter {
        converters.computeIfAbsent(name){
            if(let Some(c) <- lookupOption<QueryMapperConverter>(name)){
                c
            }else{
                (ClassTypeInfo.get(name).construct([]) as QueryMapperConverter).getOrThrow{ORMException('QueryMapperJsonConverter: ${name} not found')}
            }
        }
    }
    public func convert<T>(data: Any): T where T <: DataFields<T>
}
@Bean
public class QueryMapperJsonConverter <: QueryMapperConverter {
    public func convert<T>(data: Any): T where T <: DataFields<T> {
        let json = if(let x: String <- data){
            x
        }else if(let x: Array<Byte> <- data){
            String.fromUtf8(x)
        }else if (let x: InputStream <- data) {
            StringReader(x).readToEnd()
        }else{
            throw ORMException("QueryMapperJsonConverter: ${TypeInfo.of(data)} does not support")
        }
        ((JsonValue.fromStr(json).toData() |> T.fromData) as T).getOrThrow()
    }
}
@Bean
public class QueryMapperWithTypeNameJsonConverter <: QueryMapperConverter { 
    public func convert<T>(data: Any): T where T <: DataFields<T> {
        let json = if(let x: String <- data){
            x
        }else if(let x: Array<Byte> <- data){
            String.fromUtf8(x)
        }else if (let x: InputStream <- data) {
            StringReader(x).readToEnd()
        }else{
            throw ORMException("QueryMapperJsonConverter: ${TypeInfo.of(data)} does not support")
        }
        let jsonObj = JsonValue.fromStr(json).asObject()
        let typeName = jsonObj.get("typeName")?.asString().value ?? ""
        let value = jsonObj.get("value")
        if(typeName != '' && value.isSome()){
            let typeInfo = TypeInfo.get(typeName)
            let any = typeInfo.getStaticFunction("fromData").apply(typeInfo, [value.toData()])
            (any as T).getOrThrow()
        }else{
            ((jsonObj.toData() |> T.fromData) as T).getOrThrow()
        }
    }
    public static func toJson<T>(data: T): String where T <: DataFields<T> {
        let json = match(JsonValue.fromData(data.toData())){
            case x: JsonValue => x
            case x: ?JsonValue => x.getOrThrow{UnreachableException()}
            case _ => throw UnreachableException()
        }
        let obj = JsonObject()
        obj.add("typeName", TypeInfo.of(data).qualifiedName)
        obj.add("value", json)
        obj.toString()
    }
}