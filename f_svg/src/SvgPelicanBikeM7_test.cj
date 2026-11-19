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
import std.fs.{File, Path}
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 生成两幅故事动图：
 * - 草原：鹈鹕在公路上骑自行车，路旁羊群吃草，晴 / 阴 / 雨 / 雪每 3 秒循环；
 * - 海边：同一只鹈鹕沿海滨公路骑行，海面有鲨鱼鳍，远处椰岛，天气同样四季循环。
 */
@Test
public class SvgPelicanBikeM7_test {
    private static let KEY_TIMES = "0;0.2083;0.25;0.4583;0.5;0.7083;0.75;0.9583;1"
    private static let SKY_VALUES = [
        "#7ec9f0", "#7ec9f0", "#9db0bf", "#9db0bf", "#54697b",
        "#54697b", "#c3d2e0", "#c3d2e0", "#7ec9f0"
    ]
    private static let SEA_VALUES = [
        "#2f9fc9", "#2f9fc9", "#5f8798", "#5f8798", "#35545f",
        "#35545f", "#7fa8bb", "#7fa8bb", "#2f9fc9"
    ]
    private static let CLOUD_VALUES = ["0.5", "0.5", "1", "1", "0.95", "0.95", "0.8", "0.8", "0.5"]
    private static let SUN_VALUES = ["1", "1", "0", "0", "0", "0", "0", "0", "1"]
    private static let RAIN_VALUES = ["0", "0", "0", "0", "1", "1", "0", "0", "0"]
    private static let SNOW_VALUES = ["0", "0", "0", "0", "0", "0", "1", "1", "0"]
    private static let DARK_VALUES = ["0", "0", "0.05", "0.05", "0.16", "0.16", "0.1", "0.1", "0"]

    // ------------------------------------------------------------------
    // 用例
    // ------------------------------------------------------------------

