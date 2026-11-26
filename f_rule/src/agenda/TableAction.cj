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
package fountain::f_rule.agenda

/**
 * `TableAction` 已下沉到 `rule` 包（与 `RuleAction` 接口同包，避免包循环）。
 *
 * 这里做公开重导出，保持 `fountain::f_rule.agenda.TableAction` 的历史导入路径不变。
 */
public import fountain::f_rule.rule.TableAction
