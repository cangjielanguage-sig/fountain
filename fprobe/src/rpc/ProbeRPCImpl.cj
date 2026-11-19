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

import fountain::f_probe.{ProbeErrorCode, ProbeException, ProbeRegistry}
import fountain::f_rpc.macros.*
import fountain::f_rpc.server.*
import fountain::fprobe.snapshot.{ProbeKinds, ProbeSnapshot, SnapshotStore}

/**
 * `ProbeRPC` 的服务端实现。
 *
 * `collect()` 只读 [SnapshotStore]，不触发采集；`kinds()` 读注册表，
 * 因此 supervisor 看到的监控项与 agent 实际注册的一致。
 *
 * `@RPCSkeleton` 生成的 `@Bean` 需要无参构造，所以同时提供两种入口：
 * 生产装配调用 [install] 绑定共享仓库，用例则直接注入。
 */
@RPCSkeleton
public class ProbeRPCImpl <: ProbeRPC {
    private static var installedStore: ?SnapshotStore = None
    private let store: ?SnapshotStore

    init() {
        this.store = None
    }

    init(store: SnapshotStore) {
        this.store = Some(store)
    }

    /** 绑定进程内共享的快照仓库；启动期调用一次。 */
    public static func install(store: SnapshotStore): Unit {
        installedStore = Some(store)
    }

    /** 清除绑定，仅供测试使用。 */
    public static func reset(): Unit {
        installedStore = None
    }

    public func collect(): ProbeSnapshot {
        currentStore().collect()
    }

    public func kinds(): ProbeKinds {
        ProbeKinds(ProbeRegistry.agents())
    }

    private func currentStore(): SnapshotStore {
        match (store) {
            case Some(value) => value
            case None => match (installedStore) {
                case Some(value) => value
                case None => throw ProbeException(ProbeErrorCode.CONFIG, "ProbeRPCImpl 尚未绑定 SnapshotStore")
            }
        }
    }
}
