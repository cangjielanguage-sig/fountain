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

/** 视图状态：缩放与平移；渲染时插在根视口矩阵之后。 */
public class SvgViewState {
    public var currentScale: Float64
    public var currentTranslate: SvgPoint

    public init(currentScale!: Float64 = 1.0, currentTranslate!: SvgPoint = SvgPoint(0.0, 0.0)) {
        this.currentScale = currentScale
        this.currentTranslate = currentTranslate
    }

    public func toMatrix(): SvgMatrix {
        SvgMatrix.translate(this.currentTranslate.x, this.currentTranslate.y)
            .multiply(SvgMatrix.scale(this.currentScale, this.currentScale))
    }
}
