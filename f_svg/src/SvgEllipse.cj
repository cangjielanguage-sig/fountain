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

/** `ellipse` 元素。 */
public class SvgEllipse <: SvgShape {
    private let cxCache = SvgValueCache<SvgLength>()
    private let cyCache = SvgValueCache<SvgLength>()
    private let rxCache = SvgValueCache<SvgLength>()
    private let ryCache = SvgValueCache<SvgLength>()

    public init(
        cx!: ?SvgLength = None,
        cy!: ?SvgLength = None,
        rx!: ?SvgLength = None,
        ry!: ?SvgLength = None
    ) {
        super("ellipse")
        this.cx = cx
        this.cy = cy
        this.rx = rx
        this.ry = ry
    }

    public mut prop cx: ?SvgLength {
        get() {
            this.cxCache.get(this.attributesVersion, {=> readLength(this, "cx")})
        }
        set(value) {
            writeLength(this, "cx", value)
        }
    }

    public mut prop cy: ?SvgLength {
        get() {
            this.cyCache.get(this.attributesVersion, {=> readLength(this, "cy")})
        }
        set(value) {
            writeLength(this, "cy", value)
        }
    }

    public mut prop rx: ?SvgLength {
        get() {
            this.rxCache.get(this.attributesVersion, {=> readLength(this, "rx")})
        }
        set(value) {
            writeLength(this, "rx", value)
        }
    }

    public mut prop ry: ?SvgLength {
        get() {
            this.ryCache.get(this.attributesVersion, {=> readLength(this, "ry")})
        }
        set(value) {
            writeLength(this, "ry", value)
        }
    }
}
