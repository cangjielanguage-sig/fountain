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
package fountain::f_llm.model.po

import std.collection.HashMap
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_orm.*
import fountain::f_orm.macros.*

/**
 * 一个平台上的一个大模型配置。
 *
 * 同一个 llmName 可以由多条配置提供（多平台），按 weight 分配流量。
 * conf 是开放的字符串键值表（tokenThreshold / thinking / chatPath / searchUrl ...）。
 */
@DataAssist[props fields]
@QueryMappersGenerator[table: llm_conf]
public class LLMConf {
    @ORMField[true 'id']
    private var id: Int64 = 0

    /** 提供服务的平台名称：zhipu / deepseek / ark / dashscope / siliconflow / openai ... */
    @ORMField['provider']
    private var provider: String = ''

    /** 统一的大模型名：框架内唯一寻址键 */
    @ORMField['llm_name']
    private var llmName: String = ''

    /** 平台实际使用的模型名 */
    @ORMField['actual_llm_name']
    private var actualLlmName: String = ''

    /** baseUrl，不含协议路径 */
    @ORMField['llm_url']
    private var url: String = ''

    /** 鉴权 KEY，或 secretRef:env:NAME */
    @ORMField['auth']
    private var auth: String = ''

    /** 温度：< 0 表示用平台默认值（报文不带该参数） */
    @ORMField['temperature']
    private var temperature: Float64 = -1.0f64

    /** 有些模型必须开启思考 */
    @ORMField['always_thinking']
    private var alwaysThinking: Bool = false

    /**
     * 其他配置，见设计文档 3.5。
     *
     * ORM 只认基础类型与 PO，不认识 Map，所以库里存 JSON 文本（列名仍是 conf），
     * 对外用下面的 conf 属性读写 Map。切换由此处一次性完成，调用方无需感知。
     */
    @ORMField['conf']
    private var confJson: String = '{}'

    @DataExclude[prop field]
    public prop conf: HashMap<String, String> {
        get() {
            LLMConfCodec.fromColumn(confJson)
        }
    }

    /** 只能用函数写入：PO 上的 public mut prop 会被 ORM 当成列映射，Map 类型它不支持 */
    public func setConf(value: HashMap<String, String>): Unit {
        confJson = LLMConfCodec.toColumn(value)
    }

    /** 当前配置是否启用 */
    @ORMField['enabled']
    private var enabled: Bool = true

    /** 多个平台为相同 llmName 提供服务时分配流量的权重（> 0 才有效） */
    @ORMField['weight']
    private var weight: Int64 = 1

    public func option(key: String): ?String {
        conf.get(key)
    }

    public func option(key: String, defaultValue: String): String {
        conf.get(key) ?? defaultValue
    }

    public func optionInt(key: String, defaultValue: Int64): Int64 {
        if(let Some(v) <- option(key)){
            Int64.tryParse(v) ?? defaultValue
        }else{
            defaultValue
        }
    }

    public func optionBool(key: String, defaultValue: Bool): Bool {
        if(let Some(v) <- option(key)){
            v == 'true' || v == '1'
        }else{
            defaultValue
        }
    }

    /** 该平台该模型的饱和 token 数；0 表示不限制 */
    @DataExclude[prop field]
    public prop tokenThreshold: Int64 {
        get() {
            optionInt('tokenThreshold', 0)
        }
    }

    @DataExclude[prop field]
    public prop streamable: Bool {
        get() {
            optionBool('stream', true)
        }
    }

    /** 平台标识、模型名或地址缺失的残缺配置 */
    @DataExclude[prop field]
    public prop isPlaceholder: Bool {
        get() {
            provider.isEmpty() || actualLlmName.isEmpty() || url.isEmpty()
        }
    }
}
