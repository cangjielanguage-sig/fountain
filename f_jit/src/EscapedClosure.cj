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

import fountain::f_jit.runtime.PromotionGroup

/**
 * 单元发出的一个逃逸闭包（m2 §14.2/§14.3）。
 *
 * 与包装实例解耦：条目在**提升组产生处**登记（`callLocked` 解包 `retType=12`），
 * 因此未经 `callForFn` 承接的组也被单元卸载兜底；条目只引用组与计数，不让单元
 * 强引用包装对象。
 *
 * `state` / `active` 均由**所属单元的 `mtx`** 保护（不在条目上加锁）。
 */
class EscapedClosure {
    /** 单元内序号（登记表的键）。 */
    let seq: Int64
    /** 提升组：闭包自身槽 + 各句柄型捕获（m2 §14.1）。 */
    let group: PromotionGroup
    /** 0 Ready / 1 Unloading / 2 Released。 */
    var state: Int64 = 0
    /** 该闭包的在飞调用数（只算本闭包，不含单元的其它调用）。 */
    var active: Int64 = 0

    init(seq: Int64, group: PromotionGroup) {
        this.seq = seq
        this.group = group
    }
}
