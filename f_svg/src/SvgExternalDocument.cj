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

/** 外部 SVG 文档提供者；库内不联网、不读文件。 */
public interface SvgExternalDocumentProvider {
    func resolveHref(href: String): ?Array<Byte>
}

/** 外部文档安全上限。 */
internal let SVG_EXTERNAL_MAX_BYTES: Int64 = 16 * 1024 * 1024

/**
 * 外部文档展开深度的防御上限。
 *
 * 规格语义为“外部文档不递归加载”：provider 返回的文档以
 * `allowExternalReferences: false` 解析，第二层外部引用被移除并 warning。
 * 该常量仅保留为异常路径的防御性检查，不参与正常渲染流程。
 */
internal let SVG_EXTERNAL_MAX_DEPTH: Int64 = 4

/** 外部文档嵌套深度是否仍可用；正常流程下不会触发。 */
internal func svgExternalDepthAllows(depth: Int64): Bool {
    depth >= 0 && depth < SVG_EXTERNAL_MAX_DEPTH
}

/** 单条 use 链允许的最大展开层数；与普通容器 / 嵌套 svg 深度无关。 */
internal let SVG_USE_MAX_DEPTH: Int64 = 64
