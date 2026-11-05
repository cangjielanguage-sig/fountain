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
import std.math.*
import fountain::f_base.*
import std.unittest.*
import std.unittest.testmacro.*

internal func animationDoc(body: String): SvgDocument {
    SvgParser.parse('<svg xmlns="http://www.w3.org/2000/svg">${body}</svg>')
}

internal func sampleAttribute(document: SvgDocument, time: Float64, id: String, name: String): String {
    let snapshot = SvgTimeline(document).sample(time)
    match (snapshot.elementById(id)) {
        case Some(element) => element.attr(name) ?? "<missing>"
        case None => "<missing-element>"
    }
}

internal func sampleTransformMatrix(document: SvgDocument, time: Float64, id: String): SvgMatrix {
    let text = sampleAttribute(document, time, id, "transform")
    if (text == "<missing>" || text == "<missing-element>") {
        return SvgMatrix.identity
    }
    match (tryParseSvgTransform(text)) {
        case Some(transform) => transform.toMatrix()
        case None => SvgMatrix.identity
    }
}

@Test
public class SvgAnimation_test {
    /** 四类动画识别与缺失属性 warning。 */
    @TestCase
    public func animationKindsAndWarnings(): Unit {
        let document = animationDoc(
            '<rect id="r" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="2s"/>' +
            '<animateTransform attributeName="transform" type="translate" from="0 0" to="10 0" dur="2s"/>' +
            '<animateMotion path="M0 0 L10 0" dur="2s"/>' +
            '<set attributeName="fill" to="red" dur="1s"/>' +
            '</rect>'
        )
        let timeline = SvgTimeline(document)
        let animations = timeline.animations()
        @Assert(animations.size == 4)
        @Assert(animations[0].kind == SvgAnimationKind.Animate)
        @Assert(animations[1].kind == SvgAnimationKind.AnimateTransform)
        @Assert(animations[2].kind == SvgAnimationKind.AnimateMotion)
        @Assert(animations[3].kind == SvgAnimationKind.Set)

        let missing = animationDoc(
            '<rect width="10" height="10">' +
            '<animate from="0" to="10" dur="1s"/>' +
            '<animateTransform from="0 0" to="1 1" dur="1s"/>' +
            '<animateMotion dur="1s"/>' +
            '</rect>'
        )
        let missingTimeline = SvgTimeline(missing)
        @Assert(missingTimeline.warnings.size >= 3)
    }

    /** 时间解析：s / ms / indefinite / id.begin / id.end / 事件型。 */
    @TestCase
    public func timeParsing(): Unit {
        let document = animationDoc(
            '<rect width="10" height="10">' +
            '<animate id="a" attributeName="x" from="0" to="10" dur="2s"/>' +
            '<animate id="b" attributeName="y" from="0" to="10" begin="a.begin" dur="1s"/>' +
            '<animate id="c" attributeName="width" from="0" to="10" begin="a.end" dur="500ms"/>' +
            '<animate id="d" attributeName="height" from="0" to="10" begin="indefinite" dur="1s"/>' +
            '<animate id="e" attributeName="opacity" from="0" to="1" begin="click" dur="1s"/>' +
            '</rect>'
        )
        let timeline = SvgTimeline(document)
        let animations = timeline.animations()
        @Assert(near(animations[0].begin, 0.0) && near(animations[0].end, 2.0))
        @Assert(near(animations[1].begin, 0.0) && near(animations[1].end, 1.0))
        @Assert(near(animations[2].begin, 2.0))
        @Assert(near(animations[2].end, 2.5))
        @Assert(animations[3].begin.isInf())
        @Assert(near(timeline.duration(), 2.5))
        @Assert(timeline.warnings.size >= 1)
    }

