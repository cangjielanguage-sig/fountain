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

private let CSS_PAINT_LAYER_NAMES: Array<String> = ["fill", "stroke", "markers"]

/**
 * `paint-order` 的字符串归一化：去重、按默认顺序补齐缺失层。
 *
 * 未知关键字使整条声明无效（返回 `None`，由调用方回退初始值并告警）。
 */
internal func normalizeCssPaintOrder(text: String): ?String {
    let tokens = splitCssWhitespaceWords(text.toAsciiLower())
    if (tokens.size == 0) {
        return None
    }
    let layers = ArrayList<String>()
    for (token in tokens) {
        if (!isCssPaintLayerName(token)) {
            return None
        }
        if (!containsCssPaintLayer(layers, token)) {
            layers.add(token)
        }
    }
    for (name in CSS_PAINT_LAYER_NAMES) {
        if (!containsCssPaintLayer(layers, name)) {
            layers.add(name)
        }
    }
    joinCssStrings(layers, " ")
}

internal func isCssPaintLayerName(name: String): Bool {
    for (candidate in CSS_PAINT_LAYER_NAMES) {
        if (candidate == name) {
            return true
        }
    }
    false
}

private func containsCssPaintLayer(layers: ArrayList<String>, name: String): Bool {
    for (item in layers) {
        if (item == name) {
            return true
        }
    }
    false
}
