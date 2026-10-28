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
package fountain::f_xml

/**
 * f_xml —— 通用 XML 1.0 解析与生成模块。
 *
 * 设计见 `doc/f_xml模块设计.md`。模块不绑定任何业务格式：
 * 提供流式事件解析（推 / 拉）、DOM 构建、命名空间、DTD 内部实体与序列化。
 */
