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
package fountain::f_a2a.model

import std.collection.*

import fountain::f_data.*

/** 任务状态：`input-required` 是非终态，其余四个是终态 */
public class A2aStates {
    public static let SUBMITTED = 'submitted'
    public static let WORKING = 'working'
    public static let COMPLETED = 'completed'
    public static let FAILED = 'failed'
    public static let CANCELED = 'canceled'
    public static let INPUT_REQUIRED = 'input-required'

    private init() {
    }

    /** 终态判定：`input-required` 之后还能继续，不能算结束 */
    public static func isTerminal(state: String): Bool {
        state == COMPLETED || state == FAILED || state == CANCELED
    }

    public static func isValid(state: String): Bool {
        state == SUBMITTED || state == WORKING || isTerminal(state) || state == INPUT_REQUIRED
    }
}

/** A2A 业务错误码（`f_jsonrpc` 的 `-32020 ~ -32099` 段） */
public class A2aError {
    public static let TASK_NOT_FOUND: Int64 = -32020
    public static let TASK_NOT_CANCELABLE: Int64 = -32021
    public static let UNSUPPORTED: Int64 = -32022
    public static let CONTENT_TYPE_UNSUPPORTED: Int64 = -32023
    public static let TASK_REJECTED: Int64 = -32024

    private init() {
    }
}

/** 消息片段：`text` / `file`（url 引用，不内联字节）/ `data`（小段 JSON 字符串） */
public class A2aPart {
    public var kind: String = 'text'
    public var text: String = ''
    public var url: String = ''
    public var mimeType: String = ''
    public var data: String = ''

    public init(kind!: String = 'text', text!: String = '', url!: String = '', mimeType!: String = '',
                data!: String = '') {
        this.kind = kind
        this.text = text
        this.url = url
        this.mimeType = mimeType
        this.data = data
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('kind', kind)
        if (!text.isEmpty()) {
            obj.add('text', text)
        }
        if (!url.isEmpty()) {
            obj.add('url', url)
        }
        if (!mimeType.isEmpty()) {
            obj.add('mimeType', mimeType)
        }
        if (!data.isEmpty()) {
            obj.add('data', data)
        }
        obj
    }

    public static func isSupported(kind: String): Bool {
        kind == 'text' || kind == 'file' || kind == 'data'
    }
}

public class A2aMessage {
    public var role: String = 'user'
    public var messageId: String = ''
    public var taskId: String = ''
    public var contextId: String = ''
    public var parts: ArrayList<A2aPart> = ArrayList<A2aPart>()

    public init(role!: String = 'user', parts!: ArrayList<A2aPart> = ArrayList<A2aPart>(),
                messageId!: String = '', taskId!: String = '', contextId!: String = '') {
        this.role = role
        this.parts = parts
        this.messageId = messageId
        this.taskId = taskId
        this.contextId = contextId
    }

    /** 第一条文本片段（执行器与应用层读消息用） */
    public func text(): String {
        for (part in parts) {
            if (part.kind == 'text' && !part.text.isEmpty()) {
                return part.text
            }
        }
        ''
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('role', role)
        obj.add('messageId', messageId)
        if (!taskId.isEmpty()) {
            obj.add('taskId', taskId)
        }
        if (!contextId.isEmpty()) {
            obj.add('contextId', contextId)
        }
        let list = ArrayList<JsonValue>()
        for (part in parts) {
            list.add(part.toJson())
        }
        obj.add('parts', JsonArray(list: list))
        obj
    }
}

public class A2aArtifact {
    public var artifactId: String = ''
    public var name: String = ''
    public var parts: ArrayList<A2aPart> = ArrayList<A2aPart>()

    public init(artifactId!: String = '', name!: String = '',
                parts!: ArrayList<A2aPart> = ArrayList<A2aPart>()) {
        this.artifactId = artifactId
        this.name = name
        this.parts = parts
    }

    public static func textOf(artifactId: String, text: String): A2aArtifact {
        let parts = ArrayList<A2aPart>()
        parts.add(A2aPart(text: text))
        A2aArtifact(artifactId: artifactId, parts: parts)
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('artifactId', artifactId)
        if (!name.isEmpty()) {
            obj.add('name', name)
        }
        let list = ArrayList<JsonValue>()
        for (part in parts) {
            list.add(part.toJson())
        }
        obj.add('parts', JsonArray(list: list))
        obj
    }
}

