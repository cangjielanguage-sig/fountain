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
package fountain::f_llm.store.hydra

import std.collection.*
import std.env.*
import std.sync.*

import fountain::f_hydra.*
import fountain::f_llm.store.*

/**
 * 基于 f_hydra 的演进租约：把时间型 UUID 存成一条**全 0 向量**记录的 payload。
 *
 * 之所以用全 0 向量：租约不是语义数据，不该被任何检索命中；全 0 向量与任何查询的
 * 余弦相似度都是 0，天然不会被 dense/sparse 检索带出来，同时又复用了已有的存储与同步能力。
 */
public class HydraEvolutionLease <: EvolutionLease {
    private static let COLLECTION = 'f_llm:lease'
    private static let RECORD_ID = 'evolution'

    private let transport: HydraTransport
    private let mutex = Mutex()

    /** 进程内：直接落本地 f_hydra 目录（`llm_hydraPath` 或默认 ./data/f_hydra） */
    public init(path!: String = '') {
        let location = if(path.isEmpty()){
            DeployPaths.resolve(getVariable('llm_hydraPath') ?? './data/f_hydra')
        }else{
            path
        }
        this.transport = InProcessTransport(FStoreVectorStore(location))
    }

    init(transport: HydraTransport) {
        this.transport = transport
    }

    /** 远程 fhydra：`llm_hydraUrl` / `llm_hydraSecret` */
    public static func remote(): HydraEvolutionLease {
        HydraEvolutionLease(HttpTransport())
    }

    public func ensure(now: Int64): String {
        let box = HydraLeaseBox()
        synchronized(mutex){
            let current = read()
            if(current.isEmpty()){
                let created = TimeUuid.create()
                write(created)
                box.value = created
            }else{
                box.value = current
            }
        }
        box.value
    }

    public func current(): String {
        let box = HydraLeaseBox()
        synchronized(mutex){
            box.value = read()
        }
        box.value
    }

    public func acquire(now: Int64): String {
        let box = HydraLeaseBox()
        synchronized(mutex){
            let previous = read()
            if(previous.isEmpty() || TimeUuid.dayOf(previous) != now / 86400){
                let created = TimeUuid.create()
                // hydra 没有条件写：先写后读校验，写输的一方会让后读到的值与自己不同
                write(created)
                if(read() == created){
                    box.value = created
                }
            }
        }
        box.value
    }

    private func read(): String {
        match(transport.get(COLLECTION, RECORD_ID)){
            case Some(record) => record.payload
            case None => ''
        }
    }

    private func write(value: String): Unit {
        // 全 0 向量：不参与语义检索；时间型 UUID 放在 payload
        let zeros = [0.0f64]
        transport.upsert(COLLECTION, VectorRecord(RECORD_ID, value, zeros))
    }
}

class HydraLeaseBox {
    public var value: String = ''
}
