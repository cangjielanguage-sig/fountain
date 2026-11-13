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

/**
 * 模型层的 JSON 读取：与 `toJson` 成对，保证往返一致。
 *
 * 容错策略：字段缺失走默认值；结构错误（不是对象/数组）返回 `None`，
 * 由调用方决定是「当成坏请求」还是「当成空对象」。
 */
public class A2aJson {
    private init() {
    }

    /** 任务副本：存储层返回给调用方的是副本，避免外部改到库里的对象 */
    public static func copyOf(task: A2aTask): A2aTask {
        match (taskOf(task.toJson())) {
            case Some(value) => value
            case None => A2aTask(id: task.id, contextId: task.contextId)
        }
    }

    public static func taskOf(value: JsonValue): ?A2aTask {
        let obj = match (asObject(value)) {
            case Some(value) => value
            case None => return None
        }
        let task = A2aTask(id: strOf(obj, 'id'), contextId: strOf(obj, 'contextId'))
        let status = strOf(obj, 'status')
        if (!status.isEmpty()) {
            task.status = status
        }
        task.statusMessage = match (obj.get('statusMessage')) {
            case Some(item) => messageOf(item)
            case None => None
        }
        task.artifacts = artifactsOf(obj, 'artifacts')
        task.history = messagesOf(obj, 'history')
        task.createdAt = intOf(obj, 'createdAt')
        task.updatedAt = intOf(obj, 'updatedAt')
        Some(task)
    }

    public static func taskOf(text: String): ?A2aTask {
        let value = try {
            JsonValue.fromStr(text)
        } catch (e: Exception) {
            return None
        }
        taskOf(value)
    }

    public static func messageOf(value: JsonValue): ?A2aMessage {
        let obj = match (asObject(value)) {
            case Some(item) => item
            case None => return None
        }
        let message = A2aMessage(role: strOf(obj, 'role'), messageId: strOf(obj, 'messageId'),
            taskId: strOf(obj, 'taskId'), contextId: strOf(obj, 'contextId'))
        message.parts = partsOf(obj, 'parts')
        Some(message)
    }

    public static func partOf(value: JsonValue): ?A2aPart {
        let obj = match (asObject(value)) {
            case Some(item) => item
            case None => return None
        }
        let kind = strOf(obj, 'kind')
        Some(A2aPart(kind: if (kind.isEmpty()) {
            'text'
        } else {
            kind
        }, text: strOf(obj, 'text'), url: strOf(obj, 'url'), mimeType: strOf(obj, 'mimeType'),
            data: strOf(obj, 'data')))
    }

    public static func artifactOf(value: JsonValue): ?A2aArtifact {
        let obj = match (asObject(value)) {
            case Some(item) => item
            case None => return None
        }
        let artifact = A2aArtifact(artifactId: strOf(obj, 'artifactId'), name: strOf(obj, 'name'))
        artifact.parts = partsOf(obj, 'parts')
        Some(artifact)
    }

    public static func partsOf(obj: JsonObject, key: String): ArrayList<A2aPart> {
        let result = ArrayList<A2aPart>()
        for (item in arrayOf(obj, key)) {
            match (partOf(item)) {
                case Some(part) => result.add(part)
                case None => ()
            }
        }
        result
    }

    public static func messagesOf(obj: JsonObject, key: String): ArrayList<A2aMessage> {
        let result = ArrayList<A2aMessage>()
        for (item in arrayOf(obj, key)) {
            match (messageOf(item)) {
                case Some(message) => result.add(message)
                case None => ()
            }
        }
        result
    }

    public static func artifactsOf(obj: JsonObject, key: String): ArrayList<A2aArtifact> {
        let result = ArrayList<A2aArtifact>()
        for (item in arrayOf(obj, key)) {
            match (artifactOf(item)) {
                case Some(artifact) => result.add(artifact)
                case None => ()
            }
        }
        result
    }

    public static func arrayOf(obj: JsonObject, key: String): ArrayList<JsonValue> {
        match (obj.get(key)) {
            case Some(value) =>
                let array = try {
                    value.asArray()
                } catch (e: Exception) {
                    return ArrayList<JsonValue>()
                }
                let result = ArrayList<JsonValue>()
                for (index in 0..array.size) {
                    result.add(array[index])
                }
                result
            case None => ArrayList<JsonValue>()
        }
    }

    public static func strOf(obj: JsonObject, key: String): String {
        match (obj.get(key)) {
            case Some(value) =>
                let text = try {
                    value.asString()
                } catch (e: Exception) {
                    return ''
                }
                text.value
            case None => ''
        }
    }

    /** 整数没有专用取值器：走文本再解析（本项目 `JsonValue` 没有 `asInt64`） */
    public static func intOf(obj: JsonObject, key: String): Int64 {
        match (obj.get(key)) {
            case Some(value) => match (Int64.tryParse(value.toString())) {
                case Some(number) => number
                case None => 0
            }
            case None => 0
        }
    }

    public static func asObject(value: JsonValue): ?JsonObject {
        try {
            Some(value.asObject())
        } catch (e: Exception) {
            None
        }
    }
}
