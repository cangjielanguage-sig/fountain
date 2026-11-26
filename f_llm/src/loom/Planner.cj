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
import fountain::f_data.*
import fountain::f_data.base.DataObject
import fountain::f_data.base.ObjectData
import fountain::f_data.macros.DataAssist

/** 规划请求（§9.2） */
public class LoomRequest {
    public let name: String
    public let description: String
    public let tools: Array<String>
    public let mcps: Array<String>
    public let persona: String
    /** 上一轮澄清的回答：questionId → value */
    public let answers: HashMap<String, String>
    /** 澄清轮次用尽时的策略：ask | default | abort */
    public let onUnresolved: String
    public let dryRun: Bool
    /** 规划用模型；空串表示由 chat 回调使用默认模型 */
    public let model: String
    /** 是否允许并发执行分叉；模型可在计划里覆盖 */
    public let parallel: Bool
    /** 默认技能：计划 JSON 没写 skills 时用它 */
    public let skills: Array<String>

    public init(name: String, description: String, tools!: Array<String> = Array<String>(),
        mcps!: Array<String> = Array<String>(), persona!: String = '',
        answers!: HashMap<String, String> = HashMap<String, String>(), onUnresolved!: String = 'ask',
        dryRun!: Bool = true, model!: String = '', parallel!: Bool = false, skills!: Array<String> = Array<String>()) {
        if (name.trimAscii().isEmpty()) {
            throw LoomException('loom name must not be blank')
        }
        if (description.trimAscii().isEmpty()) {
            throw LoomException('loom description must not be blank')
        }
        this.name = name
        this.description = description
        this.tools = tools
        this.mcps = mcps
        this.persona = persona
        this.answers = answers
        this.onUnresolved = onUnresolved
        this.dryRun = dryRun
        this.model = model
        this.parallel = parallel
        this.skills = skills
    }
}

/** 澄清问题（§9.11） */
public class ClarifyQuestion {
    public let id: String
    public let question: String
    public let why: String
    public let blocking: Bool
    public let defaultValue: String
    public let options: ArrayList<String>

    public init(id: String, question: String, why!: String = '', blocking!: Bool = true, defaultValue!: String = '',
        options!: ArrayList<String> = ArrayList<String>()) {
        this.id = id
        this.question = question
        this.why = why
        this.blocking = blocking
        this.defaultValue = defaultValue
        this.options = options
    }
}

/** 规划结果：要么拿到计划，要么需要澄清 */
public class PlannerResult {
    public let status: String
    public let plan: ?FlowPlan
    public let questions: ArrayList<ClarifyQuestion>
    public let assumptions: ArrayList<String>
    public let round: Int64

    public init(status: String, plan: ?FlowPlan, questions: ArrayList<ClarifyQuestion>, assumptions: ArrayList<String>,
        round: Int64) {
        this.status = status
        this.plan = plan
        this.questions = questions
        this.assumptions = assumptions
        this.round = round
    }

    public prop isPlanned: Bool {
        get() {
            status == 'planned'
        }
    }
}

/**
 * 把自然语言描述解析成 [FlowPlan]（§9.3）。
 *
 * 模型调用以 `(system, user) -> String` 注入：测试用固定 JSON，生产接 LLM 客户端。
 * 模型只产出 JSON，不产出仓颉代码——代码由 `CodeGen` 生成。
 */
public class Planner {
    private let llm: (String, String) -> String

    private let systemPrompt: String

    /** 开发者自定义的编排提示词；为空时用 [Prompts.PLANNER_SYSTEM] */
    public init(llm: (String, String) -> String, systemPrompt!: String = '') {
        this.llm = llm
        this.systemPrompt = systemPrompt
    }

    public func plan(request: LoomRequest): PlannerResult {
        let base = if (systemPrompt.trimAscii().isEmpty()) {
            Prompts.PLANNER_SYSTEM
        } else {
            systemPrompt
        }
        // 能力清单始终追加：自定义提示词也一样，否则模型不知道宿主有什么。
        // 任务描述里给了 tools 白名单时只列这些（按需收窄）。
        let allowed: ?Array<String> = if (request.tools.size > 0) {
            Some(request.tools)
        } else {
            None
        }
        let system = base + '\n\n' + PromptCapabilities.render(allowed: allowed)
        let raw = llm(system, Planner.userPrompt(request))
        Planner.parse(raw, request)
    }

