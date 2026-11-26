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

internal func svgDocumentHitQuery(
    document: SvgDocument,
    rect: SvgBounds,
    reference: ?SvgElement,
    enclosure: Bool
): ArrayList<SvgElement> {
    let result = ArrayList<SvgElement>()
    let resolver = SvgStyleResolver()
    let styles = resolver.compute(document.root, mediaWidth: 300.0, mediaHeight: 150.0)
    let start = match (reference) {
        case Some(value) => value
        case None => document.root
    }
    for (child in svgDirectChildElements(start)) {
        svgHitQueryCollect(child, rect, enclosure, styles, result)
    }
    result
}

internal func svgDocumentHitQueryCheck(
    document: SvgDocument,
    element: SvgElement,
    rect: SvgBounds,
    enclosure: Bool
): Bool {
    let resolver = SvgStyleResolver()
    let styles = resolver.compute(document.root, mediaWidth: 300.0, mediaHeight: 150.0)
    svgHitQueryMatches(element, rect, enclosure, styles)
}

private func svgHitQueryCollect(
    element: SvgElement,
    rect: SvgBounds,
    enclosure: Bool,
    styles: SvgComputedStyleTree,
    result: ArrayList<SvgElement>
): Unit {
    if (svgHitQueryMatches(element, rect, enclosure, styles)) {
        result.add(element)
    }
    for (child in svgDirectChildElements(element)) {
        svgHitQueryCollect(child, rect, enclosure, styles, result)
    }
}

private func svgHitQueryMatches(
    element: SvgElement,
    rect: SvgBounds,
    enclosure: Bool,
    styles: SvgComputedStyleTree
): Bool {
    let style = match (styles.get(element)) {
        case Some(value) => value
        case None => return false
    }
    if (style.pointerEvents() == SvgPointerEvents.None || style.visibility() == "hidden" ||
        style.visibility() == "collapse") {
        return false
    }
    let box = match (svgBBoxOf(element, SvgBBoxRequest(
        SvgBBoxOptions(),
        Some(styles),
        viewportWidth: 300.0,
        viewportHeight: 150.0
    ))) {
        case Some(value) => value
        case None => return false
    }
    if (enclosure) {
        rect.x <= box.x && rect.y <= box.y &&
        rect.x + rect.width >= box.x + box.width &&
        rect.y + rect.height >= box.y + box.height
    } else {
        !box.intersect(rect).isEmpty()
    }
}

private func svgDirectChildElements(element: SvgElement): ArrayList<SvgElement> {
    let result = ArrayList<SvgElement>()
    for (node in element.children) {
        match (node) {
            case ElementNode(child) => result.add(child)
            case _ => ()
        }
    }
    result
}
