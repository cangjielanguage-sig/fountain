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

import std.collection.*

/** 绘制层。 */
public enum SvgPaintLayer <: Equatable<SvgPaintLayer> & ToString {
    | Fill
    | Stroke
    | Markers

    public operator func ==(that: SvgPaintLayer): Bool {
        match ((this, that)) {
            case (Fill, Fill) => true
            case (Stroke, Stroke) => true
            case (Markers, Markers) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Fill => "fill"
            case Stroke => "stroke"
            case Markers => "markers"
        }
    }
}

/** `fill` / `stroke` / `markers` 的无重复有序子集。 */
public class SvgPaintOrder <: ToString {
    public let layers: Array<SvgPaintLayer>

    private init(layers: Array<SvgPaintLayer>) {
        this.layers = layers
    }

    /** 缺省顺序。 */
    public static func defaultOrder(): SvgPaintOrder {
        SvgPaintOrder([SvgPaintLayer.Fill, SvgPaintLayer.Stroke, SvgPaintLayer.Markers])
    }

    public static func parse(text: String): SvgPaintOrder {
        SvgPaintOrder.parse(text, ArrayList<String>())
    }

    /** 解析并记录重复 / 未知关键字告警。 */
    internal static func parse(text: String, warnings: ArrayList<String>): SvgPaintOrder {
        let tokens = splitCssWhitespaceWords(text.trimAscii().toAsciiLower())
        let layers = ArrayList<SvgPaintLayer>()
        for (token in tokens) {
            match (paintLayerFromName(token)) {
                case Some(layer) =>
                    if (containsPaintLayer(layers, layer)) {
                        warnings.add("paint-order 重复层「${token}」，已忽略重复项")
                    } else {
                        layers.add(layer)
                    }
                case None => warnings.add("paint-order 忽略未知关键字「${token}」")
            }
        }
        for (layer in [SvgPaintLayer.Fill, SvgPaintLayer.Stroke, SvgPaintLayer.Markers]) {
            if (!containsPaintLayer(layers, layer)) {
                layers.add(layer)
            }
        }
        SvgPaintOrder(layers.toArray())
    }

    public func toString(): String {
        let out = ArrayList<String>()
        for (layer in this.layers) {
            out.add(layer.toString())
        }
        joinCssStrings(out, " ")
    }
}

/** 关键字到层的映射；未知返回 `None`。 */
internal func paintLayerFromName(name: String): ?SvgPaintLayer {
    match (name.trimAscii().toAsciiLower()) {
        case "fill" => Some(SvgPaintLayer.Fill)
        case "stroke" => Some(SvgPaintLayer.Stroke)
        case "markers" => Some(SvgPaintLayer.Markers)
        case _ => None
    }
}

private func containsPaintLayer(layers: ArrayList<SvgPaintLayer>, layer: SvgPaintLayer): Bool {
    for (item in layers) {
        if (item == layer) {
            return true
        }
    }
    false
}

/**
 * `paint-order` 的字符串归一化：去重、按默认顺序补齐缺失层。
 *
 * 未知关键字逐项丢弃并记 warning，合法项保留；空白值返回 `None`。
 */
internal func normalizeCssPaintOrder(text: String, warnings: ArrayList<String>): ?String {
    let tokens = splitCssWhitespaceWords(text.toAsciiLower())
    if (tokens.size == 0) {
        return None
    }
    SvgPaintOrder.parse(text, warnings).toString()
}

/** 计算样式值转回绘制层序列；非法值返回缺省顺序。 */
internal func svgPaintOrderOf(value: ?String): SvgPaintOrder {
    match (value) {
        case Some(text) => SvgPaintOrder.parse(text)
        case None => SvgPaintOrder.defaultOrder()
    }
}
