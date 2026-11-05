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

/** `linearGradient` 元素。 */
public class SvgLinearGradient <: SvgGradient {
    private let x1Cache = SvgValueCache<SvgLength>()
    private let y1Cache = SvgValueCache<SvgLength>()
    private let x2Cache = SvgValueCache<SvgLength>()
    private let y2Cache = SvgValueCache<SvgLength>()

    public init(
        x1!: ?SvgLength = None,
        y1!: ?SvgLength = None,
        x2!: ?SvgLength = None,
        y2!: ?SvgLength = None
    ) {
        super("linearGradient")
        this.x1 = x1
        this.y1 = y1
        this.x2 = x2
        this.y2 = y2
    }

    public mut prop x1: ?SvgLength {
        get() {
            this.x1Cache.get(this.attributesVersion, {=> readLength(this, "x1")})
        }
        set(value) {
            writeLength(this, "x1", value)
        }
    }

    public mut prop y1: ?SvgLength {
        get() {
            this.y1Cache.get(this.attributesVersion, {=> readLength(this, "y1")})
        }
        set(value) {
            writeLength(this, "y1", value)
        }
    }

    public mut prop x2: ?SvgLength {
        get() {
            this.x2Cache.get(this.attributesVersion, {=> readLength(this, "x2")})
        }
        set(value) {
            writeLength(this, "x2", value)
        }
    }

    public mut prop y2: ?SvgLength {
        get() {
            this.y2Cache.get(this.attributesVersion, {=> readLength(this, "y2")})
        }
        set(value) {
            writeLength(this, "y2", value)
        }
    }
}
