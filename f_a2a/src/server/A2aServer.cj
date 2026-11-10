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
package fountain::f_a2a.server

import std.collection.*
import std.sync.*
import std.time.*

import fountain::f_a2a.model.*
import fountain::f_data.*
import fountain::f_jsonrpc.base.*
import fountain::f_jsonrpc.server.*
import fountain::f_log.*

/**
 * A2A 服务端：把三个方法注册进 `JsonRpcRegistry`，任务状态机与存储留在本模块。
 *
 * 传输、路由、鉴权、线程池全部由 `f_jsonrpc` / `f_mvc` 提供，本类只做协议语义。
 */
public class A2aServer {
    public let card: A2aAgentCard
    private let executor: A2aExecutor
    private let store: A2aTaskStore
    private let mutex = Mutex()
    private var registered = false
    private var seq: Int64 = 0
    /** 注册次数（测试用：证明幂等） */
    private var registrations: Int64 = 0

    public init(card: A2aAgentCard, executor: A2aExecutor,
                store!: A2aTaskStore = InMemoryA2aTaskStore()) {
        this.card = card
        this.executor = executor
        this.store = store
    }

    /** 注册三个方法；重复调用不会重复注册 */
    public func register(): Unit {
        synchronized(mutex) {
            if (registered) {
                return
            }
            registered = true
        }
        safeRegister(JsonRpcMethodMeta(name: METHOD_SEND, handler: {_, params => send(unwrap(params))},
            description: 'A2A: 发送消息并同步执行'))
        safeRegister(JsonRpcMethodMeta(name: METHOD_GET, handler: {_, params => getTask(unwrap(params))},
            description: 'A2A: 查询任务'))
        safeRegister(JsonRpcMethodMeta(name: METHOD_CANCEL,
            handler: {_, params => cancelTask(unwrap(params))}, description: 'A2A: 取消任务'))
        synchronized(mutex) {
            registrations = 3
        }
    }

    /** 同名方法已存在时忽略：同一进程里多实例共存不该让第二个实例注册失败 */
    private func safeRegister(meta: JsonRpcMethodMeta): Unit {
        try {
            JsonRpcRegistry.register(meta)
        } catch (e: JsonRpcException) {
            ()
        }
    }

    public func registrationCount(): Int64 {
        synchronized(mutex) {
            registrations
        }
    }

    /** `a2a.message.send` */
    public func send(params: JsonValue): JsonValue {
        let message = parseMessage(params)
        let task = A2aTask(id: nextId(), contextId: contextOf(message))
        task.status = A2aStates.WORKING
        task.createdAt = now()
        task.updatedAt = task.createdAt
        task.history.add(message)

        let result = try {
            executor.execute(task, message)
        } catch (e: Exception) {
            // 执行器抛异常 → 任务失败（不是协议错误），原因写进 statusMessage，同时留一条 warn
            LoggerFactory.getLogger<A2aServer>().warn('a2a executor failed: ${e.message}')
            A2aExecutionResult.failed('executor failed: ${e.message}')
        }
        apply(result, task)
        task.updatedAt = now()
        store.save(task)
        task.toJson()
    }

    /** `a2a.tasks.get` */
    public func getTask(params: JsonValue): JsonValue {
        let id = strOf(asObject(params), 'id')
        match (store.get(id)) {
            case Some(task) => task.toJson()
            case None => throw JsonRpcException(A2aError.TASK_NOT_FOUND, 'task not found: ${id}',
                data: JsonString(id))
        }
    }

    /** `a2a.tasks.cancel` */
    public func cancelTask(params: JsonValue): JsonValue {
        let id = strOf(asObject(params), 'id')
        let task = match (store.get(id)) {
            case Some(value) => value
            case None => throw JsonRpcException(A2aError.TASK_NOT_FOUND, 'task not found: ${id}',
                data: JsonString(id))
        }
        if (task.isTerminal()) {
            throw JsonRpcException(A2aError.TASK_NOT_CANCELABLE, 'task is already ${task.status}',
                data: JsonString(id))
        }
        task.status = A2aStates.CANCELED
        task.statusMessage = agentMessage('canceled by client')
        task.updatedAt = now()
        store.save(task)
        task.toJson()
    }

    /** 已注册的三个方法名（测试与文档用） */
    public static let METHOD_SEND = 'a2a.message.send'
    public static let METHOD_GET = 'a2a.tasks.get'
    public static let METHOD_CANCEL = 'a2a.tasks.cancel'

    private func apply(result: A2aExecutionResult, task: A2aTask): Unit {
        if (result.completed) {
            task.status = A2aStates.COMPLETED
            task.artifacts.add(A2aArtifact.textOf('${task.id}-a1', result.text))
            task.history.add(agentMessage(result.text))
        } else if (result.needsInput) {
            task.status = A2aStates.INPUT_REQUIRED
            task.statusMessage = agentMessage(result.text)
            task.history.add(agentMessage(result.text))
        } else if (result.rejected) {
            task.status = A2aStates.FAILED
            task.statusMessage = agentMessage('rejected: ${result.text}')
        } else {
            task.status = A2aStates.FAILED
            task.statusMessage = agentMessage(result.text)
        }
    }

    private func parseMessage(params: JsonValue): A2aMessage {
        let obj = asObject(params)
        let raw = match (obj.get('message')) {
            case Some(value) => value
            case None => throw JsonRpcException(INVALID_PARAMS, 'a2a.message.send requires message')
        }
        let message = match (A2aJson.messageOf(raw)) {
            case Some(value) => value
            case None => throw JsonRpcException(INVALID_PARAMS, 'message must be an object')
        }
        if (message.parts.isEmpty()) {
            throw JsonRpcException(INVALID_PARAMS, 'message requires at least one part')
        }
        for (part in message.parts) {
            if (!A2aPart.isSupported(part.kind)) {
                throw JsonRpcException(A2aError.CONTENT_TYPE_UNSUPPORTED,
                    'unsupported part kind: ${part.kind}', data: JsonString(part.kind))
            }
        }
        if (message.messageId.isEmpty()) {
            message.messageId = 'msg-${nextSeq()}'
        }
        message
    }

    private func contextOf(message: A2aMessage): String {
        if (message.contextId.isEmpty()) {
            'ctx-${nextSeq()}'
        } else {
            message.contextId
        }
    }

    /** 注册的函数收到的是 `?JsonValue`：没传参数时当成空对象，交给各方法给出可读错误 */
    private static func unwrap(params: ?JsonValue): JsonValue {
        match (params) {
            case Some(value) => value
            case None => JsonObject()
        }
    }

    private func nextId(): String {
        'task-${now()}-${nextSeq()}'
    }

    private func nextSeq(): Int64 {
        synchronized(mutex) {
            seq++
            seq
        }
    }

    private static func now(): Int64 {
        DateTime.now().toUnixTimeStamp().toSeconds()
    }

    private static func agentMessage(text: String): A2aMessage {
        let parts = ArrayList<A2aPart>()
        parts.add(A2aPart(text: text))
        A2aMessage(role: 'agent', parts: parts, messageId: 'reply-${text.size}')
    }

    private static func asObject(value: JsonValue): JsonObject {
        match (A2aJson.asObject(value)) {
            case Some(obj) => obj
            case None => JsonObject()
        }
    }

    private static func strOf(obj: JsonObject, key: String): String {
        A2aJson.strOf(obj, key)
    }

    private static let INVALID_PARAMS: Int64 = -32602
}
