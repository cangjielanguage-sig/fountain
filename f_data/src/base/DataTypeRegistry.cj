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
package fountain::f_data.base

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.reflect.ClassTypeInfo

/**
 * 对象类型创建者注册表：`@DataAssist[fields]` 生成的类在**包初始化时**登记自己的「限定名 → 创建者」。
 *
 * **为什么需要**：f_codec 的「类型hash → 创建者」表原先只在该进程**编码过**该类型时才登记，
 * 于是只解码不编码的一侧（客户端第一次收响应、服务端第一次收请求）会失败；而**嵌套**的对象字段
 * 更麻烦 —— 它不是任何 RPC 方法的顶层参数/返回类型，连 RPC 宏的自动登记也够不着（.autocode/bugs/bug-archived-on-20261004.md 7.11）。
 *
 * **为什么放在 f_data**：`@DataAssist` 在 f_data 里，而「hash→创建者」表与 murmur 在 f_codec；
 * f_data → f_codec 会构成依赖环。所以这里只登记到 f_data 自己的表（纯内存操作，不做 I/O、不读配置），
 * 由 f_codec 在解码未命中时按名字补算 murmur 并拉取。
 *
 * 泛型 `@DataAssist` 类不在覆盖范围：文件级拿不到类型实参（`Foo` 不是类型，`Foo<Int64>` 才是），
 * 这类类型仍需在解码侧手工调用 `DefaultCodec.registerType<Foo<…>>()`。
 */
public class DataTypeRegistry {
    private static let creators = ConcurrentHashMap<String, () -> SimpleDataObject>()

    /**
     * 已登记类型的个数。只增不减，可当作「注册表版本」：f_codec 用它判断是否需要重新拉取，
     * 避免每次解码未命中都遍历一遍全表。
     */
    public static prop size: Int64 {
        get() {
            creators.size
        }
    }

    /**
     * 由 `@DataAssist[fields]` 展开出的代码在包初始化时调用。
     * 约束与 `DefaultCodec.registerType<T>()` 一致（能生成 `dataFields()` 的对象类型天然满足）。
     */
    public static func registerDataType<T>(): Unit where T <: Object & ObjectData<T> & DataFields<T> {
        let qualifiedName = ClassTypeInfo.of<T>().qualifiedName
        register(qualifiedName) {
            => if (let o: T <- T.dataFields().create() && let x: SimpleDataObject <- o.toData()) {
                x
            } else {
                throw DataException('cannot create data object for registered type ${qualifiedName}')
            }
        }
    }

    /** 登记一个类型的创建者；同名只登记一次（幂等）。 */
    private static func register(qualifiedName: String, creator: () -> SimpleDataObject): Unit {
        creators.addIfAbsent(qualifiedName, creator)
    }

    /** 当前所有登记项的快照（限定名 + 创建者），供 f_codec 补算 murmur 后登记进自己的表。 */
    public static func snapshot(): Array<(String, () -> SimpleDataObject)> {
        let list = ArrayList<(String, () -> SimpleDataObject)>()
        for ((name, creator) in creators) {
            list.add((name, creator))
        }
        list.toArray()
    }
}
