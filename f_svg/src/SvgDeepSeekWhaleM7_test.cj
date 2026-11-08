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

import std.fs.{File, Path}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 生成故事动图：Q 版二头身 DeepSeek 女仆装鲸鱼娘，戴着 DeepSeek 发卡，
 * 抱着写有 “fountain” 与仓颉图标电饭煲，边跑边干饭。
 */
@Test
public class SvgDeepSeekWhaleM7_test {
    @TestCase
    public func whaleMaidRunsWithRiceCooker(): Unit {
        let builder = SvgBuilder(640.0, 520.0, viewBox: SvgViewBox(0.0, 0.0, 640.0, 520.0))

        this.addBackdrop(builder)
        this.addWhaleMaid(builder)
        this.addRiceCooker(builder)

        let svg = builder.toSvgString()
        @Assert(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        @Assert(svg.contains("id=\"whale-maid\""))
        @Assert(svg.contains("id=\"deepseek-pin\""))
        @Assert(svg.contains("id=\"cangjie-badge\""))
        @Assert(svg.contains("id=\"fountain-label\""))

        let target = Path("target/deepseek-whale-maid.svg")
        builder.save(target)
        let parsed = SvgParser.parse(target)
        @Assert(parsed.root.tag == "svg")

        for (id in ["whale-maid", "rice-cooker", "deepseek-pin", "cangjie-badge", "tail", "steam"]) {
            @Assert(parsed.elementById(id).isSome())
        }
        for (leg in ["leg-left", "leg-right", "scoop-arm"]) {
            let group = parsed.elementById(leg).getOrThrow()
            let animate = group.child("animateTransform").getOrThrow()
            @Assert(animate.attr("type") == Some("rotate"))
            @Assert(animate.attr("repeatCount") == Some("indefinite"))
        }
        let body = parsed.elementById("whale-maid").getOrThrow()
        @Assert(body.child("animateTransform").isSome())

        let golden = String.fromUtf8(File.readFrom(Path("testdata/story/deepseek-whale-maid.svg")))
        @Assert(golden == svg)
        println("WHALE_SVG=${target}")
    }

    /** 粉蓝背景、地面阴影与装饰气泡。 */
    private func addBackdrop(builder: SvgBuilder): Unit {
        builder.rect(x: 0.0, y: 0.0, width: 640.0, height: 520.0).fill("#FDF1F7")
        builder.circle(cx: 90.0, cy: 90.0, r: 46.0).fill("#E7F6FF")
        builder.circle(cx: 560.0, cy: 120.0, r: 34.0).fill("#FFE5F1")
        builder.circle(cx: 520.0, cy: 60.0, r: 14.0).fill("#FFF7DA")
        builder.ellipse(cx: 320.0, cy: 486.0, rx: 150.0, ry: 16.0).fill("#E8D5E1")
    }

    /** 二头身鲸鱼娘：头 130，全身 260。 */
    private func addWhaleMaid(builder: SvgBuilder): Unit {
        builder.group(id: "whale-maid").animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Translate,
            values: ["0 0", "0 -8", "0 0"],
            dur: "1.2s",
            repeatCount: "indefinite"
        )

        this.addTail(builder)
        this.addLegs(builder)
        this.addDress(builder)
        this.addHead(builder)
        this.addScoopArm(builder)
        builder.end()
    }

