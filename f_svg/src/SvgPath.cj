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

/** `path` 元素。 */
public class SvgPath <: SvgShape {
    private let dCache = SvgValueCache<SvgPathData>()

    public init(d!: ?SvgPathData = None) {
        super("path")
        this.d = d
    }

    /** 路径总弧长；`d` 缺失或为空时返回 0。 */
    public func getTotalLength(): Float64 {
        match (this.d) {
            case Some(data) => data.totalLength()
            case None => 0.0
        }
    }

    /** 弧长处的点；负值与超长分别钳制到起点与终点。 */
    public func getPointAtLength(distance: Float64): SvgPoint {
        match (this.d) {
            case Some(data) => data.pointAtLength(distance)
            case None => SvgPoint(0.0, 0.0)
        }
    }

    public mut prop d: ?SvgPathData {
        get() {
            this.dCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("d")) {
                        case Some(text) => SvgPathData.tryParse(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(data) => this.setAttr("d", data.toString())
                case None => this.removeAttr("d")
            }
        }
    }
}
