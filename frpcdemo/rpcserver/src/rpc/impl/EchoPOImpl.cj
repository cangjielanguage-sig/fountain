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
package fountain::rpcserver.rpc.impl

import fountain::f_data.*
import fountain::f_rpc.server.*
import fountain::f_rpc.macros.*
import fountain::rpcdef.EchoRPC
import fountain::rpcdef.model.EchoPO


@RPCSkeleton
public class EchoPOImpl <: EchoPO {
    public func echo(po: EchoPO): EchoPO {
        let obj = po.toData()
        let json = JsonValue.from(obj)
        println('===========================')
        println(json.toString())
        println('===========================')
        po
    }
}
