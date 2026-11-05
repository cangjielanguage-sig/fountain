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
package fountain::f_svg

/**
 * f_svg —— SVG 1.1 静态文档模块。
 *
 * 设计见 `doc/f_svg模块设计.md`。模块只负责「把 SVG 文档讲清楚、改对、写回去」：
 * 值类型、类型化文档模型、解析与生成、安全过滤。不渲染、不做 CSS 级联、不做动画。
 *
 * 底层 XML 全部交给 `fountain::f_xml`，本模块不实现第二套 XML 词法器。
 */
