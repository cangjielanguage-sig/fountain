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

/** `shape-rendering`。 */
public enum SvgShapeRendering <: Equatable<SvgShapeRendering> & ToString {
    | Auto
    | OptimizeSpeed
    | CrispEdges
    | GeometricPrecision

    public operator func ==(that: SvgShapeRendering): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (OptimizeSpeed, OptimizeSpeed) => true
            case (CrispEdges, CrispEdges) => true
            case (GeometricPrecision, GeometricPrecision) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case OptimizeSpeed => "optimizeSpeed"
            case CrispEdges => "crispEdges"
            case GeometricPrecision => "geometricPrecision"
        }
    }

    internal static func fromName(name: String): ?SvgShapeRendering {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "optimizespeed" => Some(OptimizeSpeed)
            case "crispedges" => Some(CrispEdges)
            case "geometricprecision" => Some(GeometricPrecision)
            case _ => Option<SvgShapeRendering>.None
        }
    }
}

/** `text-rendering`。 */
public enum SvgTextRendering <: Equatable<SvgTextRendering> & ToString {
    | Auto
    | OptimizeSpeed
    | OptimizeLegibility
    | GeometricPrecision

    public operator func ==(that: SvgTextRendering): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (OptimizeSpeed, OptimizeSpeed) => true
            case (OptimizeLegibility, OptimizeLegibility) => true
            case (GeometricPrecision, GeometricPrecision) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case OptimizeSpeed => "optimizeSpeed"
            case OptimizeLegibility => "optimizeLegibility"
            case GeometricPrecision => "geometricPrecision"
        }
    }

    internal static func fromName(name: String): ?SvgTextRendering {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "optimizespeed" => Some(OptimizeSpeed)
            case "optimizelegibility" => Some(OptimizeLegibility)
            case "geometricprecision" => Some(GeometricPrecision)
            case _ => Option<SvgTextRendering>.None
        }
    }
}

/** `color-rendering`；M6 映射为渐变量化级数。 */
public enum SvgColorRendering <: Equatable<SvgColorRendering> & ToString {
    | Auto
    | OptimizeSpeed
    | OptimizeQuality

    public operator func ==(that: SvgColorRendering): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (OptimizeSpeed, OptimizeSpeed) => true
            case (OptimizeQuality, OptimizeQuality) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case OptimizeSpeed => "optimizeSpeed"
            case OptimizeQuality => "optimizeQuality"
        }
    }

    internal static func fromName(name: String): ?SvgColorRendering {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "optimizespeed" => Some(OptimizeSpeed)
            case "optimizequality" => Some(OptimizeQuality)
            case _ => Option<SvgColorRendering>.None
        }
    }

    /** `auto` 为解析式（0），其余返回量化级数。 */
    internal func quantizeSteps(): Int64 {
        match (this) {
            case Auto => 0
            case OptimizeSpeed => 128
            case OptimizeQuality => 512
        }
    }
}

/** `color-interpolation`；`auto` 与 `sRGB` 都走 sRGB 插值。 */
public enum SvgColorInterpolation <: Equatable<SvgColorInterpolation> & ToString {
    | Auto
    | Srgb
    | LinearRgb

    public operator func ==(that: SvgColorInterpolation): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (Srgb, Srgb) => true
            case (LinearRgb, LinearRgb) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case Srgb => "sRGB"
            case LinearRgb => "linearRGB"
        }
    }

    internal static func fromName(name: String): ?SvgColorInterpolation {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "srgb" => Some(Srgb)
            case "linearrgb" => Some(LinearRgb)
            case _ => Option<SvgColorInterpolation>.None
        }
    }

    internal func isLinear(): Bool {
        match (this) {
            case LinearRgb => true
            case _ => false
        }
    }
}
