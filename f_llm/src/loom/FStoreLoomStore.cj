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
package fountain::f_llm.loom

import std.collection.*
import std.convert.*

import fountain::f_store.Store

import fountain::f_llm.store.*

/**
 * f_store 版流程存储（元数据族，与 `MetaStore` 共用 `llm_metaStore` 配置项）。
 *
 * 键布局（按字段拆键，避免把多行源码拼成一条记录再切分）：
 *
 * ```
 * f_llm:loom:index:{name}          → 空值，仅用于列举
 * f_llm:loom:data:{name}:h         → status \u0003 round \u0003 tools \u0003 mcps
 * f_llm:loom:data:{name}:d         → description
 * f_llm:loom:data:{name}:p         → planJson
 * f_llm:loom:data:{name}:f         → flowSource
 * f_llm:loom:data:{name}:q         → questionsJson
 * f_llm:loom:data:{name}:s         → stepSources（StepSourceCodec 编码）
 * ```
 *
 * 之所以不用「一条记录 + 分隔符」：`planJson`/`flowSource` 含换行与引号，
 * 拆字段存可以完全绕开转义问题；loom 的写入频率极低，多几次 put 不值得优化。
 */
public class FStoreLoomStore <: LoomStore {
    private static const INDEX = 'f_llm:loom:index:'
    private static const DATA = 'f_llm:loom:data:'
    private static let SEP = String.fromUtf8([3u8])

    private let store: Store

    public init(path: String) {
        this.store = Store(path)
    }

    /** 容器用：路径取 `llm_metaStorePath`（相对部署目录解析） */
    public init() {
        this.store = Store(DeployPaths.resolve(StoreSettings.load().metaStorePath))
    }

    public func save(flow: LoomFlow): Unit {
        let header = '${flow.status}${SEP}${flow.round}${SEP}${flow.tools}${SEP}${flow.mcps}'
        put('${DATA}${flow.name}:h', header)
        put('${DATA}${flow.name}:d', flow.description)
        put('${DATA}${flow.name}:p', flow.planJson)
        put('${DATA}${flow.name}:f', flow.flowSource)
        put('${DATA}${flow.name}:q', flow.questionsJson)
        put('${DATA}${flow.name}:s', StepSourceCodec.encode(flow.stepSources))
        put('${INDEX}${flow.name}', '')
    }

    public func get(name: String): ?LoomFlow {
        let header = match(text('${DATA}${name}:h')){
            case Some(value) => value
            case None => return None
        }
        let parts = header.split(SEP)
        let status = if(parts.size > 0){ parts[0] }else{ LoomStatus.PENDING }
        let round = if(parts.size > 1){ Int64.tryParse(parts[1]) ?? 0 }else{ 0 }
        let tools = if(parts.size > 2){ parts[2] }else{ '' }
        let mcps = if(parts.size > 3){ parts[3] }else{ '' }

        let flow = LoomFlow(name, description: text('${DATA}${name}:d') ?? '')
        flow.planJson = text('${DATA}${name}:p') ?? ''
        flow.flowSource = text('${DATA}${name}:f') ?? ''
        flow.stepSources = StepSourceCodec.decode(text('${DATA}${name}:s') ?? '')
        flow.status = status
        flow.round = round
        flow.questionsJson = text('${DATA}${name}:q') ?? ''
        flow.tools = tools
        flow.mcps = mcps
        Some(flow)
    }

    public func list(offset: Int64, limit: Int64): ArrayList<LoomFlow> {
        let names = ArrayList<String>()
        for((key, _) in store.prefix(INDEX.toArray())){
            let full = String.fromUtf8(key)
            if(full.size > INDEX.size){
                names.add(full[INDEX.size..])
            }
        }
        MemoryLoomStore.sortNames(names)

        let result = ArrayList<LoomFlow>()
        var index = offset
        while(index < Int64(names.size) && Int64(result.size) < limit){
            match(get(names[index])){
                case Some(flow) => result.add(flow)
                case None => ()
            }
            index++
        }
        result
    }

    public func remove(name: String): Bool {
        let existed = store.contains('${DATA}${name}:h'.toArray())
        let prefix = '${DATA}${name}:'
        let keys = ArrayList<String>()
        for((key, _) in store.prefix(prefix.toArray())){
            keys.add(String.fromUtf8(key))
        }
        for(key in keys){
            store.remove(key.toArray())
        }
        store.remove('${INDEX}${name}'.toArray())
        existed
    }

    private func put(key: String, value: String): Unit {
        store.add(key.toArray(), value.toArray())
        ()
    }

    private func text(key: String): ?String {
        match(store.get(key.toArray())){
            case Some(bytes) => Some(String.fromUtf8(bytes))
            case None => None
        }
    }
}
