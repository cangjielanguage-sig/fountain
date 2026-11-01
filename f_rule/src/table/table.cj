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
package fountain::f_rule.table

/**
 * 决策表（`doc/07-decision-table.md`）。
 *
 * 模型、命中策略、条件/输出单元格、编译与执行、CSV 与 XLSX 两种载体
 * （`CsvTableParser` / `XlsxTableParser`）均已落地；XLSX 另有流式入口
 * `XlsxTableParser.stream`，供 10 万行级大表使用。
 */