/** 任务：状态机与产物都在这里；`statusMessage` 只在终态/需要澄清时有值 */
public class A2aTask {
    public var id: String = ''
    public var contextId: String = ''
    public var status: String = A2aStates.SUBMITTED
    public var statusMessage: ?A2aMessage = None
    public var artifacts: ArrayList<A2aArtifact> = ArrayList<A2aArtifact>()
    public var history: ArrayList<A2aMessage> = ArrayList<A2aMessage>()
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0

    public init(id!: String = '', contextId!: String = '') {
        this.id = id
        this.contextId = contextId
    }

    public func isTerminal(): Bool {
        A2aStates.isTerminal(status)
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('id', id)
        obj.add('contextId', contextId)
        obj.add('status', status)
        match (statusMessage) {
            case Some(message) => obj.add('statusMessage', message.toJson())
            case None => ()
        }
        let artifactsJson = ArrayList<JsonValue>()
        for (artifact in artifacts) {
            artifactsJson.add(artifact.toJson())
        }
        obj.add('artifacts', JsonArray(list: artifactsJson))
        let historyJson = ArrayList<JsonValue>()
        for (message in history) {
            historyJson.add(message.toJson())
        }
        obj.add('history', JsonArray(list: historyJson))
        obj.add('createdAt', createdAt)
        obj.add('updatedAt', updatedAt)
        obj
    }
}

/** 能力位：本实现 `streaming` 为真（SSE），`pushNotifications` 视注册表是否启用 */
public class A2aCapabilities {
    public var streaming: Bool = true
    public var pushNotifications: Bool = false

    public init(streaming!: Bool = true, pushNotifications!: Bool = false) {
        this.streaming = streaming
        this.pushNotifications = pushNotifications
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('streaming', streaming)
        obj.add('pushNotifications', pushNotifications)
        obj
    }
}

public class A2aSkill {
    public var id: String = ''
    public var name: String = ''
    public var description: String = ''
    public var tags: ArrayList<String> = ArrayList<String>()

    public init(id!: String, name!: String, description!: String = '',
                tags!: ArrayList<String> = ArrayList<String>()) {
        this.id = id
        this.name = name
        this.description = description
        this.tags = tags
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('id', id)
        obj.add('name', name)
        if (!description.isEmpty()) {
            obj.add('description', description)
        }
        let list = ArrayList<JsonValue>()
        for (tag in tags) {
            list.add(JsonString(tag))
        }
        obj.add('tags', JsonArray(list: list))
        obj
    }
}

/** 代理卡片：`/.well-known/agent.json` 的内容 */
public class A2aAgentCard {
    public var name: String = ''
    public var description: String = ''
    public var url: String = ''
    public var version: String = '1.0.0'
    public var capabilities: A2aCapabilities = A2aCapabilities()
    public var skills: ArrayList<A2aSkill> = ArrayList<A2aSkill>()
    public var extensions: String = ''

    public init(name!: String, description!: String = '', url!: String, version!: String = '1.0.0') {
        this.name = name
        this.description = description
        this.url = url
        this.version = version
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('name', name)
        obj.add('description', description)
        obj.add('url', url)
        obj.add('version', version)
        obj.add('capabilities', capabilities.toJson())
        let list = ArrayList<JsonValue>()
        for (skill in skills) {
            list.add(skill.toJson())
        }
        obj.add('skills', JsonArray(list: list))
        let inputs = ArrayList<JsonValue>()
        inputs.add(JsonString('text/plain'))
        obj.add('defaultInputModes', JsonArray(list: inputs))
        let outputs = ArrayList<JsonValue>()
        outputs.add(JsonString('text/plain'))
        obj.add('defaultOutputModes', JsonArray(list: outputs))
        if (!extensions.isEmpty()) {
            obj.add('x-a2a-extensions', extensions)
        }
        obj
    }

    public func json(): String {
        toJson().toString()
    }
}
