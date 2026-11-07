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

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.macros.*

import fountain::f_llm.tool.*

/** 列出已注册工具（分页） */
@DataAssist[props fields]
public class ListToolsParam {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'起始偏移，默认 0']
    private var offset: String = '0'
    @JsonStringSchema[description:'返回条数，默认 20']
    private var limit: String = '20'
}

@Bean
public class ListToolsFunction <: FunctionCalling<ListToolsParam> {
    public init() {
    }

    public prop name: String {
        get() {
            'listTools'
        }
    }

    public prop description: String {
        get() {
            '列出当前已注册的工具（名称 + 描述），支持分页'
        }
    }

    public func call(params: ListToolsParam): FunctionResult {
        let offset = Int64.tryParse(params.offset.trimAscii()) ?? 0
        let limit = Int64.tryParse(params.limit.trimAscii()) ?? 20
        let all = ToolCatalog.entries()
        var text = '['
        var first = true
        var index = offset
        var taken: Int64 = 0
        while(index < Int64(all.size) && taken < limit){
            if(!first){
                text += ','
            }
            first = false
            text += '{"name":${FlowPlan.jsonQuote(all[index].name)},'
            text += '"description":${FlowPlan.jsonQuote(all[index].description)}}'
            index++
            taken++
        }
        FunctionResult(event: params.nextEvent, result: text + ']')
    }
}

/** 按关键词检索工具 */
@DataAssist[props fields]
public class SearchToolsParam {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'关键词，匹配工具名与描述']
    private var query: String = ''
    @JsonStringSchema[description:'返回条数，默认 5']
    private var topK: String = '5'
}

@Bean
public class SearchToolsFunction <: FunctionCalling<SearchToolsParam> {
    public init() {
    }

    public prop name: String {
        get() {
            'searchTools'
        }
    }

    public prop description: String {
        get() {
            '按关键词检索工具，返回名称、描述与相关度得分'
        }
    }

    public func call(params: SearchToolsParam): FunctionResult {
        if(params.query.trimAscii().isEmpty()){
            return FunctionResult(event: params.nextEvent, result: 'searchTools requires query')
        }
        let topK = Int64.tryParse(params.topK.trimAscii()) ?? 5
        let hits = ToolCatalog.search(params.query, topK: topK)
        var text = '['
        var first = true
        for(item in hits){
            if(!first){
                text += ','
            }
            first = false
            text += '{"name":${FlowPlan.jsonQuote(item.name)},'
            text += '"description":${FlowPlan.jsonQuote(item.description)},'
            text += '"score":${item.score}}'
        }
        FunctionResult(event: params.nextEvent, result: text + ']')
    }
}
