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
package fountain::f_jit.runtime

/**
 * `Any` 盒的**载荷对象**（句柄 tag = `TypeToken.ANY` = 12，m3 §1）。
 *
 * **为什么需要一个包装类而不是直接把原生 `Any` 存进条目**：容器（`List<Any>` / `Map<…,Any>`）
 * 的写入走 `HandleTable.cellToAny`，读出再走 `anyToCell`。若条目里直接存原生值，`Int64 1` 这样的
 * 值型会退化成裸 cell，读出时无法与「盒句柄」区分——`l[1]` 的静态类型是 15，运行期却会拿到一个
 * 裸整数，`as` 就必然把它当句柄用。有了包装对象，盒在容器里**保持身份**：写入存包装对象、读出
 * 重新 pin 回 tag 12 的句柄，`fetchAnyBox` 再取出内部值。
 *
 * 盒**不可变**：`value` 只在构造时写入一次；对盒没有「改内容」的操作（m3 §1/§12-5）。
 */
internal class JitAnyBox {
    /** 盒内载荷（值型已拷贝、引用型即共享引用）。 */
    public let value: Any

    public init(value: Any) {
        this.value = value
    }
}
