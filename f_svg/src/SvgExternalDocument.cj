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
internal let SVG_EXTERNAL_MAX_DEPTH: Int64 = 4

/** 外部文档嵌套深度是否仍可用；达到 4 层后拒绝。 */
internal func svgExternalDepthAllows(depth: Int64): Bool {
    depth >= 0 && depth < SVG_EXTERNAL_MAX_DEPTH
}
