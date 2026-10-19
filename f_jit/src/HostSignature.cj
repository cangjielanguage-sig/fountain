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
import std.sync.Mutex
import fountain::f_jit.base.LocalType

/**
 * 宿主函数**签名**的结构描述 + 调用适配器（GAP-05 乙，用户裁定）。
 *
 * 为什么需要这一层：JIT 运行期编译，产出不了新的泛型单态化实例；而调用宿主闭包
 * 必须知道 `(P1..Pn) -> R` 的具体类型（`if (let g: (P1, P2) -> R <- f) { g(p1, p2) }`）。
 * 所以签名必须在**宿主编译期**固定下来，连同适配器一起登记；JIT 只按签名索引取用。
 *
 * - `params` / `ret`：每个位置的**携带类别**（`LocalType` 码）。调用点只需知道「值型直取 /
 *   句柄 get / 14 解引用」三种搬运方式，因此这里记码而不记类名。
 * - `adapter`：`(fn, args) -> result`，入参是**已转成仓颉值**的实参数组；它由宿主在注册处
 *   用具体类型写成，编译器保证 `f as (User, Order) -> Bool` 与 `a[i] as User` 的静态正确性。
 */
public class HostSignature {
    /** 每个形参位置的携带类别（`LocalType` 码，按位置序）。 */
    public let params: Array<UInt16>

    /**
     * 每个形参位置的**具体类名**（与 `params` 等长；非 14 位置为 `''`）。
     *
     * 只比类别码是不够的：`(User) -> R` 与 `(Order) -> R` 的码都是 `[14] -> R`，会让两个
     * 签名撞成同一个 id。类名是签名的**区分维度**，也是「预先注册 User 和 Order」的落点。
     */
    public let paramNames: Array<String>

    /** 返回值的携带类别（`LocalType` 码）。 */
    public let ret: UInt16

    /** 返回值的具体类名（`ret != 14` 时为 `''`）。 */
    public let retName: String

    /** 人类可读的签名文本（诊断/异常消息用，例如 `(User, Order) -> Bool`）。 */
    public let display: String

    /** 调用适配器：`(宿主函数值, 已转换的实参数组) -> 原始仓颉返回值`。 */
    public let adapter: (Any, Array<Any>) -> Any

    public init(params!: Array<UInt16>, paramNames!: Array<String>, ret!: UInt16,
        retName!: String, display!: String, adapter!: (Any, Array<Any>) -> Any) {
        this.params = params.clone()
        this.paramNames = paramNames.clone()
        this.ret = ret
        this.retName = retName
        this.display = display
        this.adapter = adapter
    }

    /** 元数 = 形参个数。 */
    public func arity(): Int64 {
        this.params.size
    }

    /** 结构相等：元数、逐位类别码、逐位类名、返回类别与返回类名全部一致。 */
    public func sameShape(params: Array<UInt16>, paramNames: Array<String>, ret: UInt16,
        retName: String): Bool {
        if (this.params.size != params.size || this.paramNames.size != paramNames.size) {
            return false
        }
        if (this.ret != ret || this.retName != retName) {
            return false
        }
        var i = 0
        while (i < params.size) {
            if (this.params[i] != params[i] || this.paramNames[i] != paramNames[i]) {
                return false
            }
            i = i + 1
        }
        true
    }
}

/**
 * 宿主签名注册表（进程级、线程安全）。
 *
 * 语义：
 * - `register` 返回**稳定 id**（从 0 递增），同一结构重复注册返回既有 id（幂等）；
 * - `find` 按结构查 id：JIT 编译期用 lambda 的声明签名查表，未命中即**编译错误**
 *   （与「未注册类名编译期报错」同一语义）；
 * - `get` 按 id 取条目：运行期 H63 只做一次数组索引，无类型分派。
 *
 * 并发：注册发生在宿主初始化/编译前，取用发生在执行期；`ArrayList` 的读在锁内拷贝引用，
 * 条目本身不可变，故读出后无需持锁。
 */
public class SignatureRegistry {
    private static let mtx = Mutex()
    private static let entries = ArrayList<HostSignature>()

    private init() {}

    /**
     * 登记一个宿主签名；结构相同则返回既有 id（幂等）。
     *
     * 调用方（`JitHost.registerSignature` 或宏生成物）负责给出正确的 `params`/`ret` 与
     * 类型正确的 `adapter`；两者不一致会在适配器执行时以 `ClassCastException` 暴露。
     */
    public static func register(sig: HostSignature): Int32 {
        synchronized(mtx) {
            var i = 0
            while (i < entries.size) {
                let e = entries[i]
                if (e.sameShape(sig.params, sig.paramNames, sig.ret, sig.retName)) {
                    return Int32(i)
                }
                i = i + 1
            }
            entries.add(sig)
            Int32(entries.size - 1)
        }
    }

    /** 按结构查 id；未登记 → `None`（JIT 编译期据此报「签名未注册」）。 */
    public static func find(params: Array<UInt16>, paramNames: Array<String>,
        ret: UInt16, retName: String): ?Int32 {
        synchronized(mtx) {
            var i = 0
            while (i < entries.size) {
                if (entries[i].sameShape(params, paramNames, ret, retName)) {
                    return Some(Int32(i))
                }
                i = i + 1
            }
            None
        }
    }

    /** 按 id 取条目；越界 → `None`（运行期视为单元/宿主不匹配）。 */
    public static func get(id: Int32): ?HostSignature {
        synchronized(mtx) {
            if (id < 0 || Int64(id) >= entries.size) {
                return None
            }
            Some(entries[Int64(id)])
        }
    }

    /** 已登记数量（诊断/测试用）。 */
    public static func count(): Int64 {
        synchronized(mtx) {
            entries.size
        }
    }

    /** 测试专用：清空注册表。 */
    public static func resetForTest(): Unit {
        synchronized(mtx) {
            entries.clear()
        }
    }
}
