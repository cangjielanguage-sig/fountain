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

/** loom 层错误（计划非法、工具越界、编译失败等） */
public class LoomException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * 计划中的一步（§9.3）。
 *
 * 只描述「做什么」，不含仓颉代码；`kind` 取值：`tool` / `llm` / `mcp` / `jit` / `http`。
 */
public class StepPlan {
    public var id: String
    public var kind: String
    public var tool: String = ''
    public var model: String = ''
    public var system: String = ''
    public var input: String = ''
    /** 参数模板（原样 JSON 对象文本，模板变量由 CodeGen 替换） */
    public var args: String = '{}'
    /** `auto` / `true` / `false`；`auto` 由 §9.5 的 kind 推断 */
    public var async: String = 'auto'
    public var external: Bool = false

    public init(id: String, kind: String) {
        this.id = id
        this.kind = kind
    }
}

/** 计划的边：`from -> to` */
public class EdgePlan {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        this.from = from
        this.to = to
    }
}

/**
 * 一份流程计划（LLM 只产出这一层，§9.3）。
 *
 * `toJson()` 按设计文档的 schema 输出，供 `LoomStore` 落库与人工审阅。
 */
public class FlowPlan {
    public let name: String
    public var persona: String = ''
    /** 计划声明要加载的技能标题：执行时注入 system（空则由任务描述自动检索） */
    public var skills: ArrayList<String> = ArrayList<String>()
    public var steps: ArrayList<StepPlan> = ArrayList<StepPlan>()
    public var edges: ArrayList<EdgePlan> = ArrayList<EdgePlan>()
    public var notes: String = ''
    /** 是否允许并发执行分叉（由开发者或模型决定） */
    public var parallel: Bool = false
    /** 澄清轮次（§9.11），完整计划为 0 */
    public var round: Int64 = 0

    public init(name: String) {
        this.name = name
    }

    public func step(id: String): ?StepPlan {
        for (item in steps) {
            if (item.id == id) {
                return Some(item)
            }
        }
        None
    }

    /** 校验：步骤 id 唯一、边两端存在、无自环、kind 合法 */
    public func validate(): Unit {
        if (name.trimAscii().isEmpty()) {
            throw LoomException('loom plan name must not be blank')
        }
        let seen = HashMap<String, Bool>()
        for (item in steps) {
            if (item.id.trimAscii().isEmpty()) {
                throw LoomException('loom step id must not be blank')
            }
            if (seen.contains(item.id)) {
                throw LoomException('duplicate loom step id: ${item.id}')
            }
            seen[item.id] = true
            match (item.kind) {
                case 'tool' | 'llm' | 'mcp' => ()
                case 'jit' =>
                    // jit 源码在编译期固化，{step.output} 不会被替换：与其留成字面量，不如直接拒绝
                    for (token in seen.keys()) {
                        if (item.input.contains('{${token}.output}') || item.input.contains('{${token}}')) {
                            throw LoomException(
                                'jit step does not support {…} template placeholders '
                                    + '(${item.id} references ${token}): use an llm/tool step, '
                                    + 'or call loomStore/loomCallTool inside the snippet')
                        }
                    }
                    if (item.input.contains('{start.output}') || item.input.contains('{start}')) {
                        throw LoomException(
                            'jit step does not support {…} template placeholders '
                                + '(${item.id} references start): use an llm/tool step, '
                                + 'or call loomStore/loomCallTool inside the snippet')
                    }
                // http 尚未实现：明确拒绝，避免被当成 llm 步骤静默执行
                case 'http' => throw LoomException('loom step kind http is not implemented yet: ${item.id}')
                case _ => throw LoomException('unknown loom step kind: ${item.kind} (step ${item.id})')
            }
            if (item.kind == 'tool' && item.tool.isEmpty()) {
                throw LoomException('tool step must set tool: ${item.id}')
            }
        }
        for (edge in edges) {
            if (step(edge.from).isNone() || step(edge.to).isNone()) {
                throw LoomException('edge refers to missing step: ${edge.from} -> ${edge.to}')
            }
            if (edge.from == edge.to) {
                throw LoomException('loom plan must not contain self loop: ${edge.from}')
            }
        }
    }

    public func toJson(): String {
        var text = '{\n'
        text += '  \"name\": ${jsonQuote(name)},\n'
        if (!persona.isEmpty()) {
            text += '  \"persona\": ${jsonQuote(persona)},\n'
        }
        if (!skills.isEmpty()) {
            text += '  \"skills\": ['
            for (index in 0..skills.size) {
                if (index > 0) {
                    text += ', '
                }
                text += jsonQuote(skills[index])
            }
            text += '],\n'
        }
        text += '  "steps": [\n'
        for (index in 0..steps.size) {
            text += '    ${steps[index].toJson()}'
            if (index + 1 < steps.size) {
                text += ','
            }
            text += '\n'
        }
        text += '  ],\n'
        text += '  "edges": ['
        for (index in 0..edges.size) {
            if (index > 0) {
                text += ', '
            }
            // jsonQuote 自带引号，这里不能再包一层
            text += '[${jsonQuote(edges[index].from)}, ${jsonQuote(edges[index].to)}]'
        }
        text += ']'
        if (parallel) {
            text += ',\n  "parallel": true'
        }
        if (!notes.isEmpty()) {
            text += ',\n  \"notes\": ${jsonQuote(notes)}'
        }
        text + '\n}'
    }

    internal static func jsonQuote(text: String): String {
        let out = ArrayList<Byte>()
        for (byte in text.toArray()) {
            let ch = UInt8(byte)
            if (ch == 34u8) {
                out.add(92u8)
                out.add(34u8)
            } else if (ch == 92u8) {
                out.add(92u8)
                out.add(92u8)
            } else if (ch == 10u8) {
                out.add(92u8)
                out.add(110u8)
            } else if (ch == 13u8) {
                out.add(92u8)
                out.add(114u8)
            } else if (ch < 32u8) {
                out.add(92u8)
                out.add(117u8)
                out.add(48u8)
                out.add(48u8)
                out.add(hexOf(ch >> 4))
                out.add(hexOf(ch & 0x0Fu8))
            } else {
                out.add(ch)
            }
        }
        '"' + String.fromUtf8(out.toArray()) + '"'
    }

    internal static func hexOf(value: UInt8): Byte {
        if (value < 10u8) {
            48u8 + value
        } else {
            97u8 + (value - 10u8)
        }
    }
}

extend StepPlan {
    public func toJson(): String {
        var text = '{\"id\": ${jsonQuote(id)}, \"kind\": ${jsonQuote(kind)}'
        if (!tool.isEmpty()) {
            text += ', \"tool\": ${jsonQuote(tool)}'
        }
        if (!model.isEmpty()) {
            text += ', \"model\": ${jsonQuote(model)}'
        }
        if (!system.isEmpty()) {
            text += ', \"system\": ${jsonQuote(system)}'
        }
        if (!input.isEmpty()) {
            text += ', \"input\": ${jsonQuote(input)}'
        }
        text += ', \"args\": ${args}'
        text += ', \"async\": ${jsonQuote(async)}'
        if (external) {
            text += ', "external": true'
        }
        text + '}'
    }

    internal static func jsonQuote(text: String): String {
        FlowPlan.jsonQuote(text)
    }
}
