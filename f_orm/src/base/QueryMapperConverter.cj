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
import fountain::f_collection.*
import fountain::f_data.*

public abstract class QueryMapperConverter {
    private static let converters = ConcurrentHashMap<String, QueryMapperConverter>()

    public static func lookup(name: String): QueryMapperConverter {
        converters.computeIfAbsent(name){
            if(let Some(c) <- lookupOption<QueryMapperConverter>(name)){
                c
            }else{
                for(bean in lookupList<QueryMapperConverter>() where TypeInfo.of(bean) == TypeInfo.get(name)){
                    return bean
                }
                (ClassTypeInfo.get(name).construct([]) as QueryMapperConverter).getOrThrow{ORMException('QueryMapperJsonConverter: ${name} not found')}
            }
        }
    }
    public func convert<T>(data: Any): T where T <: DataFields<T>
}
public class QueryMapperJsonConverter <: QueryMapperConverter {
    public func convert<T>(data: Any): T where T <: DataFields<T> {
        let json = if(let x: String <- data){
            x
        }else if(let x: Array<Byte> <- data){
            String.fromUtf8(x)
        }else if (let x: InputStream <- data) {
            // bug-orm.md §3.2 ORM-C6：这里**只读不关**。`StringReader` 自身不持有 fd（std：内部 4096 字节缓冲），
            // 但它的 `close()` 会关**底层流**（io_package_classes.md:1990-2012）⇒ 补 close 等于误关驱动/调用方的流。
            // 流的所有权随结果集/调用方，见 InputStreamSqlArg 与 wrap/SqlArg.cj 的同类注释。
            StringReader(x).readToEnd()
        }else{
            throw ORMException("QueryMapperJsonConverter: ${TypeInfo.of(data)} does not support")
        }
        ((JsonValue.fromStr(json).toData() |> T.fromData) as T).getOrThrow()
    }
}
public class QueryMapperWithTypeNameJsonConverter <: QueryMapperConverter { 
    public func convert<T>(data: Any): T where T <: DataFields<T> {
        let json = if(let x: String <- data){
            x
        }else if(let x: Array<Byte> <- data){
            String.fromUtf8(x)
        }else if (let x: InputStream <- data) {
            // bug-orm.md §3.2 ORM-C6：同上——只读不关（`StringReader.close()` 会关底层流）
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