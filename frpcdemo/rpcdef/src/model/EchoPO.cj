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
import fountain::f_codec.default.DefaultCodec

/**
 * 解码侧必须先注册对象类型的创建者：`DefaultCodec` 的类型hash→creator 注册表只在该进程
 * **编码过**该类型时才登记，只解码不编码的一侧（客户端第一次收EchoPO响应、服务端第一次收EchoPO请求）
 * 否则会以“object type murmur ... is not registered”失败。
 * rpcdef 是两端共享的模块，在这里注册一次即可覆盖两侧。
 */
private let _ = DefaultCodec.registerType<EchoPO>()

@DataAssist[props fields]
public open class EchoPO {
    private var a: Int64 = 1
    private var b: String = 'asfd'
    private var c: Bool = true
    private var d: Float64 = 3.1415926
}