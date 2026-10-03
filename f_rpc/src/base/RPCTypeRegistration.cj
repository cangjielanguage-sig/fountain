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
package fountain::f_rpc.base

import std.reflect.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.*

/**
 * 由 `@RPCStub` / `@RPCSkeleton` 宏在展开处自动调用：把跨 RPC 边界的类型登记进
 * `DefaultCodec` 的「类型hash → 创建者」表，免去应用手写 `DefaultCodec.registerType<T>()`。
 *
 * **为什么是运行时探测，而不是在宏里直接生成 `registerType<T>()`**：
 * 后者要求 `T <: Object & ObjectData<T> & DataFields<T>`，而宏是 token 级的、无法判断类型是否满足约束；
 * 对「参数/返回类型是 Int64、String、Unit、集合」的接口生成直调会直接编译失败。
 * （也试过用「同签名、仅泛型约束不同」的重载兜底，编译器明确报
 * `generic constraints are not involved in the overloading`，此路不通。）
 *
 * 探测依据：`@DataAssist[fields]` 生成的类必有静态方法 `dataFields()`（`ObjectFields`，内含实例创建器），
 * 这正是解码 OBJECT 分支需要的创建者来源。非对象类型（基本类型、集合、接口、泛型实参）会被跳过 ——
 * 它们走各自的 dataType 分支，本来就不需要登记。
 */
public func registerRPCType<T>(): Unit {
    try {
        let typeInfo = TypeInfo.of<T>()
        if (let classInfo: ClassTypeInfo <- typeInfo
            && let dataFields <- classInfo.getStaticFunction('dataFields', [])
            && let fields: ObjectFields <- dataFields.apply(classInfo, [])) {
            // 用一次性实例换到 SimpleDataObject，再取它的 dataCreator()：即「每次都造一个新对象」的创建者，
            // 与 DefaultCodec.registerType<T>() 内部登记的形式一致
            let sample = fields.create()
            if (let data: ToData <- sample && let simple: SimpleDataObject <- data.toData()) {
                DefaultCodec.registerType(classInfo.qualifiedName, simple.dataCreator())
            }
        }
    } catch (_: Exception) {
        // 反射不可用/非对象类型：不登记，不需要影响调用方
    }
}