    /** 草原场景：一只鹈鹕骑车穿过四季。 */
    @TestCase
    public func pelicanRidesMeadowThroughFourWeathers(): Unit {
        let builder = this.buildMeadow()
        let svg = builder.toSvgString()

        @Assert(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        @Assert(svg.contains("<title>骑自行车的鹈鹕 · 草原羊群 · 四季天气循环</title>"))
        @Assert(svg.contains("id=\"rider\""))
        @Assert(svg.contains("id=\"sky\""))
        @Assert(svg.contains("url(#grassF)"))

        let target = Path("target/pelican-weather.svg")
        builder.save(target)
        let parsed = SvgParser.parse(target)
        @Assert(parsed.root.tag == "svg")

        let sky = parsed.elementById("sky").getOrThrow()
        let skyAnimate = sky.child("animate").getOrThrow()
        @Assert(skyAnimate.attr("attributeName") == Some("fill"))
        @Assert(skyAnimate.attr("dur") == Some("12s"))
        @Assert(skyAnimate.attr("keyTimes") == Some(KEY_TIMES))
        @Assert(skyAnimate.attr("repeatCount") == Some("indefinite"))

        let sun = parsed.elementById("sun").getOrThrow()
        let sunFade = sun.child("animate").getOrThrow()
        @Assert(sunFade.attr("attributeName") == Some("opacity"))
        @Assert(sunFade.attr("dur") == Some("12s"))

        for (index in 1..5) {
            let sheepId = "sheep-" + index.toString()
            let sheep = parsed.elementById(sheepId).getOrThrow()
            @Assert(sheep.children.size > 4)
            let bob = parsed.elementById(sheepId + "-move").getOrThrow()
            let bobAnimate = bob.child("animateTransform").getOrThrow()
            @Assert(bobAnimate.attr("type") == Some("translate"))
            @Assert(parsed.elementById(sheepId + "-graze").getOrThrow().child("animateTransform").isSome())
        }

        for (wheel in ["wheel-rear", "wheel-front"]) {
            let spin = parsed.elementById(wheel).getOrThrow().child("animateTransform").getOrThrow()
            @Assert(spin.attr("type") == Some("rotate"))
            @Assert(spin.attr("dur") == Some("0.55s"))
        }

        for (leg in ["leg-near-thigh", "leg-far-thigh"]) {
            let pedal = parsed.elementById(leg).getOrThrow().child("animate").getOrThrow()
            @Assert(pedal.attr("attributeName") == Some("d"))
            @Assert(pedal.attr("dur") == Some("1s"))
            @Assert(pedal.attr("repeatCount") == Some("indefinite"))
        }

        let rain = parsed.elementById("rain").getOrThrow()
        @Assert(rain.child("animate").getOrThrow().attr("attributeName") == Some("opacity"))
        @Assert(rain.children.size > 40)

        let snow = parsed.elementById("snow").getOrThrow()
        @Assert(snow.child("animate").getOrThrow().attr("attributeName") == Some("opacity"))
        @Assert(snow.children.size > 30)

        let golden = String.fromUtf8(File.readFrom(Path("testdata/story/pelican-weather.svg")))
        @Assert(golden == svg)
        println("PELICAN_MEADOW_SVG=${target}")
    }

    /** 海边场景：海滨公路、椰岛、鲨鱼鳍与四季天气。 */
    @TestCase
    public func pelicanRidesBeachThroughFourWeathers(): Unit {
        let builder = this.buildBeach()
        let svg = builder.toSvgString()

        @Assert(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        @Assert(svg.contains("<title>海边公路上骑自行车的鹈鹕 · 椰岛鲨鱼 · 四季天气循环</title>"))
        @Assert(svg.contains("id=\"sea\""))
        @Assert(svg.contains("url(#sandG)"))

        let target = Path("target/pelican-beach-weather.svg")
        builder.save(target)
        let parsed = SvgParser.parse(target)
        @Assert(parsed.root.tag == "svg")

        let sky = parsed.elementById("sky").getOrThrow()
        @Assert(sky.child("animate").getOrThrow().attr("dur") == Some("12s"))

        let sea = parsed.elementById("sea").getOrThrow()
        let seaAnimate = sea.child("animate").getOrThrow()
        @Assert(seaAnimate.attr("attributeName") == Some("fill"))
        @Assert(seaAnimate.attr("keyTimes") == Some(KEY_TIMES))

        for (index in 1..4) {
            let sharkId = "shark-" + index.toString()
            @Assert(parsed.elementById(sharkId).isSome())
            let move = parsed.elementById(sharkId + "-move").getOrThrow()
            @Assert(move.child("animateTransform").isSome())
        }

        let island = parsed.elementById("island").getOrThrow()
        @Assert(island.children.size > 6)
        @Assert(parsed.elementById("palm").isSome())
        let palm = parsed.elementById("palm-leaves").getOrThrow()
        @Assert(palm.child("animateTransform").isSome())

        for (index in 1..4) {
            let sheepId = "beach-sheep-" + index.toString()
            @Assert(parsed.elementById(sheepId).isSome())
            @Assert(parsed.elementById(sheepId + "-graze").isSome())
        }

        for (index in 1..6) {
            @Assert(parsed.elementById("cloud-" + index.toString()).isSome())
        }

        let rain = parsed.elementById("rain").getOrThrow()
        @Assert(rain.children.size > 40)
        let snow = parsed.elementById("snow").getOrThrow()
        @Assert(snow.children.size > 30)
        @Assert(parsed.elementById("rider").isSome())

        let golden = String.fromUtf8(File.readFrom(Path("testdata/story/pelican-beach-weather.svg")))
        @Assert(golden == svg)
        println("PELICAN_BEACH_SVG=${target}")
    }

    // ------------------------------------------------------------------
    // 场景装配
    // ------------------------------------------------------------------

    private func buildMeadow(): SvgBuilder {
        let builder = SvgBuilder(900.0, 520.0, viewBox: SvgViewBox(0.0, 0.0, 900.0, 520.0))
        builder.attr("font-family", "sans-serif")

        builder.rect(x: 0.0, y: 0.0, width: 900.0, height: 520.0)
            .fill("#7ec9f0")
            .id("sky")
            .animate(
                attribute: "fill",
                values: SvgPelicanBikeM7_test.SKY_VALUES,
                dur: "12s",
                keyTimes: KEY_TIMES,
                repeatCount: "indefinite"
            )
        this.addSun(builder, 762.0, 92.0)
        this.addCloud(builder, "cloud-1", 180.0, 96.0, 1.0, 0.0, "26s")
        this.addCloud(builder, "cloud-2", 520.0, 66.0, 0.8, -6.0, "34s")
        this.addCloud(builder, "cloud-3", 690.0, 150.0, 0.7, -14.0, "30s")
        this.addCloud(builder, "cloud-4", 330.0, 160.0, 0.6, -20.0, "38s")

        this.addMeadowGround(builder)
        builder.ellipse(cx: 400.0, cy: 431.0, rx: 118.0, ry: 8.0)
            .fill("#1c2a1c")
            .attr("opacity", "0.22")
        this.addRider(builder, 0.0, 36.0)
        this.addWeatherOverlays(builder, 384.0)
        this.installMeadowProlog(builder)
        builder
    }

    private func buildBeach(): SvgBuilder {
        let builder = SvgBuilder(900.0, 520.0, viewBox: SvgViewBox(0.0, 0.0, 900.0, 520.0))
        builder.attr("font-family", "sans-serif")

        builder.rect(x: 0.0, y: 0.0, width: 900.0, height: 520.0)
            .fill("#7ec9f0")
            .id("sky")
            .animate(
                attribute: "fill",
                values: SvgPelicanBikeM7_test.SKY_VALUES,
                dur: "12s",
                keyTimes: KEY_TIMES,
                repeatCount: "indefinite"
            )
        this.addSun(builder, 138.0, 76.0)
        this.addCloud(builder, "cloud-1", 255.0, 58.0, 1.0, 0.0, "26s")
        this.addCloud(builder, "cloud-2", 520.0, 52.0, 0.8, -6.0, "34s")
        this.addCloud(builder, "cloud-3", 700.0, 118.0, 0.7, -14.0, "30s")
        this.addCloud(builder, "cloud-4", 340.0, 152.0, 0.6, -20.0, "38s")
        this.addCloud(builder, "cloud-5", 60.0, 150.0, 0.5, -26.0, "44s")

        this.addSea(builder)
        this.addIsland(builder)
        this.addShark(builder, "shark-1", 150.0, 282.0, 1.1, 26.0, "9.5s", 0.0)
        this.addShark(builder, "shark-2", 620.0, 258.0, 0.8, -22.0, "11s", -2.4)
        this.addShark(builder, "shark-3", 806.0, 300.0, 1.1, 18.0, "10.5s", -4.6)
        this.addSeaCrests(builder)

        builder.rect(x: 0.0, y: 330.0, width: 900.0, height: 64.0).fill("url(#sandG)")
        this.addFoam(builder)
        builder.rect(x: 0.0, y: 342.0, width: 900.0, height: 10.0)
            .fill("#d8b678")
            .attr("opacity", "0.55")
        this.addShell(builder, 96.0, 372.0, 0.9, "#fdf6e6")
        this.addShell(builder, 430.0, 380.0, 0.7, "#ffe9d0")
        this.addShell(builder, 694.0, 368.0, 0.8, "#fdf6e6")
        this.addStarfish(builder, 250.0, 378.0, 0.85)

        this.addSheep(builder, 120.0, 358.0, 0.7, 0.0, "beach-sheep-1")
        this.addSheep(builder, 214.0, 364.0, -0.6, -0.9, "beach-sheep-2")
        this.addSheep(builder, 686.0, 360.0, -0.6, -1.8, "beach-sheep-3")

        this.addBeachRoad(builder)
        builder.rect(x: 0.0, y: 466.0, width: 900.0, height: 54.0).fill("url(#sandFG)")
        builder.path(d: "M0,466 Q150,460 300,468 Q470,476 620,466 Q760,458 900,467 L900,472 L0,472 Z")
            .fill("#f3dfb4")
            .attr("opacity", "0.7")
        for (index in 0..14) {
            let x = 40.0 + Float64((index * 67) % 820)
            let y = 478.0 + Float64((index * 11) % 32)
            let rx = 2.8 + Float64(index % 3) * 0.9
            builder.ellipse(cx: x, cy: y, rx: rx, ry: rx * 0.6)
                .fill("#c9a86c")
                .attr("opacity", "0.7")
        }
        this.addShell(builder, 760.0, 496.0, 1.0, "#fff3e0")
        this.addShell(builder, 150.0, 502.0, 0.8, "#fdf6e6")

        builder.ellipse(cx: 400.0, cy: 467.0, rx: 118.0, ry: 8.0)
            .fill("#1c2a1c")
            .attr("opacity", "0.22")
        this.addRider(builder, 0.0, 36.0)
        this.addWeatherOverlays(builder, 398.0)
        this.installBeachProlog(builder)
        builder
    }

    // ------------------------------------------------------------------
    // 天空、天气
    // ------------------------------------------------------------------

    private func addSun(builder: SvgBuilder, cx: Float64, cy: Float64): Unit {
        builder.group().id("sun").animate(
            attribute: "opacity",
            values: SvgPelicanBikeM7_test.SUN_VALUES,
            dur: "12s",
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        builder.group().transform("translate(${formatSvgNumber(cx)} ${formatSvgNumber(cy)})")
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            from: "0",
            to: "360",
            dur: "36s",
            repeatCount: "indefinite"
        )
        for (index in 0..12) {
            let angle = Float64(index) * 30.0
            builder.line(x1: 0.0, y1: -48.0, x2: 0.0, y2: -64.0)
                .stroke("#ffe27a")
                .strokeWidth(5.0)
                .attr("stroke-linecap", "round")
                .transform("rotate(${formatSvgNumber(angle)})")
        }
        builder.circle(cx: 0.0, cy: 0.0, r: 34.0).fill("#ffe680")
        builder.circle(cx: 0.0, cy: 0.0, r: 26.0).fill("#fff6c2")
        builder.end()
        builder.end()
        builder.end()
    }

    private func addCloud(
        builder: SvgBuilder,
        id: String,
        x: Float64,
        y: Float64,
        scale: Float64,
        begin: Float64,
        dur: String
    ): Unit {
        builder.group().id(id).animate(
            attribute: "opacity",
            values: SvgPelicanBikeM7_test.CLOUD_VALUES,
            dur: "12s",
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Translate,
            values: ["0,0", "-140,0", "0,0"],
            dur: dur,
            begin: SvgBegin.offset(begin),
            repeatCount: "indefinite"
        )
        builder.group().transform(
            "translate(${formatSvgNumber(x)} ${formatSvgNumber(y)}) scale(${formatSvgNumber(scale)})"
        )
        builder.ellipse(cx: 0.0, cy: 0.0, rx: 46.0, ry: 26.0).fill("#ffffff")
        builder.ellipse(cx: -38.0, cy: 8.0, rx: 30.0, ry: 18.0).fill("#ffffff")
        builder.ellipse(cx: 34.0, cy: 10.0, rx: 26.0, ry: 16.0).fill("#ffffff")
        builder.ellipse(cx: 6.0, cy: -16.0, rx: 26.0, ry: 18.0).fill("#ffffff")
        builder.end()
        builder.end()
        builder.end()
    }

    private func addWeatherOverlays(builder: SvgBuilder, splashY: Float64): Unit {
        builder.rect(x: 0.0, y: 0.0, width: 900.0, height: 520.0)
            .fill("#16222c")
            .attr("opacity", "0")
            .id("dark")
            .animate(
                attribute: "opacity",
                values: SvgPelicanBikeM7_test.DARK_VALUES,
                dur: "12s",
                keyTimes: KEY_TIMES,
                repeatCount: "indefinite"
            )
        this.addRain(builder)
        this.addSnow(builder)
        this.addSplash(builder, splashY)
    }

    private func addRain(builder: SvgBuilder): Unit {
        builder.group().id("rain").animate(
            attribute: "opacity",
            values: SvgPelicanBikeM7_test.RAIN_VALUES,
            dur: "12s",
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        let durations = ["0.5s", "0.6s", "0.7s", "0.8s", "0.9s"]
        let begins = ["0s", "-0.3s", "-0.6s", "-0.9s", "-1.2s", "-1.5s", "-1.8s"]
        for (index in 0..60) {
            let x = 8 + (index * 97) % 884
            let length = 12 + (index % 5) * 3
            builder.line(x1: 0.0, y1: 0.0, x2: 5.0, y2: Float64(length))
                .stroke("#e8f6ff")
                .strokeWidth(1.6)
                .attr("stroke-linecap", "round")
                .attr("opacity", "0.6")
                .animateTransform(
                    attribute: "transform",
                    transformType: SvgAnimationTransformType.Translate,
                    from: "${x} -260",
                    to: "${x} 540",
                    dur: durations[index % 5],
                    begin: SvgBegin.clock(begins[index % 7]),
                    repeatCount: "indefinite"
                )
        }
        builder.end()
    }

    private func addSnow(builder: SvgBuilder): Unit {
        builder.group().id("snow").animate(
            attribute: "opacity",
            values: SvgPelicanBikeM7_test.SNOW_VALUES,
            dur: "12s",
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        let durations = ["6.1s", "7.2s", "8.3s", "9.4s", "10.5s", "11.6s"]
        let sways = ["3.6s", "4.3s", "4.9s", "5.6s", "6.3s"]
        let begins = ["0s", "-0.8s", "-1.6s", "-2.4s", "-3.2s", "-4.1s", "-5.0s"]
        for (index in 0..44) {
            let x = 10 + (index * 83) % 880
            let radius = 1.6 + Float64(index % 4) * 0.8
            builder.group().animateTransform(
                attribute: "transform",
                transformType: SvgAnimationTransformType.Translate,
                from: "0 -40",
                to: "0 540",
                dur: durations[index % 6],
                begin: SvgBegin.clock(begins[index % 7]),
                repeatCount: "indefinite"
            )
            builder.group().animateTransform(
                attribute: "transform",
                transformType: SvgAnimationTransformType.Translate,
                values: ["-12,0", "12,0", "-12,0"],
                dur: sways[index % 5],
                repeatCount: "indefinite"
            )
            if (index % 6 == 0) {
                let tilt = Float64((index * 13) % 60)
                builder.path(d: "M0,-4 L0,4 M-4,0 L4,0 M-3,-2 L3,2 M-3,2 L3,-2")
                    .stroke("#ffffff")
                    .strokeWidth(1.1)
                    .attr("stroke-linecap", "round")
                    .attr("opacity", "0.85")
                    .transform("translate(${x} 0) rotate(${formatSvgNumber(tilt)})")
            } else {
                builder.circle(cx: Float64(x), cy: 0.0, r: radius)
                    .fill("#ffffff")
                    .attr("opacity", "0.85")
            }
            builder.end()
            builder.end()
        }
        builder.end()
    }

    private func addSplash(builder: SvgBuilder, baseY: Float64): Unit {
        builder.group().id("splash").animate(
            attribute: "opacity",
            values: SvgPelicanBikeM7_test.RAIN_VALUES,
            dur: "12s",
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        let begins = ["0s", "-0.1s", "-0.2s", "-0.3s", "-0.4s", "-0.5s", "-0.6s"]
        for (index in 0..16) {
            let x = 20.0 + Float64((index * 59) % 860)
            let y = baseY + Float64((index * 13) % 96)
            builder.ellipse(cx: x, cy: y, rx: 2.0, ry: 1.6)
                .attr("fill", "none")
                .stroke("#dff0ff")
                .strokeWidth(1.4)
                .attr("opacity", "0.5")
                .animate(
                    attribute: "rx",
                    values: ["2", "10"],
                    dur: "0.7s",
                    begin: SvgBegin.clock(begins[index % 7]),
                    repeatCount: "indefinite"
                )
                .animate(
                    attribute: "ry",
                    values: ["1", "3.4"],
                    dur: "0.7s",
                    begin: SvgBegin.clock(begins[index % 7]),
                    repeatCount: "indefinite"
                )
                .animate(
                    attribute: "opacity",
                    values: ["0.7", "0"],
                    dur: "0.7s",
                    begin: SvgBegin.clock(begins[index % 7]),
                    repeatCount: "indefinite"
                )
        }
        builder.end()
    }

    // ------------------------------------------------------------------
    // 草原
    // ------------------------------------------------------------------

    private func addMeadowGround(builder: SvgBuilder): Unit {
        builder.path(d: "M0,342 L120,286 L210,330 L300,292 L410,342 Z")
            .fill("#8fbd7e")
            .attr("opacity", "0.9")
        builder.path(d: "M380,342 L500,300 L600,336 L700,296 L820,342 L900,320 L900,342 Z")
            .fill("#9ac78a")
            .attr("opacity", "0.9")
        builder.rect(x: 0.0, y: 334.0, width: 900.0, height: 100.0).fill("url(#grassB)")
        builder.rect(x: 0.0, y: 352.0, width: 900.0, height: 78.0).fill("url(#roadG)")
        builder.rect(x: 0.0, y: 352.0, width: 900.0, height: 4.0).fill("#8b959c")
        builder.rect(x: 0.0, y: 424.0, width: 900.0, height: 6.0).fill("#3b444a")
        this.addLaneDashes(builder, 374.0)
        this.addLaneDashes(builder, 412.0)
        builder.rect(x: 0.0, y: 430.0, width: 900.0, height: 90.0).fill("url(#grassF)")
        builder.path(d: "M0,430 Q120,424 260,432 Q420,440 560,430 Q720,420 900,431 L900,436 L0,436 Z")
            .fill("#6cbd5e")
            .attr("opacity", "0.8")

        this.addGrassTufts(builder, 30, 436.0)
        this.addFlower(builder, 60.0, 470.0, "#ffe066")
        this.addFlower(builder, 250.0, 500.0, "#ff9db0")
        this.addFlower(builder, 640.0, 486.0, "#ffffff")
        this.addFlower(builder, 500.0, 512.0, "#ffd166")
        this.addFlower(builder, 150.0, 508.0, "#ffffff")

        this.addSheep(builder, 92.0, 476.0, 1.1, 0.0, "sheep-1")
        this.addSheep(builder, 198.0, 478.0, -0.7, -0.9, "sheep-2")
        this.addSheep(builder, 736.0, 470.0, -0.9, -1.8, "sheep-3")
        this.addSheep(builder, 834.0, 484.0, 0.6, -2.7, "sheep-4")
    }

    private func addLaneDashes(builder: SvgBuilder, y: Float64): Unit {
        builder.line(x1: -100.0, y1: y, x2: 1000.0, y2: y)
            .stroke("#efe6c2")
            .strokeWidth(5.0)
            .attr("stroke-dasharray", "52 40")
            .attr("opacity", "0.85")
            .animate(
                attribute: "stroke-dashoffset",
                from: "0",
                to: "92",
                dur: "1s",
                repeatCount: "indefinite"
            )
    }

    private func addGrassTufts(builder: SvgBuilder, count: Int64, baseY: Float64): Unit {
        builder.group().attr("opacity", "0.85")
        for (index in 0..count) {
            let x = 8.0 + Float64((index * 41) % 876)
            let y = baseY + Float64((index * 23) % 76)
            let dx = 4.0 + Float64(index % 4) * 1.7
            let dy = 6.0 + Float64(index % 5) * 2.0
            builder.path(
                d: "M${formatSvgNumber(x)},${formatSvgNumber(y)} " +
                    "q${formatSvgNumber(dx)},${formatSvgNumber(-dy * 0.7)} " +
                    "${formatSvgNumber(dx * 1.6)},${formatSvgNumber(-dy)}"
            )
                .stroke("#3f8f3c")
                .strokeWidth(2.2)
                .attr("fill", "none")
                .attr("stroke-linecap", "round")
        }
        builder.end()
    }

    private func addFlower(builder: SvgBuilder, x: Float64, y: Float64, color: String): Unit {
        builder.group().transform("translate(${formatSvgNumber(x)} ${formatSvgNumber(y)})")
        builder.circle(cx: 0.0, cy: 0.0, r: 3.2).fill(color)
        for (index in 0..5) {
            let angle = Float64(index) * 72.0 * 3.141592653589793 / 180.0
            builder.circle(cx: cos(angle) * 3.6, cy: sin(angle) * 3.6, r: 2.6).fill(color)
        }
        builder.end()
    }

    // ------------------------------------------------------------------
    // 海边
    // ------------------------------------------------------------------

    private func addSea(builder: SvgBuilder): Unit {
        builder.rect(x: 0.0, y: 196.0, width: 900.0, height: 136.0)
            .fill("#2f9fc9")
            .id("sea")
            .animate(
                attribute: "fill",
                values: SvgPelicanBikeM7_test.SEA_VALUES,
                dur: "12s",
                keyTimes: KEY_TIMES,
                repeatCount: "indefinite"
            )
        builder.rect(x: 0.0, y: 196.0, width: 900.0, height: 6.0)
            .fill("#cfedf8")
            .attr("opacity", "0.5")
        builder.rect(x: 0.0, y: 202.0, width: 900.0, height: 26.0)
            .fill("#bfe6f5")
            .attr("opacity", "0.25")

        let drifts = ["13", "-24", "19", "-10", "16", "-18", "21", "-14", "9", "-22"]
        let durations = ["6.4s", "7.5s", "8.8s", "9.6s", "10.5s"]
        let opacities = ["0.22", "0.31", "0.38", "0.27", "0.17"]
        for (index in 0..24) {
            let x = 4.0 + Float64((index * 53) % 780)
            let y = 206.0 + Float64((index * 17) % 110)
            let width = 20.0 + Float64(index % 4) * 14.0
            builder.path(
                d: "M${formatSvgNumber(x)},${formatSvgNumber(y)} " +
                    "q${formatSvgNumber(width / 2.0)},-2 ${formatSvgNumber(width)},0"
            )
                .stroke("#e8f8ff")
                .strokeWidth(1.6)
                .attr("fill", "none")
                .attr("stroke-linecap", "round")
                .attr("opacity", opacities[index % 5])
                .animateTransform(
                    attribute: "transform",
                    transformType: SvgAnimationTransformType.Translate,
                    values: ["0,0", drifts[index % 10] + ",0", "0,0"],
                    dur: durations[index % 5],
                    repeatCount: "indefinite"
                )
        }
    }

    private func addSeaCrests(builder: SvgBuilder): Unit {
        let drifts = ["-38", "15", "-15", "37", "-18", "29", "-19", "24", "37", "-16", "-24", "-34"]
        let durations = ["6.6s", "5.1s", "8.5s", "8.9s", "6.3s"]
        let widths = [3.1, 2.5, 3.4, 3.3, 4.2, 3.4, 3.2, 2.6, 3.2, 2.8, 2.6, 3.6]
        for (index in 0..12) {
            let x = 60.0 + Float64((index * 71) % 760)
            let y = 267.0 + Float64((index * 29) % 54)
            let width = 55.0 + Float64(index % 4) * 22.0
            builder.path(
                d: "M${formatSvgNumber(x)},${formatSvgNumber(y)} " +
                    "q${formatSvgNumber(width / 2.0)},-4 ${formatSvgNumber(width)},0 " +
                    "t${formatSvgNumber(width)},0"
            )
                .stroke("#ffffff")
                .strokeWidth(widths[index])
                .attr("fill", "none")
                .attr("stroke-linecap", "round")
                .attr("opacity", "0.3")
                .animateTransform(
                    attribute: "transform",
                    transformType: SvgAnimationTransformType.Translate,
                    values: ["0,0", drifts[index] + ",0", "0,0"],
                    dur: durations[index % 5],
                    repeatCount: "indefinite"
                )
        }
    }

    private func addIsland(builder: SvgBuilder): Unit {
        builder.group().id("island")
        builder.ellipse(cx: 812.0, cy: 199.0, rx: 74.0, ry: 7.0)
            .fill("#0d4a60")
            .attr("opacity", "0.28")
        builder.path(d: "M744,198 Q772,164 806,166 Q850,168 872,198 Z").fill("#ead9a8")
        builder.path(d: "M760,197 Q788,172 808,174 Q840,176 858,197 Z").fill("#78bb62")
        builder.path(d: "M772,196 Q796,180 812,182 Q834,183 846,196 Z")
            .fill("#8fcc74")
            .attr("opacity", "0.8")
        builder.path(d: "M798,177 C796,159 794,143 790,127 L800,125 C804,141 806,159 808,177 Z")
            .fill("#b08155")
        builder.path(d: "M800,177 C798,160 796,145 793,131 L797,130 C800,144 802,160 804,177 Z")
            .fill("#c69365")

        builder.group().id("palm").transform("translate(795 125)")
        builder.group().id("palm-leaves").animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["-2 -5 52", "2.2 -5 52", "-2 -5 52"],
            dur: "5.5s",
            repeatCount: "indefinite"
        )
        for (index in 0..6) {
            let angle = -172.0 + Float64(index) * 38.0
            builder.group().transform("rotate(${formatSvgNumber(angle)})")
            builder.path(d: "M0,0 Q24,-13 47,-5 Q26,7 0,0 Z").fill("#4e9b46")
            builder.path(d: "M2,-1 Q24,-8 44,-4")
                .stroke("#3d7d38")
                .strokeWidth(1.2)
                .attr("fill", "none")
            builder.end()
        }
        builder.circle(cx: 1.0, cy: 8.0, r: 4.3).fill("#6d4423")
        builder.circle(cx: 0.0, cy: 7.0, r: 1.3).fill("#a9784e").attr("opacity", "0.8")
        builder.circle(cx: 8.0, cy: 11.0, r: 4.3).fill("#6d4423")
        builder.circle(cx: 7.0, cy: 10.0, r: 1.3).fill("#a9784e").attr("opacity", "0.8")
        builder.circle(cx: -1.0, cy: 12.0, r: 4.3).fill("#6d4423")
        builder.circle(cx: -2.0, cy: 11.0, r: 1.3).fill("#a9784e").attr("opacity", "0.8")
        builder.end()
        builder.end()

        builder.ellipse(cx: 795.0, cy: 176.0, rx: 16.0, ry: 4.0)
            .fill("#3f7a3a")
            .attr("opacity", "0.35")
        builder.path(d: "M756,197 q6,-9 12,0")
            .stroke("#5fa84f")
            .strokeWidth(2.4)
            .attr("fill", "none")
        builder.path(d: "M862,197 q-5,-8 -11,-1")
            .stroke("#5fa84f")
            .strokeWidth(2.4)
            .attr("fill", "none")
        builder.end()
    }

    private func addShark(
        builder: SvgBuilder,
        id: String,
        x: Float64,
        y: Float64,
        scale: Float64,
        drift: Float64,
        dur: String,
        begin: Float64
    ): Unit {
        builder.group()
            .id(id)
            .transform(
                "translate(${formatSvgNumber(x)} ${formatSvgNumber(y)}) scale(${formatSvgNumber(scale)})"
            )
        builder.group().id(id + "-move").animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Translate,
            values: ["0,0", "${formatSvgNumber(drift)},0", "0,0"],
            dur: dur,
            begin: SvgBegin.offset(begin),
            repeatCount: "indefinite"
        )
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Translate,
            values: ["0,0", "0,-1.8", "0,0"],
            dur: "2.6s",
            begin: SvgBegin.offset(begin),
            repeatCount: "indefinite"
        )
        builder.ellipse(cx: 0.0, cy: 1.0, rx: 21.0, ry: 3.2)
            .fill("#eaf7fc")
            .attr("opacity", "0.5")
        builder.path(d: "M-14,1 C-7,-4 -1,-17 3,-17 C11,-14 15,-5 16,1 Z").fill("#42525c")
        builder.path(d: "M-6,-6 C-2,-11 1,-14 3,-15 C2,-9 0,-4 -2,0 Z")
            .fill("#5b6f7b")
            .attr("opacity", "0.85")
        builder.path(d: "M-22,1 q22,-5 40,0")
            .stroke("#dff4fb")
            .strokeWidth(1.8)
            .attr("fill", "none")
            .attr("opacity", "0.75")
        builder.end()
        builder.end()
        builder.end()
    }

    private func addFoam(builder: SvgBuilder): Unit {
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Translate,
            values: ["0,0", "14,0", "0,0"],
            dur: "7s",
            repeatCount: "indefinite"
        )
        builder.path(d: "M0,332 q30,-7 60,0 t60,0 t60,0 t60,0 t60,0 t60,0 t60,0 t60,0 " +
            "t60,0 t60,0 t60,0 t60,0 t60,0 t60,0 L900,344 L0,344 Z")
            .fill("#ffffff")
            .attr("opacity", "0.85")
        builder.path(d: "M0,340 q45,6 90,0 t90,0 t90,0 t90,0 t90,0 t90,0 t90,0 t90,0 " +
            "t90,0 t90,0 L900,350 L0,350 Z")
            .fill("#f4fbff")
            .attr("opacity", "0.5")
        builder.end()
    }

    private func addBeachRoad(builder: SvgBuilder): Unit {
        builder.rect(x: 0.0, y: 392.0, width: 900.0, height: 74.0).fill("url(#roadG)")
        builder.rect(x: 0.0, y: 392.0, width: 900.0, height: 4.0).fill("#98a3aa")
        builder.rect(x: 0.0, y: 460.0, width: 900.0, height: 6.0).fill("#3b444a")
        this.addLaneDashes(builder, 406.0)
        this.addLaneDashes(builder, 452.0)
    }

    private func addShell(builder: SvgBuilder, x: Float64, y: Float64, scale: Float64, color: String): Unit {
        builder.group().transform(
            "translate(${formatSvgNumber(x)} ${formatSvgNumber(y)}) scale(${formatSvgNumber(scale)})"
        )
        builder.path(d: "M0,0 q-9,-6 -9,-11 q0,-5 4.5,-5 q4.5,0 4.5,5 q0,5 4.5,5 q4.5,0 4.5,-5 " +
            "q0,-5 4.5,-5 q4.5,0 4.5,5 q0,5 -9,11 z")
            .fill(color)
            .stroke("#c99f63")
            .strokeWidth(0.8)
        builder.end()
    }

    private func addStarfish(builder: SvgBuilder, x: Float64, y: Float64, scale: Float64): Unit {
        builder.group().transform(
            "translate(${formatSvgNumber(x)} ${formatSvgNumber(y)}) scale(${formatSvgNumber(scale)})"
        )
        builder.path(d: "M0,-9 L3,-2 L10,-2 L4.5,2.5 L7,10 L0,5.5 L-7,10 L-4.5,2.5 L-10,-2 L-3,-2 Z")
            .fill("#f08a5d")
            .stroke("#cf6b41")
            .strokeWidth(1.0)
        builder.end()
    }

    // ------------------------------------------------------------------
    // 鹈鹕与自行车
    // ------------------------------------------------------------------

    private func addRider(builder: SvgBuilder, offsetX: Float64, offsetY: Float64): Unit {
        builder.group()
            .id("rider")
            .transform("translate(${formatSvgNumber(offsetX)} ${formatSvgNumber(offsetY)})")

        // 远侧曲柄与脚踏
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["-90 400 396", "270 400 396"],
            dur: "1s",
            repeatCount: "indefinite"
        )
        builder.line(x1: 400.0, y1: 396.0, x2: 400.0, y2: 380.0)
            .stroke("#8d959b")
            .strokeWidth(4.0)
        builder.rect(x: 391.0, y: 381.0, width: 18.0, height: 5.0, rx: 2.0, ry: 2.0)
            .fill("#5d5d5d")
        builder.end()

        this.addPedalingLeg(builder, 388.0, 338.0, -90.0, "#e9dfc6", "leg-far")

        this.addWheel(builder, 330.0, 396.0, "wheel-rear")
        this.addWheel(builder, 472.0, 396.0, "wheel-front")

        // 车架
        builder.path(d: "M378,340 L400,396 M378,340 L330,396 M330,396 L400,396 " +
            "M400,396 L455,342 M378,340 L455,342 M455,342 L472,396")
            .stroke("#d94f3d")
            .strokeWidth(7.0)
            .attr("fill", "none")
            .attr("stroke-linecap", "round")
        builder.path(d: "M330,389 L400,388 M330,403 L400,404")
            .stroke("#7b8388")
            .strokeWidth(2.4)
            .attr("fill", "none")
            .attr("opacity", "0.9")
        builder.circle(cx: 400.0, cy: 396.0, r: 9.0)
            .stroke("#8d959b")
            .strokeWidth(3.0)
            .attr("fill", "none")
        builder.path(d: "M358,340 q14,-7 30,-1 q4,6 -6,8 l-24,1 q-6,-3 0,-8 z").fill("#3a3f44")
        builder.line(x1: 378.0, y1: 340.0, x2: 378.0, y2: 348.0)
            .stroke("#8d959b")
            .strokeWidth(4.0)
        builder.path(d: "M455,342 L452,328 Q452,320 440,318 Q432,317 430,324")
            .stroke("#8d959b")
            .strokeWidth(5.0)
            .attr("fill", "none")
            .attr("stroke-linecap", "round")
        builder.circle(cx: 430.0, cy: 325.0, r: 4.0).fill("#2f3438")

        // 近侧曲柄与脚踏
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["90 400 396", "450 400 396"],
            dur: "1s",
            repeatCount: "indefinite"
        )
        builder.line(x1: 400.0, y1: 396.0, x2: 400.0, y2: 412.0)
            .stroke("#cfc3a6")
            .strokeWidth(4.0)
        builder.rect(x: 391.0, y: 413.0, width: 18.0, height: 5.0, rx: 2.0, ry: 2.0)
            .fill("#4a4a4a")
        builder.end()

