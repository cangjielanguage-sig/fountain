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
package fountain::f_rule.rule

/**
 * 规则模型与构建期校验（`doc/02-fact-model.md` §8、`doc/08-api.md`）。
 *
 * M0 只建包骨架；`Rule` / `RuleBuilder` / `Bindings` / `RuleSet`（模型侧）/ `Validator`
 * 在 M1 落地；面向应用的 `RuleSetBuilder` 放根包，避免循环依赖。
 */
