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

public import std.time.DateTime
public import std.io.InputStream

public interface QueryMappersInit<T> where T <: QueryMappersInit<T> {
    static func isSimpleData(): Bool {
        true
    }
    static func queryMappers(): QueryMappers<T> {
        throw ORMException("not supported")
    }
}

extend<T> Option<T> <: QueryMappersInit<T> where T <: QueryMappersInit<T> {
    public static func isSimpleData(): Bool {
        T.isSimpleData()
    }
    public static func queryMappers(): QueryMappers<T> {
        T.queryMappers()
    }
}

extend Int8 <: QueryMappersInit<Int8> {}

extend UInt8 <: QueryMappersInit<UInt8> {}

extend Int16 <: QueryMappersInit<Int16> {}

extend UInt16 <: QueryMappersInit<UInt16> {}

extend Int32 <: QueryMappersInit<Int32> {}

extend UInt32 <: QueryMappersInit<UInt32> {}

extend Int64 <: QueryMappersInit<Int64> {}

extend UInt64 <: QueryMappersInit<UInt64> {}

extend Float16 <: QueryMappersInit<Float16> {}

extend Float32 <: QueryMappersInit<Float32> {}

extend Float64 <: QueryMappersInit<Float64> {}

extend Rune <: QueryMappersInit<Rune> {}

extend String <: QueryMappersInit<String> {}

extend Bool <: QueryMappersInit<Bool> {}

extend Duration <: QueryMappersInit<Duration> {}

extend DateTime <: QueryMappersInit<DateTime> {}

extend<T> Array<T> <: QueryMappersInit<Array<T>> where T <: QueryMappersInit<T> {}
