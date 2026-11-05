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


/** `rect` 元素。 */
public class SvgRect <: SvgShape {
    private let xCache = SvgValueCache<SvgLength>()
    private let yCache = SvgValueCache<SvgLength>()
    private let widthCache = SvgValueCache<SvgLength>()
    private let heightCache = SvgValueCache<SvgLength>()
    private let rxCache = SvgValueCache<SvgLength>()
    private let ryCache = SvgValueCache<SvgLength>()

    public init(
        x!: ?SvgLength = None,
        y!: ?SvgLength = None,
        width!: ?SvgLength = None,
        height!: ?SvgLength = None,
        rx!: ?SvgLength = None,
        ry!: ?SvgLength = None
    ) {
        super("rect")
        this.x = x
        this.y = y
        this.width = width
        this.height = height
        this.rx = rx
        this.ry = ry
    }

    public mut prop x: ?SvgLength {
        get() {
            this.xCache.get(this.attributesVersion, {=> readLength(this, "x")})
        }
        set(value) {
            writeLength(this, "x", value)
        }
    }

    public mut prop y: ?SvgLength {
        get() {
            this.yCache.get(this.attributesVersion, {=> readLength(this, "y")})
        }
        set(value) {
            writeLength(this, "y", value)
        }
    }

    public mut prop width: ?SvgLength {
        get() {
            this.widthCache.get(this.attributesVersion, {=> readLength(this, "width")})
        }
        set(value) {
            writeLength(this, "width", value)
        }
    }

    public mut prop height: ?SvgLength {
        get() {
            this.heightCache.get(this.attributesVersion, {=> readLength(this, "height")})
        }
        set(value) {
            writeLength(this, "height", value)
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
