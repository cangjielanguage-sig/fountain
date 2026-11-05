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

internal func m4Buffer(width: Int64, height: Int64, color: SvgColor): SvgFilterBuffer {
    let buffer = SvgFilterBuffer(width, height)
    let alpha = quantizeSvgChannel(color.alpha)
    var index = 0
    while (index < buffer.pixels.size) {
        buffer.pixels[index] = color.red
        buffer.pixels[index + 1] = color.green
        buffer.pixels[index + 2] = color.blue
        buffer.pixels[index + 3] = alpha
        index += 4
    }
    buffer
}

internal func m4TransparentBuffer(width: Int64, height: Int64): SvgFilterBuffer {
    SvgFilterBuffer(width, height)
}

internal func m4FillRect(
    buffer: SvgFilterBuffer,
    x: Int64,
    y: Int64,
    width: Int64,
    height: Int64,
    color: SvgColor
): Unit {
    let alpha = quantizeSvgChannel(color.alpha)
    var row = y
    while (row < y + height) {
        var column = x
        while (column < x + width) {
            let base = (row * buffer.width + column) * 4
            buffer.pixels[base] = color.red
            buffer.pixels[base + 1] = color.green
            buffer.pixels[base + 2] = color.blue
            buffer.pixels[base + 3] = alpha
            column++
        }
        row++
    }
}

internal func m4AlphaAt(buffer: SvgFilterBuffer, x: Int64, y: Int64): Int64 {
    Int64(buffer.pixels[(y * buffer.width + x) * 4 + 3])
}

internal func m4ChannelAt(buffer: SvgFilterBuffer, x: Int64, y: Int64, channel: Int64): Int64 {
    Int64(buffer.pixels[(y * buffer.width + x) * 4 + channel])
}

internal func m4BuffersEqual(left: SvgFilterBuffer, right: SvgFilterBuffer): Bool {
    if (left.width != right.width || left.height != right.height) {
        return false
    }
    for (index in 0..left.pixels.size) {
        if (left.pixels[index] != right.pixels[index]) {
            return false
        }
    }
    true
}

private func m4ColorLevel(value: Int64): SvgColor {
    let channel = UInt8(value)
    SvgColor(channel, channel, channel, alpha: 1.0)
}

@Test
public class SvgFilterPrimitives2M4_test {
    /** identity 直通与缺失通道。 */
    @TestCase
    public func componentIdentityAndMissingChannels(): Unit {
        let input = m4Buffer(2, 1, m4ColorLevel(128))
        let transfer = SvgFeComponentTransfer()
        let warnings = ArrayList<String>()
        let identity = componentTransferFilterBuffer(input, transfer, warnings)
        @Assert(m4BuffersEqual(input, identity))

        let linear = SvgFeFuncR()
        linear.functionType = SvgTransferFunctionType.Linear
        linear.slope = 0.0
        linear.intercept = 0.0
        transfer.appendElement(linear)
        let onlyRed = componentTransferFilterBuffer(input, transfer, warnings)
        @Assert(m4ChannelAt(onlyRed, 0, 0, 0) == 0)
        @Assert(m4ChannelAt(onlyRed, 0, 0, 1) == 128)
        @Assert(m4ChannelAt(onlyRed, 0, 0, 2) == 128)
        @Assert(m4ChannelAt(onlyRed, 0, 0, 3) == 255)
    }