    /** repeatCount、repeatDur、fill remove / freeze。 */
    @TestCase
    public func repeatAndFill(): Unit {
        let frozen = animationDoc(
            '<rect id="r" x="99" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="1s" repeatCount="2.5" fill="freeze"/>' +
            '</rect>'
        )
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(frozen, 0.5, "r", "x"))), 5.0))
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(frozen, 1.5, "r", "x"))), 5.0))
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(frozen, 2.4, "r", "x"))), 4.0))
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(frozen, 2.6, "r", "x"))), 10.0))

        let removed = animationDoc(
            '<rect id="r" x="99" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="1s" repeatCount="2.5"/>' +
            '</rect>'
        )
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(removed, 2.6, "r", "x"))), 99.0))

        let repeatDurDocument = animationDoc(
            '<rect id="r" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="1s" repeatCount="10" repeatDur="1.5s" fill="freeze"/>' +
            '</rect>'
        )
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(repeatDurDocument, 1.2, "r", "x"))), 2.0))
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(repeatDurDocument, 1.6, "r", "x"))), 10.0))
    }

    /** animateTransform 五种 type 与 additive=sum。 */
    @TestCase
    public func animateTransforms(): Unit {
        for (kind in ["translate", "scale", "rotate", "skewX", "skewY"]) {
            let from = match (kind) {
                case "translate" => "0 0"
                case "scale" => "1 1"
                case "rotate" => "0"
                case "skewX" => "0"
                case _ => "0"
            }
            let to = match (kind) {
                case "translate" => "10 20"
                case "scale" => "2 3"
                case "rotate" => "90"
                case "skewX" => "45"
                case _ => "45"
            }
            let document = animationDoc(
                '<rect id="r" width="10" height="10">' +
                '<animateTransform type="' + kind + '" from="' + from + '" to="' + to +
                '" dur="2s" fill="freeze"/></rect>'
            )
            let matrix = sampleTransformMatrix(document, 1.0, "r")
            if (kind == "translate") {
                @Assert(near(matrix.e, 5.0) && near(matrix.f, 10.0))
            } else if (kind == "scale") {
                @Assert(near(matrix.a, 1.5) && near(matrix.d, 2.0))
            } else if (kind == "rotate") {
                @Assert(near(matrix.a, cos(45.0 * 3.141592653589793 / 180.0)))
            } else if (kind == "skewX") {
                @Assert(near(matrix.c, tan(22.5 * 3.141592653589793 / 180.0)))
            } else {
                @Assert(near(matrix.b, tan(22.5 * 3.141592653589793 / 180.0)))
            }
        }

        let additive = animationDoc(
            '<rect id="r" width="10" height="10" transform="translate(100 0)">' +
            '<animateTransform type="translate" from="0 0" to="10 0" dur="2s" additive="sum" fill="freeze"/>' +
            '</rect>'
        )
        let additiveMatrix = sampleTransformMatrix(additive, 1.0, "r")
        @Assert(near(additiveMatrix.e, 105.0))
    }

    /** animateMotion：直线、rotate auto / 角度。 */
    @TestCase
    public func animateMotion(): Unit {
        let line = animationDoc(
            '<rect id="r" width="10" height="10">' +
            '<animateMotion path="M0 0 L10 0" dur="2s" fill="freeze"/></rect>'
        )
        let lineMatrix = sampleTransformMatrix(line, 1.0, "r")
        @Assert(near(lineMatrix.e, 5.0) && near(lineMatrix.f, 0.0))

        let diagonal = animationDoc(
            '<rect id="r" width="10" height="10">' +
            '<animateMotion path="M0 0 L10 10" dur="2s" rotate="auto" fill="freeze"/></rect>'
        )
        let diagonalMatrix = sampleTransformMatrix(diagonal, 1.0, "r")
        @Assert(near(diagonalMatrix.e, 5.0) && near(diagonalMatrix.f, 5.0))
        @Assert(near(diagonalMatrix.a, cos(45.0 * 3.141592653589793 / 180.0)))

        let fixedRotation = animationDoc(
            '<rect id="r" width="10" height="10">' +
            '<animateMotion path="M0 0 L10 0" dur="2s" rotate="90" fill="freeze"/></rect>'
        )
        let fixedMatrix = sampleTransformMatrix(fixedRotation, 1.0, "r")
        @Assert(near(fixedMatrix.a, 0.0))
        @Assert(near(fixedMatrix.b, 1.0))
    }

    /** duration / animations / 同元素多动画 / by / additive / accumulate。 */
    @TestCase
    public func timelineSemantics(): Unit {
        let overridden = animationDoc(
            '<rect id="r" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="2s"/>' +
            '<animate attributeName="x" from="0" to="100" begin="1s" dur="2s"/>' +
            '</rect>'
        )
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(overridden, 0.5, "r", "x"))), 2.5))
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(overridden, 1.5, "r", "x"))), 25.0))

        let byDocument = animationDoc(
            '<rect id="r" x="5" width="10" height="10">' +
            '<animate attributeName="x" by="10" dur="2s" fill="freeze"/></rect>'
        )
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(byDocument, 1.0, "r", "x"))), 10.0))

        let additiveDocument = animationDoc(
            '<rect id="r" x="5" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="2s" additive="sum" fill="freeze"/></rect>'
        )
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(additiveDocument, 1.0, "r", "x"))), 10.0))

        let accumulateDocument = animationDoc(
            '<rect id="r" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="1s" repeatCount="2" accumulate="sum" fill="freeze"/>' +
            '</rect>'
        )
        @Assert(near(parseNumericAttribute(Some(sampleAttribute(accumulateDocument, 1.5, "r", "x"))), 15.0))
    }

    /** 深拷贝保留具体子类、elementById 可用，原文档不变。 */
    @TestCase
    public func deepCloneAndNoMutation(): Unit {
        let document = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="g">' +
            '<stop offset="0" stop-color="red"/></linearGradient></defs>' +
            '<g id="grp"><path id="p" d="M0 0 L10 10"/><text id="t">A</text></g>' +
            '<rect id="r" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="2s"/></rect></svg>'
        )
        let before = document.toString()
        let snapshot = SvgTimeline(document).sample(1.0)
        @Assert(document.toString() == before)
        @Assert(snapshot.toString() != before)
        @Assert(document.elementsByTag("rect")[0].attr("x").isNone())
        match (snapshot.elementById("p")) {
            case Some(element) => match (element) {
                case _: SvgPath => ()
                case _ => @Fail("path 深拷贝丢失具体类型")
            }
            case None => @Fail("快照缺少 path")
        }
        match (snapshot.elementById("t")) {
            case Some(element) => match (element) {
                case _: SvgText => ()
                case _ => @Fail("text 深拷贝丢失具体类型")
            }
            case None => @Fail("快照缺少 text")
        }
        match (snapshot.elementById("g")) {
            case Some(element) => match (element) {
                case _: SvgLinearGradient => ()
                case _ => @Fail("渐变深拷贝丢失具体类型")
            }
            case None => @Fail("快照缺少渐变")
        }
        @Assert(snapshot.root.tag == "svg")
    }

    /** 硬上限：values 10001、mpath 深度 64。 */
    @TestCase
    public func animationLimits(): Unit {
        let builder = StringBuilder()
        builder.append("0")
        for (index in 1..=10001) {
            builder.append(";1")
        }
        let valuesDocument = animationDoc(
            '<rect width="10" height="10"><animate attributeName="x" values="' + builder.toString() +
            '" dur="1s"/></rect>'
        )
        let valuesError = expectSvgException({=> SvgTimeline(valuesDocument).sample(0.0)})
        @Assert(valuesError.kind == SvgErrorKind.Limit)

        let chain = StringBuilder()
        for (index in 0..67) {
            chain.append('<path id="p' + index.toString() + '"')
            if (index == 66) {
                chain.append(' d="M0 0 L10 0"')
            }
            chain.append('>')
            if (index < 66) {
                chain.append('<animateMotion dur="1s"><mpath href="#p' + (index + 1).toString() + '"/></animateMotion>')
            }
            chain.append('</path>')
        }
        let mpathDocument = animationDoc(chain.toString())
        let mpathError = expectSvgException({=> SvgTimeline(mpathDocument)})
        @Assert(mpathError.kind == SvgErrorKind.Limit)
    }
}
