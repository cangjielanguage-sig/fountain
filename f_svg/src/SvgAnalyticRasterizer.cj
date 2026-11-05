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

/** 抗锯齿档位。 */
public enum SvgAntiAliasMode <: Equatable<SvgAntiAliasMode> & ToString {
    /** 每像素超采样，覆盖率由命中数平均（默认）。 */
    | Supersample
    /** 解析覆盖率，`samplesPerPixel` 不参与计算。 */
    | Analytic

    public operator func ==(that: SvgAntiAliasMode): Bool {
        match ((this, that)) {
            case (Supersample, Supersample) => true
            case (Analytic, Analytic) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Supersample => "Supersample"
            case Analytic => "Analytic"
        }
    }
}

// TODO(M3-9): 解析覆盖率光栅化。
