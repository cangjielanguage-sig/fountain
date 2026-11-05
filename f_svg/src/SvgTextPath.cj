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

/** `textPath` 元素。 */
public class SvgTextPath <: SvgTextElement {
    private let startOffsetCache = SvgValueCache<SvgLength>()

    public init(href!: ?String = None, startOffset!: ?SvgLength = None) {
        super("textPath")
        this.href = href
        this.startOffset = startOffset
    }

    /** 读取同时接受 `href` 与 `xlink:href`，写入默认落在 `xlink:href`。 */
    public mut prop href: ?String {
        get() {
            readSvgHref(this)
        }
        set(value) {
            writeSvgHref(this, value)
        }
    }

    public mut prop startOffset: ?SvgLength {
        get() {
            this.startOffsetCache.get(this.attributesVersion, {=> readLength(this, "startOffset")})
        }
        set(value) {
            writeLength(this, "startOffset", value)
        }
    }
}
