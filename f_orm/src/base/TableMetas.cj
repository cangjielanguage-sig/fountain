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
import std.reflect.*

public struct TableMetas{
    private static var schemas = ConcurrentHashMap<TypeInfo, TableMeta>()

    public static func register<T>(): Unit where T <: QueryMappersInit<T> {
        schemas[TypeInfo.of<T>()] = TableMeta.new<T>()
    }
    public static func tableMetas(): Iterator<TableMeta> {
        schemas.iterator().map{tuple => tuple[1]}
    }
    public static func clear(){
        schemas = unsafeZeroValue<ConcurrentHashMap<TypeInfo, TableMeta>>()
    }
}