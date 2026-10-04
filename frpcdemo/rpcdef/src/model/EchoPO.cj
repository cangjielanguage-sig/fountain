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
package fountain::rpcdef.model

import fountain::f_data.macros.*
import fountain::f_data.*

/**
 * 嵌套对象字段的用例：它在**线上**以 OBJECT 出现，但不是任何 RPC 方法的顶层参数/返回类型 ——
 * RPC 宏的自动登记够不着它，只能靠 `@DataAssist` 在包初始化时自登记（见 .autocode/bugs/bug-archived-on-20261004.md 7.11）。
 * 客户端打印的 JSON 里出现 `inner` 就说明解码侧认出了这个嵌套类型。
 */
@DataAssist[props fields]
public open class InnerPO {
    private var tag: String = 'inner-default'
    private var count: Int64 = 7
}

// 跨网络传输的对象类型不再需要手工 `DefaultCodec.registerType<EchoPO>()`：
// @RPCStub / @RPCSkeleton 展开时会登记顶层参数与返回类型，@DataAssist 自己也会在包初始化时登记（含嵌套类型）。
@DataAssist[props fields]
public open class EchoPO {
    private var a: Int64 = 1
    private var b: String = 'asfd'
    private var c: Bool = true
    private var d: Float64 = 3.1415926
    private var inner: InnerPO = InnerPO()
}
