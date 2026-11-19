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
package fountain::f_llm.llm

/**
 * 门面的调用钩子：成功 / 可重试失败各一次，参数是 `conf.id`。
 *
 * 放在这里而不是让门面直接依赖熔断器：`LLM.chat(candidates, …)` 是纯函数式入口，
 * 编排层（`chatByName`）用钩子把状态记到 `CircuitBreaker` 上，两边互不绑定。
 */
public class LLMHooks {
    public let onSuccess: (Int64) -> Unit
    public let onRetryableFailure: (Int64) -> Unit

    public init(
        onSuccess!: (Int64) -> Unit = {_ => ()},
        onRetryableFailure!: (Int64) -> Unit = {_ => ()}
    ){
        this.onSuccess = onSuccess
        this.onRetryableFailure = onRetryableFailure
    }
}
