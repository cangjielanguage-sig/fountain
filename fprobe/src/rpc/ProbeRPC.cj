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
package fountain::fprobe.rpc

import fountain::f_rpc.client.*
import fountain::f_rpc.macros.*
import fountain::fprobe.snapshot.{ProbeKinds, ProbeSnapshot}

/**
 * 节点采集的 RPC 契约。
 *
 * `collect` 一次返回该节点全部监控项；`kinds` 用于 supervisor 核对期望监控项。
 * 返回类型必须是 `DataFields`，因此不能直接返回 `Array<String>`。
 */
@RPCStub
public interface ProbeRPC {
    func collect(): ProbeSnapshot

    func kinds(): ProbeKinds
}
