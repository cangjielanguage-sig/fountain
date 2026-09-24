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
package fountain::f_llm.constant

/**
 * - ⏸️ 等待用户提供信息
 * - ◯ 尚未开始
 * - 🟡 存在风险，需要用户确认
 * - ✅ 成功完成
 * - ❌ 失败结束
 * - 🔄 进行中
 * - 🗑️ 删除
 */
public type TodoStatus = String
public const TODO_STATUS_WAITING = "⏸️"
public const TODO_STATUS_PENDING = "◯"
public const TODO_STATUS_WARNING = "🟡"
public const TODO_STATUS_SUCCESS = "✅"
public const TODO_STATUS_FAILED = "❌"
public const TODO_STATUS_RUNNING = "🔄"