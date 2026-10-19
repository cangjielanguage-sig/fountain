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
package fountain::f_jit

import std.collection.ArrayList
import fountain::f_jit.base.HostSignature
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SignatureRegistry

/**
 * 宿主侧注册门面（GAP-05 乙）。
 *
 * 设计前提（实测）：JIT 在运行期编译，产出不了新的泛型单态化实例；而调用宿主闭包必须
 * 知道 `(P1..Pn) -> R` 的具体类型。因此**签名必须在宿主编译期固定**，连同适配器一起登记，
 * JIT 只按 id 取用——这样每个签名一份适配器，不存在 11^(n+1) 的组合枚举。
 *
 * 泛型参数 `F` 是**类型令牌**：它让调用点写出 `(User, Order) -> Bool` 的完整类型，
 * 由编译器承担可读性与拼写检查；结构（`params` / `ret`）与适配器仍由调用方显式给出，
 * 因为仓颉没有类型级反射，无法从 `F` 反解出元数与各位置类型。
 *
 * 用法：
 *
 * ```cangjie
 * let id = JitHost.registerSignature<(ReflectUser) -> Int64>(
 *     display: '(ReflectUser) -> Int64',
 *     params: [LocalType.HOST_OBJECT],
 *     ret: LocalType.I64,
 *     adapter: { f, a =>
 *         if (let g: (ReflectUser) -> Int64 <- f) {
 *             let u = match (a[0]) {
 *                 case x: ReflectUser => x
 *                 case _ => throw Exception('实参不是 ReflectUser')
 *             }
 *             g(u)
 *         } else {
 *             throw Exception('宿主函数不匹配签名')
 *         }
 *     })
 * ```
 *
 * 后续可用宏 `@JitSignature<(User, Order) -> Bool>` 把 `display` / `params` / `ret` /
 * `adapter` 四件套自动生成，调用面收敛为一行；本类是宏的落地目标。
 */
public class JitHost {
    private init() {}

    /**
     * 登记宿主签名，返回稳定 id（结构相同则幂等返回既有 id）。
     *
     * @param display 人类可读签名文本（异常消息/诊断用）
     * @param params 每个形参位置的携带类别（`LocalType` 码，按位置序）
     * @param ret 返回值的携带类别
     * @param adapter `(宿主函数值, 已转换的实参数组) -> 原始仓颉返回值`
     */
    public static func registerSignature<F>(display!: String, params!: Array<UInt16>,
        paramNames!: Array<String>, ret!: UInt16, retName!: String,
        adapter!: (Any, Array<Any>) -> Any): Int32 {
        SignatureRegistry.register(HostSignature(params: params, paramNames: paramNames,
            ret: ret, retName: retName, display: display, adapter: adapter))
    }

    /** 按结构查签名 id；未登记 → `None`（JIT 编译期据此报「签名未注册」）。 */
    public static func findSignature(params: Array<UInt16>, paramNames: Array<String>,
        ret: UInt16, retName: String): ?Int32 {
        SignatureRegistry.find(params, paramNames, ret, retName)
    }

    /** 已登记签名数量（诊断用）。 */
    public static func signatureCount(): Int64 {
        SignatureRegistry.count()
    }
}
