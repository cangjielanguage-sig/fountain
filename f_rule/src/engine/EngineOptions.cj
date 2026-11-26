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
package fountain::f_rule.engine

/**
 * 引擎运行期选项（`doc/08-api.md` §8）。
 *
 * 当前只落地 `expressionTimeout`；其余会话策略项保留在文档中，待对应里程碑接入。
 */
public class EngineOptions {
    /** 单次表达式求值超时；超时按 `Unknown` 处理。 */
    public var expressionTimeout: Duration

    public init(expressionTimeout!: Duration = Duration.millisecond * 50) {
        this.expressionTimeout = expressionTimeout
    }
}