        this.addPedalingLeg(builder, 381.0, 333.0, 90.0, "#cfc7b2", "leg-near")

        // 鹈鹕
        builder.path(d: "M352,306 Q322,294 312,304 Q322,318 348,320 Z").fill("#e6ddc6")
        builder.ellipse(cx: 394.0, cy: 304.0, rx: 52.0, ry: 40.0)
            .transform("rotate(-9 394 304)")
            .fill("#fbf8ee")
            .stroke("#e6dcc2")
            .strokeWidth(1.6)
        builder.path(d: "M352,318 q40,20 84,-2 q-8,26 -44,28 q-32,-2 -40,-26 z").fill("#f0e9d8")

        // 翅膀
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["-2 396 298", "2.5 396 298", "-2 396 298"],
            dur: "1.6s",
            repeatCount: "indefinite"
        )
        builder.path(d: "M366,288 Q394,268 426,286 Q418,318 380,318 Q364,306 366,288 Z")
            .fill("#ece3cd")
            .stroke("#ddd2b8")
            .strokeWidth(1.5)
        builder.path(d: "M372,296 q20,-8 40,0 M374,306 q18,-6 36,2")
            .stroke("#d9cdb1")
            .strokeWidth(2.0)
            .attr("fill", "none")
        builder.end()

        // 脖颈
        builder.path(d: "M414,288 C426,262 436,246 448,238")
            .stroke("#fbf8ee")
            .strokeWidth(24.0)
            .attr("fill", "none")
            .attr("stroke-linecap", "round")
        builder.path(d: "M414,288 C426,262 436,246 448,238")
            .stroke("#f2ecdc")
            .strokeWidth(20.0)
            .attr("fill", "none")
            .attr("stroke-linecap", "round")
            .attr("opacity", "0.6")

        // 头与弧形喙囊
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["0 448 246", "1.6 448 246", "0 448 246", "-1.2 448 246", "0 448 246"],
            dur: "1.1s",
            repeatCount: "indefinite"
        )
        builder.circle(cx: 456.0, cy: 238.0, r: 19.0)
            .fill("#fbf8ee")
            .stroke("#e6dcc2")
            .strokeWidth(1.4)
        builder.path(d: "M440,222 q10,-6 20,0 q-6,-8 -12,-8 q-6,0 -8,8z").fill("#f0e6cf")
        builder.path(d: "M468,230 Q512,234 552,249 Q512,247 468,243 Z")
            .fill("#f5b942")
            .stroke("#dc9a26")
            .strokeWidth(1.2)
        builder.path(d: "M468,244 Q510,252 551,249 Q512,300 468,244 Z")
            .fill("#f7c96b")
            .stroke("#dc9a26")
            .strokeWidth(1.4)
        builder.path(d: "M468,244 Q510,252 551,249")
            .stroke("#dc9a26")
            .strokeWidth(1.6)
            .attr("fill", "none")
        builder.path(d: "M486,254 q10,16 26,22")
            .stroke("#eab24c")
            .strokeWidth(1.2)
            .attr("fill", "none")
            .attr("opacity", "0.8")
        builder.circle(cx: 461.0, cy: 229.0, r: 4.4).fill("#2b2721")
        builder.circle(cx: 462.4, cy: 227.6, r: 1.5).fill("#ffffff")
        builder.end()

        builder.circle(cx: 447.0, cy: 330.0, r: 5.0)
            .fill("#f0c040")
            .stroke("#c99a20")
            .strokeWidth(1.2)
        builder.end()
    }

    /** 用两段连杆 IK 生成蹬踏路径，膝部随曲柄连续弯曲。 */
    private func addPedalingLeg(
        builder: SvgBuilder,
        hipX: Float64,
        hipY: Float64,
        startDeg: Float64,
        color: String,
        idPrefix: String
    ): Unit {
        let thighLength = 44.0
        let shinLength = 42.0
        let thigh = ArrayList<String>()
        let shin = ArrayList<String>()
        let kneeXs = ArrayList<String>()
        let kneeYs = ArrayList<String>()
        var firstKneeX = 0.0
        var firstKneeY = 0.0

        for (index in 0..25) {
            let t = Float64(index % 24) / 24.0
            let theta = (startDeg + 360.0 * t) * 3.141592653589793 / 180.0
            let footX = 400.0 + 16.0 * cos(theta)
            let footY = 396.0 + 16.0 * sin(theta)
            let dx = footX - hipX
            let dy = footY - hipY
            var distance = sqrt(dx * dx + dy * dy)
            let limit = thighLength + shinLength - 0.01
            if (distance > limit) {
                distance = limit
            }
            if (distance < 0.1) {
                distance = 0.1
            }
            let a = (thighLength * thighLength - shinLength * shinLength + distance * distance) /
                (2.0 * distance)
            var square = thighLength * thighLength - a * a
            if (square < 0.0) {
                square = 0.0
            }
            let h = sqrt(square)
            let ux = dx / distance
            let uy = dy / distance
            let kneeX = hipX + a * ux + h * uy
            let kneeY = hipY + a * uy - h * ux
            if (index == 0) {
                firstKneeX = kneeX
                firstKneeY = kneeY
            }
            thigh.add(
                "M${formatSvgNumber(hipX)},${formatSvgNumber(hipY)} " +
                    "L${formatSvgNumber(kneeX)},${formatSvgNumber(kneeY)}"
            )
            shin.add(
                "M${formatSvgNumber(kneeX)},${formatSvgNumber(kneeY)} " +
                    "L${formatSvgNumber(footX)},${formatSvgNumber(footY)}"
            )
            kneeXs.add(formatSvgNumber(kneeX))
            kneeYs.add(formatSvgNumber(kneeY))
        }

        builder.path(d: thigh[0])
            .id(idPrefix + "-thigh")
            .stroke(color)
            .strokeWidth(13.0)
            .attr("fill", "none")
            .attr("stroke-linecap", "round")
            .animate(attribute: "d", values: thigh.toArray(), dur: "1s", repeatCount: "indefinite")
        builder.path(d: shin[0])
            .id(idPrefix + "-shin")
            .stroke(color)
            .strokeWidth(8.0)
            .attr("fill", "none")
            .attr("stroke-linecap", "round")
            .animate(attribute: "d", values: shin.toArray(), dur: "1s", repeatCount: "indefinite")
        builder.circle(cx: firstKneeX, cy: firstKneeY, r: 6.5)
            .fill(color)
            .animate(attribute: "cx", values: kneeXs.toArray(), dur: "1s", repeatCount: "indefinite")
            .animate(attribute: "cy", values: kneeYs.toArray(), dur: "1s", repeatCount: "indefinite")
    }

    private func addWheel(builder: SvgBuilder, cx: Float64, cy: Float64, id: String): Unit {
        builder.group().id(id).animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            from: "0 ${formatSvgNumber(cx)} ${formatSvgNumber(cy)}",
            to: "360 ${formatSvgNumber(cx)} ${formatSvgNumber(cy)}",
            dur: "0.55s",
            repeatCount: "indefinite"
        )
        builder.circle(cx: cx, cy: cy, r: 34.0)
            .stroke("#2f3438")
            .strokeWidth(6.0)
            .attr("fill", "none")
        builder.circle(cx: cx, cy: cy, r: 27.0)
            .stroke("#c9d2d8")
            .strokeWidth(2.5)
            .attr("fill", "none")
        for (index in 0..12) {
            let angle = Float64(index) * 30.0 * 3.141592653589793 / 180.0
            builder.line(
                x1: cx,
                y1: cy,
                x2: cx + cos(angle) * 29.0,
                y2: cy + sin(angle) * 29.0
            )
                .stroke("#c9d2d8")
                .strokeWidth(2.0)
        }
        builder.circle(cx: cx, cy: cy, r: 4.0).fill("#8d959b")
        builder.circle(cx: cx, cy: cy, r: 3.0).fill("#5a6167")
        builder.end()
    }

    // ------------------------------------------------------------------
    // 羊
    // ------------------------------------------------------------------

    private func addSheep(
        builder: SvgBuilder,
        x: Float64,
        y: Float64,
        scale: Float64,
        begin: Float64,
        id: String
    ): Unit {
        let mirror = if (scale < 0.0) { -scale } else { scale }
        builder.group()
            .id(id)
            .transform(
                "translate(${formatSvgNumber(x)} ${formatSvgNumber(y)}) " +
                    "scale(${formatSvgNumber(scale)} ${formatSvgNumber(mirror)})"
            )

        let legOffsets = [-15.0, -7.0, 7.0, 15.0]
        let legBegins = [0.0, -0.2, -0.5, -0.8]
        for (index in 0..4) {
            builder.group().transform("translate(${formatSvgNumber(legOffsets[index])} 9)")
            builder.group().animateTransform(
                attribute: "transform",
                transformType: SvgAnimationTransformType.Rotate,
                values: ["0 0 0", "-2.5 0 0", "0 0 0"],
                dur: "3.6s",
                begin: SvgBegin.offset(begin + legBegins[index]),
                repeatCount: "indefinite"
            )
            builder.rect(x: -2.75, y: 0.0, width: 5.5, height: 27.0, rx: 2.7, ry: 2.7)
                .fill("#574c42")
            builder.rect(x: -3.2, y: 23.0, width: 6.4, height: 4.5, rx: 2.2, ry: 2.2)
                .fill("#332b24")
            builder.end()
            builder.end()
        }

        builder.group().id(id + "-move").animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Translate,
            values: ["0,0", "0,-1.4", "0,0"],
            dur: "3.6s",
            begin: SvgBegin.offset(begin),
            repeatCount: "indefinite"
        )
        builder.circle(cx: -15.0, cy: -6.0, r: 10.0).fill("#fdfbf3")
        builder.circle(cx: -3.0, cy: -11.0, r: 11.5).fill("#fdfbf3")
        builder.circle(cx: 10.0, cy: -8.0, r: 10.0).fill("#fdfbf3")
        builder.circle(cx: 19.0, cy: 1.0, r: 9.0).fill("#fdfbf3")
        builder.circle(cx: -20.0, cy: 4.0, r: 9.0).fill("#fdfbf3")
        builder.circle(cx: 4.0, cy: 2.0, r: 11.0).fill("#fdfbf3")
        builder.ellipse(cx: 6.0, cy: 7.0, rx: 15.0, ry: 7.0)
            .fill("#ece5d6")
            .attr("opacity", "0.5")

        // 尾巴
        builder.group().animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["-16 22 -4", "14 22 -4", "-16 22 -4"],
            dur: "2.4s",
            begin: SvgBegin.offset(begin),
            repeatCount: "indefinite"
        )
        builder.path(d: "M22,-6 q10,-6 9,2 q-6,4 -10,2 z").fill("#f6f1e4")
        builder.end()

        // 低头吃草
        builder.group().id(id + "-graze").animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: ["0 -22 -8", "0 -22 -8", "-62 -22 -8", "-62 -22 -8", "-52 -22 -8",
                "0 -22 -8", "0 -22 -8"],
            dur: "6.5s",
            begin: SvgBegin.offset(begin),
            repeatCount: "indefinite"
        )
        builder.ellipse(cx: -31.0, cy: -10.0, rx: 11.0, ry: 8.6)
            .transform("rotate(-12 -31 -10)")
            .fill("#f7f2e6")
        builder.ellipse(cx: -39.5, cy: -7.5, rx: 6.2, ry: 4.8)
            .transform("rotate(-8 -39.5 -7.5)")
            .fill("#e7dcc7")
        builder.circle(cx: -38.0, cy: -10.0, r: 1.4).fill("#3b332c")
        builder.path(d: "M-25,-14 q-9,-5 -13,0 q8,4 13,2 z")
            .fill("#efe8d8")
            .stroke("#d9ceb9")
            .strokeWidth(0.8)
        builder.path(d: "M-27,-18 q-3,-5 2,-6")
            .stroke("#d9ceb9")
            .strokeWidth(1.6)
            .attr("fill", "none")
        builder.end()

        builder.end()
        builder.end()
    }

    // ------------------------------------------------------------------
    // 文档前言与渐变
    // ------------------------------------------------------------------

    private func installMeadowProlog(builder: SvgBuilder): Unit {
        let defs = SvgElement("defs")
        defs.appendElement(this.verticalGradient("grassF", "#5cb254", "#2f7a35"))
        defs.appendElement(this.verticalGradient("grassB", "#7cc46a", "#57a44f"))
        defs.appendElement(this.verticalGradient("roadG", "#6b757d", "#4c555c"))
        this.prependToRoot(builder, defs)
        this.prependToRoot(builder, this.titleElement("骑自行车的鹈鹕 · 草原羊群 · 四季天气循环"))
        this.prependToRoot(
            builder,
            this.descElement("晴天/阴天/雨天/雪天 每 3 秒循环；鹈鹕蹬车、羊群低头吃草")
        )
    }

    private func installBeachProlog(builder: SvgBuilder): Unit {
        let defs = SvgElement("defs")
        defs.appendElement(this.verticalGradient("roadG", "#6b757d", "#4a5359"))
        defs.appendElement(this.verticalGradient("sandG", "#f6e5bb", "#e7c88c"))
        defs.appendElement(this.verticalGradient("sandFG", "#e9cd95", "#d3ad6f"))
        this.prependToRoot(builder, defs)
        this.prependToRoot(builder, this.titleElement("海边公路上骑自行车的鹈鹕 · 椰岛鲨鱼 · 四季天气循环"))
        this.prependToRoot(
            builder,
            this.descElement("晴天/阴天/雨天/雪天 每 3 秒循环；鹈鹕蹬车、羊群低头吃草、鲨鱼鳍游动")
        )
    }

    private func verticalGradient(id: String, top: String, bottom: String): SvgElement {
        let gradient = SvgElement("linearGradient")
        gradient.setAttr("id", id)
        gradient.setAttr("x1", "0")
        gradient.setAttr("y1", "0")
        gradient.setAttr("x2", "0")
        gradient.setAttr("y2", "1")
        let first = SvgElement("stop")
        first.setAttr("offset", "0")
        first.setAttr("stop-color", top)
        gradient.appendElement(first)
        let second = SvgElement("stop")
        second.setAttr("offset", "1")
        second.setAttr("stop-color", bottom)
        gradient.appendElement(second)
        gradient
    }

    private func titleElement(text: String): SvgElement {
        let title = SvgElement("title")
        title.appendText(text)
        title
    }

    private func descElement(text: String): SvgElement {
        let desc = SvgElement("desc")
        desc.appendText(text)
        desc
    }

    /** 插到根的第一个元素之前；`defs`、`title`、`desc` 用它在内容前落位。 */
    private func prependToRoot(builder: SvgBuilder, element: SvgElement): Unit {
        let root = builder.document().root
        for (index in 0..root.children.size) {
            match (root.children[index]) {
                case SvgNode.ElementNode(first) =>
                    root.insertBefore(SvgNode.ElementNode(element), Some(first))
                    return
                case _ => ()
            }
        }
        root.appendChild(SvgNode.ElementNode(element))
    }
}