    public static func parse(raw: String, request: LoomRequest): PlannerResult {
        // 模型偶尔用 ```json 包裹，或加解释性文字：先剥围栏再确认外层是 JSON 对象
        let trimmed = stripFence(raw)
        if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
            throw LoomException('planner returned invalid JSON: expect a JSON object')
        }
        let dto = match (DataObject<PlanDto>.populate(JsonValue.fromStr(raw).toData())) {
            case Some(value) => value
            case None => throw LoomException('planner returned invalid JSON')
        }
        let round = dto.round
        if (dto.status == 'need_clarification') {
            return PlannerResult('need_clarification', None, questionsOf(dto), assumptionsOf(dto), round)
        }
        let plan = planOf(dto, request)
        PlannerResult('planned', Some(plan), ArrayList<ClarifyQuestion>(), assumptionsOf(dto), round)
    }

    private static func planOf(dto: PlanDto, request: LoomRequest): FlowPlan {
        let name = if (dto.name.trimAscii().isEmpty()) {
            request.name
        } else {
            dto.name
        }
        let plan = FlowPlan(name)
        plan.persona = if (dto.persona.isEmpty()) {
            request.persona
        } else {
            dto.persona
        }
        // 技能：模型在计划里写了就用计划的，否则用请求给的（都空则执行期自动检索）
        if (!dto.skills.isEmpty()) {
            for (title in dto.skills) {
                if (!title.trimAscii().isEmpty()) {
                    plan.skills.add(title.trimAscii())
                }
            }
        } else {
            for (title in request.skills) {
                if (!title.trimAscii().isEmpty()) {
                    plan.skills.add(title.trimAscii())
                }
            }
        }
        plan.notes = dto.notes
        plan.round = dto.round
        // 开发者（请求）或模型（计划）任一认为可并发，就允许并发
        plan.parallel = dto.parallel || request.parallel
        for (item in dto.steps) {
            let step = StepPlan(item.id, item.kind)
            step.tool = item.tool
            step.model = item.model
            step.system = item.system
            step.input = item.input
            if (!item.args.isEmpty()) {
                step.args = argsJson(item.args)
            }
            if (item.async == 'false') {
                step.async = 'false'
            } else if (item.async == 'true') {
                step.async = 'true'
            }
            step.external = item.external
            plan.steps.add(step)
        }
        for (edge in dto.edges) {
            if (edge.size != 2) {
                throw LoomException('planner edge must have exactly 2 endpoints')
            }
            plan.edges.add(EdgePlan(edge[0], edge[1]))
        }
        plan.validate()
        plan
    }

    /**
     * 去掉 Markdown 代码围栏（` ```json ... ``` `）。
     *
     * 模型经常把 JSON 包在围栏里；不剥掉就会被判成非法 JSON。
     */
    internal static func stripFence(raw: String): String {
        var text = raw.trimAscii()
        if (!text.startsWith('```')) {
            return text
        }
        let lines = text.split('\n')
        var body = ''
        for (index in 1..lines.size) {
            let line = lines[index].trimAscii()
            if (line.startsWith('```')) {
                break
            }
            if (!body.isEmpty()) {
                body += '\n'
            }
            body += lines[index]
        }
        body.trimAscii()
    }

    /** 参数模板 → JSON 文本（step.args 保存原始 JSON，供 CodeGen 替换变量） */
    private static func argsJson(args: HashMap<String, String>): String {
        var text = '{'
        var first = true
        for ((key, value) in args) {
            if (!first) {
                text += ','
            }
            first = false
            text += '${FlowPlan.jsonQuote(key)}:${FlowPlan.jsonQuote(value)}'
        }
        text + '}'
    }

    private static func questionsOf(dto: PlanDto): ArrayList<ClarifyQuestion> {
        let result = ArrayList<ClarifyQuestion>()
        for (item in dto.questions) {
            let options = ArrayList<String>()
            for (option in item.options) {
                options.add(if (option.value.isEmpty()) {
                    option.label
                } else {
                    option.value
                })
            }
            result.add(
                ClarifyQuestion(item.id, item.question, why: item.why, blocking: item.blocking,
                    defaultValue: item.defaultValue, options: options))
        }
        result
    }

    private static func assumptionsOf(dto: PlanDto): ArrayList<String> {
        let result = ArrayList<String>()
        for (item in dto.assumptions) {
            result.add('${item.field}=${item.value}（${item.reason}）')
        }
        result
    }

    private static func userPrompt(request: LoomRequest): String {
        var text = '任务名：${request.name}\n'
        text += '任务描述：${request.description}\n'
        if (!request.persona.isEmpty()) {
            text += '人格：${request.persona}\n'
        }
        if (request.tools.size > 0) {
            text += '可用工具：${request.tools.toString()}\n'
        }
        if (request.mcps.size > 0) {
            text += '可用 MCP：${request.mcps.toString()}\n'
        }
        if (request.parallel) {
            text += '并发：允许分叉的步骤并行执行（输出 "parallel": true）\n'
        }
        if (!request.answers.isEmpty()) {
            text += '上一轮澄清回答：\n'
            for ((key, value) in request.answers) {
                text += '- ${key} = ${value}\n'
            }
        }
        text += '请按 schema 输出 JSON。'
        text
    }
}

// ---- LLM 输出的 DTO（f_data 的 JsonValue → DataObject） ----

@DataAssist[fields props]
public class OptionDto {
    public var label: String = ''
    public var value: String = ''

    public init() {
    }
}

@DataAssist[fields props]
public class QuestionDto {
    public var id: String = ''
    public var question: String = ''
    public var why: String = ''
    public var blocking: Bool = true
    public var defaultValue: String = ''
    public var options: ArrayList<OptionDto> = ArrayList<OptionDto>()

    public init() {
    }
}

@DataAssist[fields props]
public class AssumptionDto {
    public var field: String = ''
    public var value: String = ''
    public var reason: String = ''

    public init() {
    }
}

@DataAssist[fields props]
public class StepDto {
    public var id: String = ''
    public var kind: String = ''
    public var tool: String = ''
    public var model: String = ''
    public var system: String = ''
    public var input: String = ''
    public var args: HashMap<String, String> = HashMap<String, String>()
    public var async: String = 'auto'
    public var external: Bool = false

    public init() {
    }
}

@DataAssist[fields props]
public class PlanDto {
    public var status: String = 'planned'
    public var name: String = ''
    public var persona: String = ''
    /** 计划声明的技能标题（可空） */
    public var skills: ArrayList<String> = ArrayList<String>()
    public var notes: String = ''
    /** 模型判断可以并发时置 true */
    public var parallel: Bool = false
    public var round: Int64 = 0
    public var steps: ArrayList<StepDto> = ArrayList<StepDto>()
    /** 边：`[["fetch","sum"]]` */
    public var edges: ArrayList<ArrayList<String>> = ArrayList<ArrayList<String>>()
    public var questions: ArrayList<QuestionDto> = ArrayList<QuestionDto>()
    public var assumptions: ArrayList<AssumptionDto> = ArrayList<AssumptionDto>()

    public init() {
    }
}
