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

import std.math.*

/** `radialGradient` 元素。 */
public class SvgRadialGradient <: SvgGradient {
    private let cxCache = SvgValueCache<SvgLength>()
    private let cyCache = SvgValueCache<SvgLength>()
    private let rCache = SvgValueCache<SvgLength>()
    private let fxCache = SvgValueCache<SvgLength>()
    private let fyCache = SvgValueCache<SvgLength>()

    public init(
        cx!: ?SvgLength = None,
        cy!: ?SvgLength = None,
        r!: ?SvgLength = None,
        fx!: ?SvgLength = None,
        fy!: ?SvgLength = None
    ) {
        super("radialGradient")
        this.cx = cx
        this.cy = cy
        this.r = r
        this.fx = fx
        this.fy = fy
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

    public mut prop r: ?SvgLength {
        get() {
            this.rCache.get(this.attributesVersion, {=> readLength(this, "r")})
        }
        set(value) {
            writeLength(this, "r", value)
        }
    }

    public mut prop fx: ?SvgLength {
        get() {
            this.fxCache.get(this.attributesVersion, {=> readLength(this, "fx")})
        }
        set(value) {
            writeLength(this, "fx", value)
        }
    }

    public mut prop fy: ?SvgLength {
        get() {
            this.fyCache.get(this.attributesVersion, {=> readLength(this, "fy")})
        }
        set(value) {
            writeLength(this, "fy", value)
        }
    }
}
