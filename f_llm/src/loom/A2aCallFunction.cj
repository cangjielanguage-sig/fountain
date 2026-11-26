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
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_llm.tool.*
import fountain::f_log.*

/** `a2aCall` 的参数：把一段文本发给另一个 A2A 端点 */
@DataAssist[props fields]
public class A2aCallParam {
    @JsonStringSchema[description: '流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description: '目标 A2A 端点，如 http://127.0.0.1:8080/rpc']
    private var url: String = ''
    @JsonStringSchema[description: '发给对方的文本']
    private var text: String = ''
}

/**
 * 流程内可调用的 A2A 客户端工具。
 *
 * 与 `memoryCall` / `loomStoreCall` 同风格：参数不对或对方不可达都返回**可读错误文本**，
 * 不抛异常——一次外部调用失败不该中断整条流程。
 */
@Bean
public class A2aCallFunction <: FunctionCalling<A2aCallParam> {
    private let ask: (String, String) -> String

    public init(client!: ?LoomA2aClient = None) {
        let chosen = match (client) {
            case Some(value) => value
            case None => LoomA2aClient()
        }
        this.ask = { url, text => chosen.ask(url, text) }
    }

    /** 测试用法：注入「url + text → 正文」 */
    init(ask: (String, String) -> String) {
        this.ask = ask
    }

    public prop name: String {
        get() {
            'a2aCall'
        }
    }

    public prop description: String {
        get() {
            '调用另一个 A2A 智能体：url 为目标端点，text 为消息正文，返回对方的文本结果'
        }
    }

    public func call(params: A2aCallParam): FunctionResult {
        let url = params.url.trimAscii()
        if (url.isEmpty()) {
            return FunctionResult(event: params.nextEvent, result: 'a2aCall requires url')
        }
        if (params.text.isEmpty()) {
            return FunctionResult(event: params.nextEvent, result: 'a2aCall requires text')
        }
        try {
            FunctionResult(event: params.nextEvent, result: ask(url, params.text))
        } catch (e: Exception) {
            FunctionResult(event: params.nextEvent, result: 'a2aCall failed: ${e.message}')
        }
    }
}