    /** table / discrete / linear / gamma 与钳制。 */
    @TestCase
    public func componentTransferFunctions(): Unit {
        let warnings = ArrayList<String>()
        let input = m4Buffer(1, 1, m4ColorLevel(128))

        let table = SvgFeComponentTransfer()
        let tableFunc = SvgFeFuncR()
        tableFunc.functionType = SvgTransferFunctionType.Table
        tableFunc.tableValues = [0.0, 1.0]
        table.appendElement(tableFunc)
        let tabled = componentTransferFilterBuffer(input, table, warnings)
        @Assert(m4ChannelAt(tabled, 0, 0, 0) >= 127 && m4ChannelAt(tabled, 0, 0, 0) <= 129)

        let discrete = SvgFeComponentTransfer()
        let discreteFunc = SvgFeFuncR()
        discreteFunc.functionType = SvgTransferFunctionType.Discrete
        discreteFunc.tableValues = [0.0, 0.25, 0.5, 0.75]
        discrete.appendElement(discreteFunc)
        let stepped = componentTransferFilterBuffer(m4Buffer(1, 1, m4ColorLevel(153)), discrete, warnings)
        @Assert(m4ChannelAt(stepped, 0, 0, 0) == 128)

        let linear = SvgFeComponentTransfer()
        let linearFunc = SvgFeFuncR()
        linearFunc.functionType = SvgTransferFunctionType.Linear
        linearFunc.slope = 2.0
        linearFunc.intercept = 0.0
        linear.appendElement(linearFunc)
        let clamped = componentTransferFilterBuffer(m4Buffer(1, 1, m4ColorLevel(204)), linear, warnings)
        @Assert(m4ChannelAt(clamped, 0, 0, 0) == 255)

        let gamma = SvgFeComponentTransfer()
        let gammaFunc = SvgFeFuncR()
        gammaFunc.functionType = SvgTransferFunctionType.Gamma
        gammaFunc.amplitude = 2.0
        gammaFunc.exponent = 2.0
        gammaFunc.offset = 0.0
        gamma.appendElement(gammaFunc)
        let gammaResult = componentTransferFilterBuffer(m4Buffer(1, 1, m4ColorLevel(128)), gamma, warnings)
        @Assert(m4ChannelAt(gammaResult, 0, 0, 0) >= 126 && m4ChannelAt(gammaResult, 0, 0, 0) <= 130)
    }

    /** 空 tableValues warning + 直通。 */
    @TestCase
    public func componentEmptyTable(): Unit {
        let input = m4Buffer(1, 1, m4ColorLevel(128))
        let transfer = SvgFeComponentTransfer()
        let funcR = SvgFeFuncR()
        funcR.functionType = SvgTransferFunctionType.Table
        transfer.appendElement(funcR)
        let warnings = ArrayList<String>()
        let output = componentTransferFilterBuffer(input, transfer, warnings)
        @Assert(m4BuffersEqual(input, output))
        @Assert(warnings.size > 0)
        @Assert(warnings[0].contains("tableValues"))
    }

    /** 腐蚀 / 膨胀 / 零半径 / 负半径 / primitiveUnits 换算。 */
    @TestCase
    public func morphology(): Unit {
        let input = m4TransparentBuffer(20, 20)
        m4FillRect(input, 5, 5, 10, 10, SvgColor.fromRgb(255, 0, 0))
        let warnings = ArrayList<String>()

        let erosion = SvgFeMorphology()
        erosion.operatorKind = SvgMorphologyOperator.Erode
        erosion.radius = SvgNumberList([1.0])
        let eroded = morphologyFilterBuffer(input, erosion, 1.0, 1.0, warnings)
        @Assert(m4AlphaAt(eroded, 5, 5) == 0)
        @Assert(m4AlphaAt(eroded, 6, 6) == 255)
        @Assert(m4AlphaAt(eroded, 13, 13) == 255)
        @Assert(m4AlphaAt(eroded, 14, 14) == 0)

        let dilation = SvgFeMorphology()
        dilation.operatorKind = SvgMorphologyOperator.Dilate
        dilation.radius = SvgNumberList([1.0])
        let dilated = morphologyFilterBuffer(input, dilation, 1.0, 1.0, warnings)
        @Assert(m4AlphaAt(dilated, 4, 4) == 255)
        @Assert(m4AlphaAt(dilated, 15, 15) == 255)
        @Assert(m4AlphaAt(dilated, 3, 3) == 0)

        let zero = SvgFeMorphology()
        zero.radius = SvgNumberList([0.0])
        @Assert(m4BuffersEqual(input, morphologyFilterBuffer(input, zero, 1.0, 1.0, warnings)))

        let negative = SvgFeMorphology()
        negative.radius = SvgNumberList([-1.0])
        let negativeWarnings = ArrayList<String>()
        @Assert(m4BuffersEqual(input, morphologyFilterBuffer(input, negative, 1.0, 1.0, negativeWarnings)))
        @Assert(negativeWarnings.size > 0)

        let scaled = SvgFeMorphology()
        scaled.operatorKind = SvgMorphologyOperator.Erode
        scaled.radius = SvgNumberList([1.0])
        let scaledErosion = morphologyFilterBuffer(input, scaled, 2.0, 2.0, warnings)
        @Assert(m4AlphaAt(scaledErosion, 6, 6) == 0)
        @Assert(m4AlphaAt(scaledErosion, 7, 7) == 255)
    }

