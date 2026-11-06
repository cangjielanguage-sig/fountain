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

/** SVG 标签到模型类型的表驱动映射。 */
public class SvgTag {
    /** 已知标签创建对应模型实例；未知返回 `None`。 */
    public static func create(tag: String): ?SvgElement {
        match (tag) {
            case "svg" => Some(SvgRoot())
            case "rect" => Some(SvgRect())
            case "circle" => Some(SvgCircle())
            case "ellipse" => Some(SvgEllipse())
            case "line" => Some(SvgLine())
            case "polyline" => Some(SvgPolyline())
            case "polygon" => Some(SvgPolygon())
            case "path" => Some(SvgPath())
            case "text" => Some(SvgText())
            case "tspan" => Some(SvgTspan())
            case "textPath" => Some(SvgTextPath())
            case "linearGradient" => Some(SvgLinearGradient())
            case "radialGradient" => Some(SvgRadialGradient())
            case "stop" => Some(SvgStop())
            case "use" => Some(SvgUse())
            case "image" => Some(SvgImage())
            case "filter" => Some(SvgFilter())
            case "pattern" => Some(SvgPattern())
            case "marker" => Some(SvgMarker())
            case "feGaussianBlur" => Some(SvgFeGaussianBlur())
            case "feOffset" => Some(SvgFeOffset())
            case "feFlood" => Some(SvgFeFlood())
            case "feBlend" => Some(SvgFeBlend())
            case "feComposite" => Some(SvgFeComposite())
            case "feMerge" => Some(SvgFeMerge())
            case "feMergeNode" => Some(SvgFeMergeNode())
            case "feColorMatrix" => Some(SvgFeColorMatrix())
            case "feTile" => Some(SvgFeTile())
            case "feComponentTransfer" => Some(SvgFeComponentTransfer())
            case "feFuncR" => Some(SvgFeFuncR())
            case "feFuncG" => Some(SvgFeFuncG())
            case "feFuncB" => Some(SvgFeFuncB())
            case "feFuncA" => Some(SvgFeFuncA())
            case "feMorphology" => Some(SvgFeMorphology())
            case "feConvolveMatrix" => Some(SvgFeConvolveMatrix())
            case "feTurbulence" => Some(SvgFeTurbulence())
            case "feDisplacementMap" => Some(SvgFeDisplacementMap())
            case "feImage" => Some(SvgFeImage())
            case "feDiffuseLighting" => Some(SvgFeDiffuseLighting())
            case "feSpecularLighting" => Some(SvgFeSpecularLighting())
            case "feDistantLight" => Some(SvgFeDistantLight())
            case "fePointLight" => Some(SvgFePointLight())
            case "feSpotLight" => Some(SvgFeSpotLight())
            case "view" => Some(SvgView())
            case "style" | "title" | "desc" | "metadata" => Some(SvgElement(tag))
            case "g" | "defs" | "symbol" | "clipPath" | "mask" | "switch" | "a" |
                "foreignObject" =>
                match (SvgContainerKind.fromTag(tag)) {
                    case Some(kind) => Some(SvgContainer(kind))
                    case None => None
                }
            case _ => None
        }
    }

    public static func isKnown(tag: String): Bool {
        match (tag) {
            case "svg" | "rect" | "circle" | "ellipse" | "line" | "polyline" | "polygon" | "path" |
                "text" | "tspan" | "textPath" | "linearGradient" | "radialGradient" | "stop" | "use" |
                "image" | "g" | "defs" | "symbol" | "clipPath" | "mask" |
                "switch" | "a" | "foreignObject" | "style" | "title" | "desc" | "metadata" |
                "filter" | "pattern" | "marker" | "feGaussianBlur" | "feOffset" | "feFlood" |
                "feBlend" | "feComposite" | "feMerge" | "feMergeNode" | "feColorMatrix" |
                "feTile" | "feComponentTransfer" | "feFuncR" | "feFuncG" | "feFuncB" |
                "feFuncA" | "feMorphology" | "feConvolveMatrix" | "feTurbulence" |
                "feDisplacementMap" | "feImage" | "feDiffuseLighting" | "feSpecularLighting" |
                "feDistantLight" | "fePointLight" | "feSpotLight" | "view" => true
            case _ => false
        }
    }
}
