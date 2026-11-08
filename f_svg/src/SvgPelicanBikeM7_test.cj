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
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 生成故事动图：鹈鹕在公路上骑自行车，路旁草原上有三只羊，
 * 晴 / 阴 / 雨 / 雪四种天气每 3 秒切换一次（12 秒一轮）。
 */
@Test
public class SvgPelicanBikeM7_test {
    private static let KEY_TIMES = "0;0.25;0.5;0.75;1"

    @TestCase
    public func pelicanRidesThroughFourWeathers(): Unit {
        let builder = SvgBuilder(800.0, 450.0, viewBox: SvgViewBox(0.0, 0.0, 800.0, 450.0))

        // 兜底天空；四组天气各自覆盖整幅画面，用组透明度切换。
        builder.rect(x: 0.0, y: 0.0, width: 800.0, height: 450.0).fill("#87CEEB")

        this.addSunnyWeather(builder)
        this.addCloudyWeather(builder)
        this.addRainyWeather(builder)
        this.addSnowyWeather(builder)

        this.addLandscape(builder)
        this.addSheep(builder, 150.0, 302.0, "sheep-1")
        this.addSheep(builder, 330.0, 292.0, "sheep-2")
        this.addSheep(builder, 530.0, 308.0, "sheep-3")
        this.addRider(builder)

        let svg = builder.toSvgString()
        @Assert(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        @Assert(svg.contains("id=\"weather-sunny\""))
        @Assert(svg.contains("id=\"weather-cloudy\""))
        @Assert(svg.contains("id=\"weather-rainy\""))
        @Assert(svg.contains("id=\"weather-snowy\""))
        @Assert(svg.contains("id=\"rider\""))

        let target = Path("target/pelican-bike-weather.svg")
        builder.save(target)
        let parsed = SvgParser.parse(target)
        @Assert(parsed.root.tag == "svg")
        let golden = String.fromUtf8(File.readFrom(Path("testdata/story/pelican-bike-weather.svg")))
        @Assert(golden == svg)

        for (weather in ["weather-sunny", "weather-cloudy", "weather-rainy", "weather-snowy"]) {
            let group = parsed.elementById(weather).getOrThrow()
            let animate = group.child("animate").getOrThrow()
            @Assert(animate.attr("attributeName") == Some("opacity"))
            @Assert(animate.attr("dur") == Some("12s"))
            @Assert(animate.attr("repeatCount") == Some("indefinite"))
            @Assert(animate.attr("keyTimes") == Some(KEY_TIMES))
        }

        let rider = parsed.elementById("rider").getOrThrow()
        let move = rider.child("animateTransform").getOrThrow()
        @Assert(move.attr("type") == Some("translate"))
        @Assert(move.attr("dur") == Some("12s"))
        @Assert(move.attr("repeatCount") == Some("indefinite"))

        for (sheep in ["sheep-1", "sheep-2", "sheep-3"]) {
            @Assert(parsed.elementById(sheep).isSome())
        }
        println("PELICAN_SVG=${target}")
    }

    /** 晴天：蓝天、太阳与光芒。 */
    private func addSunnyWeather(builder: SvgBuilder): Unit {
        builder.group(id: "weather-sunny").animate(
            attribute: "opacity",
            values: ["1", "0", "0", "0", "1"],
            dur: "12s",
            calcMode: SvgCalcMode.Discrete,
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        builder.rect(x: 0.0, y: 0.0, width: 800.0, height: 450.0).fill("#87CEEB")
        builder.circle(cx: 675.0, cy: 85.0, r: 42.0).fill("#FFD54F")
        for (index in 0..8) {
            let angle = Float64(index) * 45.0 * 3.141592653589793 / 180.0
            let x1 = 675.0 + cos(angle) * 52.0
            let y1 = 85.0 + sin(angle) * 52.0
            let x2 = 675.0 + cos(angle) * 66.0
            let y2 = 85.0 + sin(angle) * 66.0
            builder.line(x1: x1, y1: y1, x2: x2, y2: y2)
                .stroke("#FFD54F")
                .strokeWidth(4.0)
                .attr("stroke-linecap", "round")
        }
        builder.end()
    }

    /** 阴天：三团灰云。 */
    private func addCloudyWeather(builder: SvgBuilder): Unit {
        builder.group(id: "weather-cloudy").animate(
            attribute: "opacity",
            values: ["0", "1", "0", "0", "0"],
            dur: "12s",
            calcMode: SvgCalcMode.Discrete,
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        builder.rect(x: 0.0, y: 0.0, width: 800.0, height: 450.0).fill("#B9C6D2")
        this.addCloud(builder, 180.0, 90.0, 1.0)
        this.addCloud(builder, 420.0, 65.0, 0.8)
        this.addCloud(builder, 650.0, 110.0, 1.1)
        builder.end()
    }

    /** 雨天：铅灰云与斜雨线。 */
    private func addRainyWeather(builder: SvgBuilder): Unit {
        builder.group(id: "weather-rainy").animate(
            attribute: "opacity",
            values: ["0", "0", "1", "0", "0"],
            dur: "12s",
            calcMode: SvgCalcMode.Discrete,
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        builder.rect(x: 0.0, y: 0.0, width: 800.0, height: 450.0).fill("#7F8C99")
        this.addCloud(builder, 240.0, 80.0, 1.2, color: "#6C7A87")
        this.addCloud(builder, 560.0, 70.0, 1.0, color: "#6C7A87")
        for (index in 0..14) {
            let x = 60.0 + Float64(index) * 52.0
            builder.line(x1: x, y1: 150.0, x2: x - 18.0, y2: 235.0)
                .stroke("#D6E6F5")
                .strokeWidth(2.0)
                .attr("stroke-linecap", "round")
                .attr("opacity", "0.85")
        }
        builder.end()
    }

    /** 雪天：淡色天空与雪花。 */
    private func addSnowyWeather(builder: SvgBuilder): Unit {
        builder.group(id: "weather-snowy").animate(
            attribute: "opacity",
            values: ["0", "0", "0", "1", "0"],
            dur: "12s",
            calcMode: SvgCalcMode.Discrete,
            keyTimes: KEY_TIMES,
            repeatCount: "indefinite"
        )
        builder.rect(x: 0.0, y: 0.0, width: 800.0, height: 450.0).fill("#E6EEF5")
        for (index in 0..18) {
            let x = 30.0 + Float64(index % 9) * 85.0
            let y = 60.0 + Float64(index / 9) * 85.0
            builder.circle(cx: x, cy: y, r: 4.0).fill("#FFFFFF")
        }
        builder.end()
    }

    /** 草原、公路与路中心虚线。 */
    private func addLandscape(builder: SvgBuilder): Unit {
        builder.rect(x: 0.0, y: 250.0, width: 800.0, height: 120.0).fill("#6BBF59")
        builder.rect(x: 0.0, y: 370.0, width: 800.0, height: 80.0).fill("#5FA34F")
        builder.rect(x: 0.0, y: 330.0, width: 800.0, height: 84.0).fill("#4A4A4A")
        builder.line(x1: 0.0, y1: 372.0, x2: 800.0, y2: 372.0)
            .stroke("#FFD54F")
            .strokeWidth(6.0)
            .attr("stroke-dasharray", "30 22")
        builder.circle(cx: 90.0, cy: 300.0, r: 16.0).fill("#5AA84C")
        builder.circle(cx: 700.0, cy: 296.0, r: 20.0).fill("#5AA84C")
    }

    private func addCloud(
        builder: SvgBuilder,
        x: Float64,
        y: Float64,
        scale: Float64,
        color!: String = "#F2F5F8"
    ): Unit {
        builder.ellipse(cx: x, cy: y, rx: 52.0 * scale, ry: 24.0 * scale).fill(color)
        builder.circle(cx: x - 28.0 * scale, cy: y - 10.0 * scale, r: 22.0 * scale).fill(color)
        builder.circle(cx: x + 6.0 * scale, cy: y - 18.0 * scale, r: 28.0 * scale).fill(color)
        builder.circle(cx: x + 36.0 * scale, cy: y - 6.0 * scale, r: 20.0 * scale).fill(color)
    }

    /** 一只羊：云朵状身体、头、耳朵、四条腿。 */
    private func addSheep(builder: SvgBuilder, x: Float64, y: Float64, id: String): Unit {
        builder.group().id(id).transform("translate(${x} ${y})")
        builder.ellipse(cx: 0.0, cy: 0.0, rx: 22.0, ry: 14.0).fill("#F7F7F2")
        builder.circle(cx: -8.0, cy: -10.0, r: 8.0).fill("#F7F7F2")
        builder.circle(cx: 8.0, cy: -11.0, r: 9.0).fill("#F7F7F2")
        builder.circle(cx: -22.0, cy: -4.0, r: 7.0).fill("#3B3B3B")
        builder.circle(cx: -25.0, cy: -8.0, r: 2.0).fill("#F7F7F2")
        builder.circle(cx: -19.0, cy: -8.0, r: 2.0).fill("#F7F7F2")
        for (offset in [-14.0, -6.0, 6.0, 14.0]) {
            builder.line(x1: offset, y1: 12.0, x2: offset, y2: 24.0)
                .stroke("#3B3B3B")
                .strokeWidth(2.0)
        }
        builder.end()
    }

    /** 鹈鹕 + 自行车；整体水平移动，车轮自转。 */
    private func addRider(builder: SvgBuilder): Unit {
        builder.group(id: "rider")
            .animateTransform(
                attribute: "transform",
                transformType: SvgAnimationTransformType.Translate,
                from: "80 360",
                to: "600 360",
                dur: "12s",
                repeatCount: "indefinite"
            )

        this.addWheel(builder, 0.0, 0.0, "wheel-rear")
        this.addWheel(builder, 62.0, 0.0, "wheel-front")

        // 车架与车把
        builder.path(d: "M0 0 L26 -30 L62 0 M26 -30 L30 0 M62 0 L48 -36 M20 -30 L26 -30")
            .stroke("#2E2E2E")
            .strokeWidth(4.0)
            .attr("fill", "none")
            .attr("stroke-linecap", "round")
        builder.line(x1: 44.0, y1: -38.0, x2: 54.0, y2: -38.0).stroke("#2E2E2E").strokeWidth(4.0)
        builder.line(x1: 14.0, y1: -32.0, x2: 26.0, y2: -32.0).stroke("#2E2E2E").strokeWidth(5.0)

        // 鹈鹕身体、脖子、头与喙
        builder.ellipse(cx: 28.0, cy: -52.0, rx: 20.0, ry: 14.0).fill("#FAFAF4")
        builder.path(d: "M38 -60 Q46 -74 54 -70 L58 -66 Q50 -60 42 -56 Z").fill("#FAFAF4")
        builder.circle(cx: 58.0, cy: -72.0, r: 10.0).fill("#FAFAF4")
        builder.polygon(points: "66,-74 92,-68 66,-62").fill("#F2A03D")
        builder.circle(cx: 60.0, cy: -74.0, r: 1.8).fill("#1F1F1F")
        builder.path(d: "M22 -54 Q34 -66 42 -54 Q34 -46 22 -48 Z").fill("#EDEDE4")
        // 腿与脚踏
        builder.line(x1: 24.0, y1: -40.0, x2: 30.0, y2: -12.0).stroke("#F2A03D").strokeWidth(3.0)
        builder.line(x1: 30.0, y1: -12.0, x2: 36.0, y2: -6.0).stroke("#F2A03D").strokeWidth(3.0)
        builder.circle(cx: 30.0, cy: -6.0, r: 3.0).fill("#2E2E2E")
        builder.end()
    }

    /** 车轮：外圈、辐条与自转动画。 */
    private func addWheel(builder: SvgBuilder, cx: Float64, cy: Float64, id: String): Unit {
        let spinValues = "0 ${cx} ${cy};360 ${cx} ${cy}"
        builder.group(id: id).animateTransform(
            attribute: "transform",
            transformType: SvgAnimationTransformType.Rotate,
            values: [spinValues],
            dur: "2s",
            repeatCount: "indefinite"
        )
        builder.circle(cx: cx, cy: cy, r: 21.0)
            .stroke("#2E2E2E")
            .strokeWidth(3.0)
            .attr("fill", "none")
        for (index in 0..6) {
            let angle = Float64(index) * 30.0 * 3.141592653589793 / 180.0
            builder.line(
                x1: cx - cos(angle) * 19.0,
                y1: cy - sin(angle) * 19.0,
                x2: cx + cos(angle) * 19.0,
                y2: cy + sin(angle) * 19.0
            ).stroke("#2E2E2E").strokeWidth(1.5)
        }
        builder.end()
    }
}
