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
macro package fountain::f_rpc.macros

import std.ast.*
import std.collection.ArrayList

/**
 * 收集一个 RPC 方法的**参数与返回类型**（跨 RPC 边界的类型要在两侧都能解码）。
 * 同一个接口里重复出现的类型只登记一次。
 */
func collectRPCTypes(types: ArrayList<Tokens>, f: FuncDecl): Unit {
    for (p in f.funcParams) {
        addRPCType(types, p.paramType.toTokens())
    }
    // 无返回值的函数这里是空 tokens；addRPCType 会跳过
    addRPCType(types, f.declType.toTokens())
}

private func addRPCType(types: ArrayList<Tokens>, t: Tokens): Unit {
    if (t.size == 0) {
        return
    }
    let key = t.toString()
    for (x in types) {
        if (x.toString() == key) {
            return
        }
    }
    types.add(t)
}

/**
 * 生成类型登记调用（插在宏展开的包初始化块里）。
 *
 * 生成的是**无约束**的泛型调用 `registerRPCType<X>()`：宏是 token 级的、拿不到类型约束，
 * 若直接生成 `DefaultCodec.registerType<X>()`，则「参数/返回类型是 Int64/String/Unit/集合」的接口
 * 会编译失败（该约束是 `T <: Object & ObjectData<T> & DataFields<T>`）。
 * 「是不是需要登记的数据对象类型」由 `f_rpc.base.registerRPCType` 在运行时探测，见 bug.md 7.11。
 */
func rpcTypeRegistrations(types: ArrayList<Tokens>): Tokens {
    var calls = `empty_tokens`
    for (t in types) {
        calls += quote(
            registerRPCType<$(t)>()
        )
        calls += `nl`
    }
    calls
}
