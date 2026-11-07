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
import std.unittest.*
import std.unittest.testmacro.*
import std.time.*

class M6MutationRecorder <: SvgMutationListener {
    let events = ArrayList<SvgMutationEvent>()
    var throws: Bool = false

    public func onMutation(event: SvgMutationEvent): Unit {
        if (this.throws) {
            throw invalidValue("listener failure")
        }
        this.events.add(event)
    }
}

@Test
public class SvgDomApiM6_test {
    /** 工厂方法与既有构造器等价。 */
    @TestCase
    public func factories(): Unit {
        @Assert(SvgPoint.create(1.0, 2.0) == SvgPoint(1.0, 2.0))
        let matrix = SvgMatrix.create(1.0, 2.0, 3.0, 4.0, 5.0, 6.0)
        @Assert(matrix == SvgMatrix(1.0, 2.0, 3.0, 4.0, 5.0, 6.0))
        let transform = SvgTransform.create([SvgTransformOp.Translate(2.0, 3.0)])
        @Assert(transform == SvgTransform([SvgTransformOp.Translate(2.0, 3.0)]))
        @Assert(SvgTransform.create() == SvgTransform.identity)
    }

    /** viewState 缺省为单位矩阵，显式缩放 / 平移参与渲染。 */
    @TestCase
    public func viewState(): Unit {
        let state = SvgViewState()
        @Assert(state.currentScale == 1.0)
        @Assert(state.currentTranslate == SvgPoint(0.0, 0.0))
        @Assert(state.toMatrix() == SvgMatrix.identity)

        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<rect x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"red\"/></svg>"
        )
        let baseline = SvgRenderer(options: SvgRenderOptions(width: 20, height: 20)).render(document)
        let explicit = SvgViewState(currentScale: 1.0, currentTranslate: SvgPoint(0.0, 0.0))
        let same = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, viewState: explicit)
        ).render(document)
        @Assert(baseline.pixels == same.pixels)

        let zoom = SvgViewState(currentScale: 2.0)
        let zoomed = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, viewState: zoom)
        ).render(document)
        @Assert(zoomed.pixel(15, 15).toString() == "#ff0000")
        @Assert(baseline.pixel(15, 15).alpha == 0.0)

        let shifted = SvgViewState(currentTranslate: SvgPoint(5.0, 0.0))
        let moved = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, viewState: shifted)
        ).render(document)
        @Assert(moved.pixel(12, 5).toString() == "#ff0000")
        @Assert(moved.pixel(2, 5).alpha == 0.0)
    }

    /** insertBefore / removeChild 维护 children 与 parent。 */
    @TestCase
    public func childMutations(): Unit {
        let parent = SvgContainer(SvgContainerKind.Group)
        let first = SvgRect()
        let second = SvgCircle()
        parent.appendElement(first)
        parent.insertBefore(SvgNode.ElementNode(second), Some(first))
        @Assert(parent.children.size == 2)
        @Assert(parent.children[0].toString().startsWith("<circle"))
        let parentValue = match (second.parent) {
            case Some(value) => value
            case None => throw invalidValue("missing parent")
        }
        @Assert(parentValue == parent)
        @Assert(parent.removeChild(SvgNode.ElementNode(first)))
        @Assert(parent.children.size == 1)
        @Assert(first.parent.isNone())
        @Assert(!parent.removeChild(SvgNode.ElementNode(first)))
        parent.insertBefore(SvgNode.ElementNode(first), Option<SvgElement>.None)
        @Assert(parent.children.size == 2)
        var threw = false
        try {
            parent.insertBefore(SvgNode.ElementNode(SvgRect()), Some(SvgRect()))
        } catch (_: SvgException) {
            threw = true
        }
        @Assert(threw)
    }

    /** 变更监听：属性、子节点、移除后不再通知。 */
    @TestCase
    public func mutationListeners(): Unit {
        let root = SvgRoot()
        let document = SvgDocument(root)
        let recorder = M6MutationRecorder()
        document.addMutationListener(recorder)
        root.setAttr("data-x", "1")
        @Assert(recorder.events.size == 1)
        @Assert(recorder.events[0].kind == SvgMutationKind.Attribute)
        @Assert(recorder.events[0].attributeName == Some("data-x"))

        let child = SvgRect()
        root.appendElement(child)
        @Assert(recorder.events.size == 2)
        @Assert(recorder.events[1].kind == SvgMutationKind.ChildList)
        @Assert(root.removeChild(SvgNode.ElementNode(child)))
        @Assert(recorder.events.size == 3)
        @Assert(recorder.events[2].kind == SvgMutationKind.ChildList)

        document.removeMutationListener(recorder)
        root.setAttr("data-y", "2")
        @Assert(recorder.events.size == 3)
    }

    /** 移除指定监听器：A、B 注册后移除 B，A 仍收到事件；移除未注册对象无副作用。 */
    @TestCase
    public func removeListenerByReference(): Unit {
        let root = SvgRoot()
        let document = SvgDocument(root)
        let first = M6MutationRecorder()
        let second = M6MutationRecorder()
        document.addMutationListener(first)
        document.addMutationListener(second)
        document.removeMutationListener(second)
        root.setAttr("data-x", "1")
        @Assert(first.events.size == 1)
        @Assert(second.events.size == 0)
        let unregistered = M6MutationRecorder()
        document.removeMutationListener(unregistered)
        root.setAttr("data-y", "2")
        @Assert(first.events.size == 2)
        @Assert(second.events.size == 0)
    }

    /** 命名空间版 setAttr / removeAttr 同样触发变更通知。 */
    @TestCase
    public func namespacedAttributesNotify(): Unit {
        let root = SvgRoot()
        let document = SvgDocument(root)
        let recorder = M6MutationRecorder()
        document.addMutationListener(recorder)
        let namespace = "http://www.w3.org/1999/xlink"
        root.setAttr(namespace, "href", "#target")
        @Assert(recorder.events.size == 1)
        @Assert(recorder.events[0].kind == SvgMutationKind.Attribute)
        @Assert(recorder.events[0].attributeName == Some("href"))
        @Assert(recorder.events[0].newValue == Some("#target"))
        root.removeAttr(namespace, "href")
        @Assert(recorder.events.size == 2)
        @Assert(recorder.events[1].kind == SvgMutationKind.Attribute)
        @Assert(recorder.events[1].oldValue == Some("#target"))
        @Assert(root.removeAttr(namespace, "href") == false)
        @Assert(recorder.events.size == 2)
    }

    /** 监听异常被隔离，不影响文档与后续监听。 */
    @TestCase
    public func listenerExceptionIsolated(): Unit {
        let root = SvgRoot()
        let document = SvgDocument(root)
        let bad = M6MutationRecorder()
        bad.throws = true
        let good = M6MutationRecorder()
        document.addMutationListener(bad)
        document.addMutationListener(good)
        root.setAttr("data-x", "1")
        @Assert(good.events.size == 1)
        @Assert(document.warnings.size >= 1)
    }

    /** 监听器上限 32。 */
    @TestCase
    public func listenerLimit(): Unit {
        let document = SvgDocument(SvgRoot())
        var index = 0
        while (index < 32) {
            document.addMutationListener(M6MutationRecorder())
            index++
        }
        var threw = false
        try {
            document.addMutationListener(M6MutationRecorder())
        } catch (_: SvgException) {
            threw = true
        }
        @Assert(threw)
    }

    /** 命中查询：相交 / 包含、check 一致、筛选与 reference 范围。 */
    @TestCase
    public func hitQueries(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
            "<g id=\"g\"><rect id=\"a\" x=\"0\" y=\"0\" width=\"10\" height=\"10\"/>" +
            "<rect id=\"b\" x=\"20\" y=\"0\" width=\"10\" height=\"10\"/>" +
            "<rect id=\"hidden\" x=\"0\" y=\"20\" width=\"10\" height=\"10\" visibility=\"hidden\"/>" +
            "<rect id=\"skip\" x=\"20\" y=\"20\" width=\"10\" height=\"10\" pointer-events=\"none\"/>" +
            "</g></svg>"
        )
        let rect = SvgBounds(5.0, 5.0, 10.0, 10.0)
        let intersection = document.getIntersectionList(rect)
        @Assert(intersection.size == 2)
        var sawA = false
        for (element in intersection) {
            if (element.attr("id") == Some("a")) {
                sawA = true
            }
        }
        @Assert(sawA)
        let empty = document.getIntersectionList(SvgBounds(100.0, 100.0, 5.0, 5.0))
        @Assert(empty.size == 0)

        let enclosure = document.getEnclosureList(SvgBounds(-1.0, -1.0, 40.0, 40.0))
        @Assert(enclosure.size == 3)
        let a = document.elementById("a") ?? throw invalidValue("missing")
        @Assert(document.checkIntersection(a, rect))
        @Assert(!document.checkIntersection(a, SvgBounds(100.0, 100.0, 1.0, 1.0)))
        @Assert(document.checkEnclosure(a, SvgBounds(-1.0, -1.0, 20.0, 20.0)))
        @Assert(!document.checkEnclosure(a, SvgBounds(5.0, 5.0, 4.0, 4.0)))

        let group = document.elementById("g") ?? throw invalidValue("missing")
        let scoped = document.getIntersectionList(SvgBounds(0.0, 0.0, 100.0, 100.0), reference: Some(group))
        @Assert(scoped.size == 2)
    }

    /** 查询不修改文档，结果集合为独立实例。 */
    @TestCase
    public func queriesAreReadOnly(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"a\" x=\"0\" y=\"0\" " +
            "width=\"10\" height=\"10\"/></svg>"
        )
        let before = document.toString()
        let first = document.getIntersectionList(SvgBounds(0.0, 0.0, 10.0, 10.0))
        let second = document.getIntersectionList(SvgBounds(0.0, 0.0, 10.0, 10.0))
        @Assert(first.size == second.size)
        @Assert(document.toString() == before)
    }

    /** 1000 元素查询有明确上限；记录耗时供 perf-baseline。 */
    @TestCase
    public func largeDocumentPerformance(): Unit {
        let builder = StringBuilder()
        builder.append("<svg xmlns=\"http://www.w3.org/2000/svg\">")
        for (index in 0..1000) {
            let x = (index % 100) * 10
            let y = (index / 100) * 10
            builder.append("<rect x=\"" + x.toString() + "\" y=\"" + y.toString() + "\" width=\"5\" height=\"5\"/>")
        }
        builder.append("</svg>")
        let document = SvgParser.parse(builder.toString())
        let start = DateTime.now()
        let result = document.getIntersectionList(SvgBounds(0.0, 0.0, 50.0, 50.0))
        let elapsed = DateTime.now() - start
        @Assert(result.size > 0)
        @Assert(elapsed.toNanoseconds() < 5000000000)
    }
}
