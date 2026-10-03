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

// 跨网络传输的对象类型不再需要手工 `DefaultCodec.registerType<EchoPO>()`：
// @RPCStub / @RPCSkeleton 展开时会自动登记其参数与返回类型（见 bug.md 7.11）。
@DataAssist[props fields]
public open class EchoPO {
    private var a: Int64 = 1
    private var b: String = 'asfd'
    private var c: Bool = true
    private var d: Float64 = 3.1415926
}