    /** 单位核、divisor/bias、edgeMode、preserveAlpha。 */
    @TestCase
    public func convolve(): Unit {
        let input = m4Buffer(5, 5, SvgColor.fromRgb(10, 20, 30))
        let warnings = ArrayList<String>()

        let identity = SvgFeConvolveMatrix()
        identity.kernelMatrix = [0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]
        identity.divisor = Some(1.0)
        @Assert(m4BuffersEqual(input, convolveFilterBuffer(input, identity, warnings)))

        let average = SvgFeConvolveMatrix()
        average.kernelMatrix = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
        let averaged = convolveFilterBuffer(input, average, warnings)
        @Assert(m4ChannelAt(averaged, 2, 2, 0) == 10)

        let biased = SvgFeConvolveMatrix()
        biased.kernelMatrix = [0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]
        biased.bias = 0.1
        let biasedResult = convolveFilterBuffer(m4Buffer(3, 3, SvgColor.Black), biased, warnings)
        @Assert(m4ChannelAt(biasedResult, 1, 1, 0) >= 25 && m4ChannelAt(biasedResult, 1, 1, 0) <= 26)

        let block = m4TransparentBuffer(9, 9)
        m4FillRect(block, 0, 0, 9, 9, SvgColor.fromRgb(255, 0, 0))
        let duplicate = SvgFeConvolveMatrix()
        duplicate.kernelMatrix = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
        duplicate.edgeMode = SvgEdgeMode.Duplicate
        @Assert(m4ChannelAt(convolveFilterBuffer(block, duplicate, warnings), 0, 0, 0) == 255)
        let noEdge = SvgFeConvolveMatrix()
        noEdge.kernelMatrix = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
        noEdge.edgeMode = SvgEdgeMode.NoEdge
        let noEdgeResult = convolveFilterBuffer(block, noEdge, warnings)
        @Assert(m4ChannelAt(noEdgeResult, 0, 0, 0) < 255)

        let preserve = SvgFeConvolveMatrix()
        preserve.kernelMatrix = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        preserve.preserveAlpha = true
        let preserved = convolveFilterBuffer(m4Buffer(3, 3, SvgColor.fromRgb(255, 0, 0)), preserve, warnings)
        @Assert(m4AlphaAt(preserved, 1, 1) == 255)
        @Assert(m4ChannelAt(preserved, 1, 1, 0) == 0)
    }

    /** 核长度不符、非有限、order 超限。 */
    @TestCase
    public func convolveValidation(): Unit {
        let input = m4Buffer(3, 3, SvgColor.White)
        let warnings = ArrayList<String>()
        let mismatch = SvgFeConvolveMatrix()
        mismatch.kernelMatrix = [1.0, 0.0]
        @Assert(m4BuffersEqual(input, convolveFilterBuffer(input, mismatch, warnings)))
        @Assert(warnings.size > 0)

        let invalid = SvgFeConvolveMatrix()
        invalid.setAttr("kernelMatrix", "0 0 0 0 nan 0 0 0 0")
        let invalidWarnings = ArrayList<String>()
        @Assert(m4BuffersEqual(input, convolveFilterBuffer(input, invalid, invalidWarnings)))
        @Assert(invalidWarnings.size > 0)

        let tooLarge = SvgFeConvolveMatrix()
        tooLarge.order = SvgNumberList([10.0, 10.0])
        let error = expectSvgException({=> convolveFilterBuffer(input, tooLarge, warnings)})
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 原语链 result 连接与确定性。 */
    @TestCase
    public func chainDeterminism(): Unit {
        let document = SvgParser.parse(
            "<svg width=\"20\" height=\"20\"><filter id=\"f\">" +
            "<feComponentTransfer result=\"a\"><feFuncR type=\"linear\" slope=\"0.5\"/>" +
            "</feComponentTransfer>" +
            "<feMorphology in=\"a\" result=\"b\" operator=\"dilate\" radius=\"1\"/>" +
            "<feConvolveMatrix in=\"b\" order=\"3\" " +
            "kernelMatrix=\"0 0 0 0 1 0 0 0 0\" divisor=\"1\"/>" +
            "</filter>" +
            "<rect width=\"10\" height=\"10\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let first = renderer.render(document)
        let second = renderer.render(document)
        @Assert(first.pixels == second.pixels)
        @Assert(first.pixel(5, 5).alpha > 0.5)
    }
}
