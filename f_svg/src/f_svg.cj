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
 * f_svg —— SVG 1.1 文档与渲染模块。
 *
 * M1 负责「把 SVG 文档讲清楚、改对、写回去」：值类型、类型化模型、解析/生成、安全过滤。
 * M2 在此基础上增加：
 *
 * - CSS 子集解析、选择器、级联、继承与计算样式（`CssStyleSheet` / `SvgStyleResolver`）；
 * - 形状/路径/描边包围盒与视口映射（`SvgGeometry` / `SvgViewport`）；
 * - CPU 软件光栅、描边轮廓、渐变、裁剪、蒙版与组透明度（`SvgRasterizer` 等）；
 * - 可插拔字体接口与内置 Hershey ASCII 文本（`SvgFont` / `SvgTextRenderer`）；
 * - 确定性 PNG 编码（`SvgPngEncoder`）；
 * - SMIL 时间轴与不修改原文档的采样快照（`SvgTimeline`）。
 *
 * M2 仍不内置 CJK 字体、不解码外部图像、不执行脚本，也不访问网络。
 * 底层 XML 全部交给 `fountain::f_xml`，本模块不实现第二套 XML 词法器。
 */