    /** 鲸鱼尾：蓝色尾柄与尾鳍，左右轻摆。 */
    private func addTail(builder: SvgBuilder): Unit {
        builder.group(id: "tail").animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["0 372 430;9 372 430;0 372 430;-9 372 430;0 372 430"],
            dur: "1.4s",
            repeatCount: "indefinite"
        )
        builder.path(d: "M365 430 Q420 412 438 372 Q452 392 470 388 Q448 420 448 448 Q412 452 372 444 Z")
            .fill("#7CC9EA")
        builder.path(d: "M438 372 Q452 392 470 388 Q462 402 456 410 Q446 396 438 390 Z")
            .fill("#5FB4D8")
        builder.end()
    }

    /** 两条跑动的腿：绕髋交替旋转。 */
    private func addLegs(builder: SvgBuilder): Unit {
        this.addLeg(builder, "leg-left", 302.0, 440.0, "16 302 440;-16 302 440;16 302 440", 0.0)
        this.addLeg(builder, "leg-right", 338.0, 440.0, "-16 338 440;16 338 440;-16 338 440", 0.3)
    }

    private func addLeg(
        builder: SvgBuilder,
        id: String,
        hipX: Float64,
        hipY: Float64,
        values: String,
        beginSeconds: Float64
    ): Unit {
        builder.group(id: id).animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: [values],
            dur: "0.6s",
            begin: SvgBegin.offset(beginSeconds),
            repeatCount: "indefinite"
        )
        builder.line(x1: hipX, y1: hipY, x2: hipX, y2: hipY + 24.0)
            .stroke("#FFE0CC")
            .strokeWidth(9.0)
            .attr("stroke-linecap", "round")
        builder.ellipse(cx: hipX, cy: hipY + 30.0, rx: 12.0, ry: 7.0).fill("#2F3A56")
        builder.end()
    }

    /** 女仆裙、白色围裙与蝴蝶结。 */
    private func addDress(builder: SvgBuilder): Unit {
        builder.path(d: "M282 336 Q320 322 358 336 L392 446 Q320 462 248 446 Z").fill("#2F3A56")
        builder.path(d: "M292 350 L348 350 L362 438 Q320 448 278 438 Z").fill("#FFFFFF")
        builder.path(d: "M292 350 Q320 366 348 350 L344 380 Q320 390 296 380 Z").fill("#F4F4F4")
        builder.circle(cx: 320.0, cy: 350.0, r: 5.0).fill("#FF8FB8")
        builder.path(d: "M306 336 Q300 326 294 336 Q300 342 306 336 Z").fill("#FF8FB8")
        builder.path(d: "M334 336 Q340 326 346 336 Q340 342 334 336 Z").fill("#FF8FB8")
        builder.circle(cx: 320.0, cy: 392.0, r: 3.0).fill("#FFD1E3")
    }

    /** 大头、蓝发、鲸鱼鳍耳、女仆头饰与 DeepSeek 发卡。 */
    private func addHead(builder: SvgBuilder): Unit {
        // 鲸鱼鳍耳
        builder.path(d: "M258 268 Q232 276 238 300 Q256 296 266 282 Z").fill("#8FD8F5")
        builder.path(d: "M382 268 Q408 276 402 300 Q384 296 374 282 Z").fill("#8FD8F5")
        // 头与头发
        builder.circle(cx: 320.0, cy: 266.0, r: 66.0).fill("#FFE0CC")
        builder.path(d: "M254 258 Q252 196 320 194 Q388 196 386 258 Q366 226 320 224 Q274 226 254 258 Z")
            .fill("#8FD8F5")
        builder.path(d: "M254 258 Q240 320 262 356 Q270 322 272 292 Z").fill("#8FD8F5")
        builder.path(d: "M386 258 Q400 320 378 356 Q370 322 368 292 Z").fill("#8FD8F5")
        builder.path(d: "M286 222 Q320 242 354 222 Q340 250 320 250 Q300 250 286 222 Z").fill("#7CC9EA")
        // 女仆头饰：白色褶边 + 黑色发带
        builder.path(d: "M258 224 Q320 190 382 224 Q380 240 370 242 Q362 230 352 240 Q344 248 334 238 Q326 248 316 238 Q308 248 298 238 Q290 248 280 238 Q270 246 262 238 Q258 232 258 224 Z")
            .fill("#FFFFFF")
        builder.path(d: "M262 232 Q320 204 378 232").stroke("#2F3A56").strokeWidth(4.0).attr("fill", "none")
        // DeepSeek 发卡：蓝色底 + 白色鲸尾标记
        builder.group(id: "deepseek-pin").transform("translate(372 232) rotate(-14)")
        builder.rect(x: -23.0, y: -12.0, width: 46.0, height: 24.0, rx: 9.0, ry: 9.0).fill("#4D6BFE")
        builder.path(d: "M-15 7 Q-9 -7 0 -3 Q5 -1 2 2 Q-3 2 -7 5 Q-10 9 -15 7 Z").fill("#FFFFFF")
        builder.circle(cx: 6.0, cy: 4.0, r: 2.4).fill("#FFFFFF")
        builder.end()
        // 眼睛、腮红、嘴
        builder.circle(cx: 296.0, cy: 270.0, r: 9.0).fill("#26324A")
        builder.circle(cx: 344.0, cy: 270.0, r: 9.0).fill("#26324A")
        builder.circle(cx: 299.0, cy: 266.0, r: 3.2).fill("#FFFFFF")
        builder.circle(cx: 347.0, cy: 266.0, r: 3.2).fill("#FFFFFF")
        builder.circle(cx: 272.0, cy: 288.0, r: 9.0).fill("#FFB7CE").attr("opacity", "0.75")
        builder.circle(cx: 368.0, cy: 288.0, r: 9.0).fill("#FFB7CE").attr("opacity", "0.75")
        builder.ellipse(cx: 320.0, cy: 300.0, rx: 8.0, ry: 10.0).fill("#C94F6D")
        builder.ellipse(cx: 320.0, cy: 305.0, rx: 4.0, ry: 3.0).fill("#FF9DB8")
    }

    /** 右手拿勺子干饭：整条手臂绕肩旋转。 */
    private func addScoopArm(builder: SvgBuilder): Unit {
        builder.group(id: "scoop-arm").animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["-6 356 352;-38 356 352;-6 356 352"],
            dur: "1.2s",
            repeatCount: "indefinite"
        )
        builder.line(x1: 358.0, y1: 352.0, x2: 352.0, y2: 324.0)
            .stroke("#2F3A56")
            .strokeWidth(13.0)
            .attr("stroke-linecap", "round")
        builder.line(x1: 352.0, y1: 324.0, x2: 338.0, y2: 310.0)
            .stroke("#FFE0CC")
            .strokeWidth(10.0)
            .attr("stroke-linecap", "round")
        builder.ellipse(cx: 331.0, cy: 306.0, rx: 13.0, ry: 6.5).fill("#D9DEE7")
        builder.ellipse(cx: 331.0, cy: 301.0, rx: 9.0, ry: 6.5).fill("#FFFFFF")
        builder.circle(cx: 326.0, cy: 298.0, r: 2.4).fill("#F4F4F4")
        builder.circle(cx: 333.0, cy: 296.0, r: 2.4).fill("#F4F4F4")
        builder.circle(cx: 329.0, cy: 293.0, r: 2.4).fill("#F4F4F4")
        builder.end()
    }

    /** 电饭煲：fountain 字样、仓颉图标、蒸汽与轻微上下浮动。 */
    private func addRiceCooker(builder: SvgBuilder): Unit {
        builder.group(id: "rice-cooker").transform("translate(202 404)").animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Translate,
            values: ["202 404", "202 399", "202 404"],
            dur: "1.2s",
            repeatCount: "indefinite"
        )
        // 煲体与盖子
        builder.rect(x: -58.0, y: -78.0, width: 116.0, height: 92.0, rx: 16.0, ry: 16.0)
            .fill("#F4F6F8")
            .stroke("#B8C2CC")
            .strokeWidth(3.0)
        builder.rect(x: -50.0, y: -88.0, width: 100.0, height: 16.0, rx: 8.0, ry: 8.0)
            .fill("#E3E8EE")
            .stroke("#B8C2CC")
            .strokeWidth(2.0)
        builder.path(d: "M-22 -92 Q0 -108 22 -92").stroke("#9AA7B4").strokeWidth(5.0).attr("fill", "none")
        builder.circle(cx: 0.0, cy: -96.0, r: 5.0).fill("#B8C2CC")
        builder.rect(x: -42.0, y: -66.0, width: 84.0, height: 18.0, rx: 9.0, ry: 9.0).fill("#DCE6F2")
            .stroke("#B8C2CC")
            .strokeWidth(1.5)
        builder.rect(x: 28.0, y: -60.0, width: 14.0, height: 8.0, rx: 3.0, ry: 3.0).fill("#FF8FB8")
        builder.rect(x: 30.0, y: -58.0, width: 10.0, height: 4.0, rx: 2.0, ry: 2.0).fill("#FFD1E3")
        // 左臂从角色伸到煲体
        builder.line(x1: 58.0, y1: -18.0, x2: 82.0, y2: -44.0)
            .stroke("#2F3A56")
            .strokeWidth(12.0)
            .attr("stroke-linecap", "round")
        builder.line(x1: 52.0, y1: -14.0, x2: 64.0, y2: -26.0)
            .stroke("#FFE0CC")
            .strokeWidth(9.0)
            .attr("stroke-linecap", "round")
        // 仓颉图标徽章
        builder.group(id: "cangjie-badge").transform("translate(32 -52)")
        builder.rect(x: -14.0, y: -14.0, width: 28.0, height: 28.0, rx: 7.0, ry: 7.0).fill("#1E88E5")
        builder.path(d: "M6 -7 A8 8 0 1 0 6 7").stroke("#FFFFFF").strokeWidth(3.0).attr("fill", "none")
        builder.circle(cx: 3.0, cy: 9.0, r: 2.2).fill("#7BE3B0")
        builder.end()
        // 蒸汽
        builder.group(id: "steam").animate(
            attribute: "opacity",
            values: ["0.15", "0.8", "0.15"],
            dur: "1.6s",
            repeatCount: "indefinite"
        )
        builder.path(d: "M-26 -100 Q-36 -114 -26 -128").stroke("#FFFFFF").strokeWidth(4.0)
            .attr("fill", "none").attr("stroke-linecap", "round")
        builder.path(d: "M0 -104 Q-10 -120 0 -136").stroke("#FFFFFF").strokeWidth(4.0)
            .attr("fill", "none").attr("stroke-linecap", "round")
        builder.path(d: "M26 -100 Q16 -114 26 -128").stroke("#FFFFFF").strokeWidth(4.0)
            .attr("fill", "none").attr("stroke-linecap", "round")
        builder.end()
        builder.end()
        builder.rect(x: 147.0, y: 352.0, width: 110.0, height: 26.0, rx: 8.0, ry: 8.0).fill("#EAF2FF")
        this.addFountainLabel(builder, 152.0, 371.0, 15.0)
    }
    /** 内置 Hershey 只有大写字母，这里用矢量笔画写小写 “fountain”。 */
    private func addFountainLabel(
        builder: SvgBuilder,
        x: Float64,
        baseline: Float64,
        size: Float64
    ): Unit {
        builder.group(id: "fountain-label")
        let unit = size / 6.0
        let advances = [4.6, 4.8, 4.8, 4.8, 4.2, 4.8, 3.2, 4.8]
        let letters = ["f", "o", "u", "n", "t", "a", "i", "n"]
        var pen = x
        for (index in 0..letters.size) {
            let letter = letters[index]
            let left = pen
            let bottom = baseline
            let top = baseline - 6.0 * unit
            match (letter) {
                case "o" =>
                    builder.ellipse(
                        cx: left + 2.0 * unit,
                        cy: baseline - 3.0 * unit,
                        rx: 1.7 * unit,
                        ry: 2.5 * unit
                    ).stroke("#4D6BFE").strokeWidth(1.6 * unit).attr("fill", "none")
                case "f" =>
                    builder.path(d: "M${left + 2.0 * unit} ${bottom} L${left + 2.0 * unit} ${top + unit} Q${left + 2.0 * unit} ${top} ${left + 3.0 * unit} ${top} Q${left + 4.0 * unit} ${top} ${left + 4.0 * unit} ${top + unit} M${left + unit} ${baseline - 3.5 * unit} L${left + 3.0 * unit} ${baseline - 3.5 * unit}")
                        .stroke("#4D6BFE").strokeWidth(1.6 * unit).attr("fill", "none")
                        .attr("stroke-linecap", "round")
                case "u" =>
                    builder.path(d: "M${left + 0.5 * unit} ${baseline - 5.0 * unit} L${left + 0.5 * unit} ${baseline - 1.2 * unit} Q${left + 0.5 * unit} ${bottom} ${left + 2.0 * unit} ${bottom} Q${left + 3.5 * unit} ${bottom} ${left + 3.5 * unit} ${baseline - 1.2 * unit} L${left + 3.5 * unit} ${baseline - 5.0 * unit}")
                        .stroke("#4D6BFE").strokeWidth(1.6 * unit).attr("fill", "none")
                        .attr("stroke-linecap", "round")
                case "n" =>
                    builder.path(d: "M${left + 0.5 * unit} ${baseline - 5.0 * unit} L${left + 0.5 * unit} ${bottom} M${left + 0.5 * unit} ${baseline - 3.6 * unit} Q${left + 0.5 * unit} ${baseline - 5.0 * unit} ${left + 2.0 * unit} ${baseline - 5.0 * unit} Q${left + 3.5 * unit} ${baseline - 5.0 * unit} ${left + 3.5 * unit} ${baseline - 3.6 * unit} L${left + 3.5 * unit} ${bottom}")
                        .stroke("#4D6BFE").strokeWidth(1.6 * unit).attr("fill", "none")
                        .attr("stroke-linecap", "round")
                case "t" =>
                    builder.path(d: "M${left + 1.6 * unit} ${top} L${left + 1.6 * unit} ${baseline - unit} Q${left + 1.6 * unit} ${bottom} ${left + 3.0 * unit} ${bottom} M${left + 0.5 * unit} ${baseline - 4.4 * unit} L${left + 3.2 * unit} ${baseline - 4.4 * unit}")
                        .stroke("#4D6BFE").strokeWidth(1.6 * unit).attr("fill", "none")
                        .attr("stroke-linecap", "round")
                case "a" =>
                    builder.path(d: "M${left + 3.5 * unit} ${baseline - 5.0 * unit} L${left + 3.5 * unit} ${bottom} M${left + 3.5 * unit} ${baseline - 3.6 * unit} Q${left + 3.5 * unit} ${baseline - 5.0 * unit} ${left + 2.0 * unit} ${baseline - 5.0 * unit} Q${left + 0.5 * unit} ${baseline - 5.0 * unit} ${left + 0.5 * unit} ${baseline - 2.5 * unit} Q${left + 0.5 * unit} ${bottom} ${left + 2.0 * unit} ${bottom} Q${left + 3.5 * unit} ${bottom} ${left + 3.5 * unit} ${baseline - 1.4 * unit}")
                        .stroke("#4D6BFE").strokeWidth(1.6 * unit).attr("fill", "none")
                        .attr("stroke-linecap", "round")
                case "i" =>
                    builder.path(d: "M${left + unit} ${baseline - 4.0 * unit} L${left + unit} ${bottom}")
                        .stroke("#4D6BFE").strokeWidth(1.6 * unit).attr("fill", "none")
                        .attr("stroke-linecap", "round")
                    builder.circle(cx: left + unit, cy: baseline - 5.4 * unit, r: 0.55 * unit)
                        .fill("#4D6BFE")
                case _ => ()
            }
            pen += advances[index] * unit
        }
        builder.end()
    }

}
