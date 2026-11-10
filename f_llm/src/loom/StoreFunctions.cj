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

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.macros.*
import fountain::f_llm.tool.*

/**
 * 记忆入口：模型可以直接读写长期记忆，不必经过 loom 流程。
 *
 * 底层复用 [LoomStoreGateway]（与 `loomStore("memory", …)` 同一条链路），
 * 因此两条入口的行为永远一致。
 */
@DataAssist[props fields]
public class MemoryCallParam {
    @JsonStringSchema[description: '流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description: '操作：search | add | remove']
    private var op: String = ''
    @JsonStringSchema[description: 'JSON 参数，如 {"userId":1,"text":"…","topK":5}']
    private var payload: String = '{}'
}

@Bean
public class MemoryCallFunction <: FunctionCalling<MemoryCallParam> {
    private let injected: ?LoomStoreGateway

    /** 测试可注入网关；生产环境留空，调用时按当前配置取 Store */
    public init(gateway!: ?LoomStoreGateway = None) {
        this.injected = gateway
    }

    public prop name: String {
        get() {
            'memoryCall'
        }
    }

    public prop description: String {
        get() {
            '读写长期记忆：op=search 检索、add 写入、remove 删除，payload 为 JSON 参数'
        }
    }

    public func call(params: MemoryCallParam): FunctionResult {
        let op = params.op.trimAscii().toAsciiLower()
        if (op != 'search' && op != 'add' && op != 'remove') {
            return FunctionResult(event: params.nextEvent,
                result: 'unsupported memoryCall op: ${params.op} (expected search|add|remove)')
        }
        try {
            FunctionResult(event: params.nextEvent, result: invoke('memory', op, params.payload))
        } catch (error: Exception) {
            FunctionResult(event: params.nextEvent, result: 'memoryCall failed: ${error.message}')
        }
    }

    /** 优先用注入的网关，其次用装配安装的网关；都没装才自建（保持可单独使用） */
    private func invoke(kind: String, op: String, payload: String): String {
        StoreInvoker.invoke(injected, kind, op, payload)
    }
}

/**
 * 工具的存储调用：注入 > 装配安装 > 自建。
 *
 * 三个工具共用一份，避免「能力拷贝」在工具层再繁衍一遍。
 */
class StoreInvoker {
    static func invoke(injected: ?LoomStoreGateway, kind: String, op: String, payload: String): String {
        match (injected) {
            case Some(gateway) => gateway.call(kind, op, payload)
            case None => try {
                LoomHostApi.callStore(kind, op, payload)
            } catch (error: LoomException) {
                LoomStoreGateway().call(kind, op, payload)
            }
        }
    }
}

/** 知识写入入口：把一段文档写进知识库，后续可用 knowledge.search 检索 */
@DataAssist[props fields]
public class KnowledgeIngestParam {
    @JsonStringSchema[description: '流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description: '文档标识，全局唯一']
    private var docId: String = ''
    @JsonStringSchema[description: '文档标题']
    private var title: String = ''
    @JsonStringSchema[description: '文档正文']
    private var content: String = ''
}

@Bean
public class KnowledgeIngestFunction <: FunctionCalling<KnowledgeIngestParam> {
    private let injected: ?LoomStoreGateway

    public init(gateway!: ?LoomStoreGateway = None) {
        this.injected = gateway
    }

    public prop name: String {
        get() {
            'knowledgeIngest'
        }
    }

    public prop description: String {
        get() {
            '把一篇文档写入知识库（覆盖同名 docId），供后续检索'
        }
    }

    public func call(params: KnowledgeIngestParam): FunctionResult {
        if (params.docId.trimAscii().isEmpty()) {
            return FunctionResult(event: params.nextEvent, result: 'knowledgeIngest requires docId')
        }
        let payload = '{\"docId\":${FlowPlan.jsonQuote(params.docId)},'
            + '\"title\":${FlowPlan.jsonQuote(params.title)},'
            + '\"content\":${FlowPlan.jsonQuote(params.content)}}'
        try {
            FunctionResult(event: params.nextEvent, result: invoke('knowledge', 'upsert', payload))
        } catch (error: Exception) {
            FunctionResult(event: params.nextEvent, result: 'knowledgeIngest failed: ${error.message}')
        }
    }

    /** 同 `memoryCall`：注入 > 装配安装 > 自建 */
    private func invoke(kind: String, op: String, payload: String): String {
        StoreInvoker.invoke(injected, kind, op, payload)
    }
}

/**
 * 通用存储入口：与 `loomStore(kind, op, payload)` 完全同源。
 *
 * 存在的理由：`kind=tool` 的步骤只能调工具，拿不到 JIT 里的 `loomStore`——
 * 没有这个工具就读不了知识、经验，也加载不了技能。
 */
@DataAssist[props fields]
public class StoreCallParam {
    @JsonStringSchema[description: '流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description: '数据类别：memory | experience | knowledge | skill | prompt | character']
    private var kind: String = ''
    @JsonStringSchema[description: '操作：按类别而定（get/list/search/add/remove/upsert/load/count/docIds）']
    private var op: String = ''
    @JsonStringSchema[description: 'JSON 参数，如 {"userId":1,"namespace":"loom","text":"…"}']
    private var payload: String = '{}'
}

@Bean
public class StoreCallFunction <: FunctionCalling<StoreCallParam> {
    private let injected: ?LoomStoreGateway

    public init(gateway!: ?LoomStoreGateway = None) {
        this.injected = gateway
    }

    public prop name: String {
        get() {
            'loomStoreCall'
        }
    }

    public prop description: String {
        get() {
            '按类别读写长期数据：kind=memory/experience/knowledge/skill/prompt/character，'
                + 'op 与 loomStore 一致（get/list/search/add/remove/upsert/load/count/docIds），payload 为 JSON'
        }
    }

    public func call(params: StoreCallParam): FunctionResult {
        let kind = params.kind.trimAscii().toAsciiLower()
        let op = params.op.trimAscii().toAsciiLower()
        if (kind.isEmpty()) {
            return FunctionResult(event: params.nextEvent, result: 'loomStoreCall requires kind')
        }
        if (op.isEmpty()) {
            return FunctionResult(event: params.nextEvent, result: 'loomStoreCall requires op')
        }
        let raw = params.payload.trimAscii()
        let payload = if (raw.isEmpty()) {
            '{}'
        } else {
            raw
        }
        // 只挡「明显不是对象」的输入；深度校验交给网关（它有可读错误）
        if (!payload.startsWith('{') || !payload.endsWith('}')) {
            return FunctionResult(event: params.nextEvent,
                result: 'loomStoreCall payload must be a JSON object, got: ${payload}')
        }
        try {
            FunctionResult(event: params.nextEvent, result: invoke(kind, op, payload))
        } catch (error: Exception) {
            FunctionResult(event: params.nextEvent, result: 'loomStoreCall failed: ${error.message}')
        }
    }

    private func invoke(kind: String, op: String, payload: String): String {
        StoreInvoker.invoke(injected, kind, op, payload)
    }
}
