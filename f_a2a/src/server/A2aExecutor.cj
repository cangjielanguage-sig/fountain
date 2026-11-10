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

import fountain::f_a2a.model.*
import fountain::f_data.*

/**
 * 执行结果三选一：成功给文本、需要澄清、失败。
 *
 * 刻意不做成「抛异常」：A2A 里「代理处理失败」是**任务状态**，不是协议错误；
 * 用 JSON-RPC 的 `-32603` 会让客户端分不清「我调错了」与「代理没做成」。
 */
public class A2aExecutionResult {
    public let completed: Bool
    public let text: String
    public let needsInput: Bool
    public let rejected: Bool

    private init(completed: Bool, text: String, needsInput: Bool, rejected: Bool) {
        this.completed = completed
        this.text = text
        this.needsInput = needsInput
        this.rejected = rejected
    }

    /** 正常完成，携带一段文本产物 */
    public static func done(text: String): A2aExecutionResult {
        A2aExecutionResult(true, text, false, false)
    }

    /** 需要调用方补充信息（非终态） */
    public static func input(text: String): A2aExecutionResult {
        A2aExecutionResult(false, text, true, false)
    }

    /** 代理拒绝执行（视为失败，但可区分原因） */
    public static func reject(text: String): A2aExecutionResult {
        A2aExecutionResult(false, text, false, true)
    }

    public static func failed(text: String): A2aExecutionResult {
        A2aExecutionResult(false, text, false, false)
    }
}

/** 宿主实现的「代理」：拿到任务与消息，同步算完并给结果 */
public interface A2aExecutor {
    func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult
}
