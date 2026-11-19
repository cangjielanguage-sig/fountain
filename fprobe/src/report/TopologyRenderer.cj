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
package fountain::fprobe.report

import std.collection.{ArrayList, HashMap, HashSet}
import std.math.*
import fountain::f_svg.SvgBuilder
import fountain::fprobe.collect.topology.{TopologyDevice, TopologyLink, TopologySample}

/**
 * 拓扑 SVG 渲染（设计 D12）。
 *
 * 设备按名字排序后均匀分布在固定半径的圆上，链路先画、设备后画；布局只依赖
 * 排序后的顺序，因此同一份拓扑输入总是得到完全相同的 SVG 文本。
 */
public class TopologyRenderer {
    private static let WIDTH = 640.0
    private static let HEIGHT = 480.0
    private static let CENTER_X = 320.0
    private static let CENTER_Y = 240.0
    private static let RADIUS = 170.0
    private static let NODE_RADIUS = 18.0

    public static func render(sample: TopologySample): ?String {
        if (sample.devices.isEmpty()) {
            return None<String>
        }

        let devices = sortedDevices(sample.devices)
        let positions = HashMap<String, (Float64, Float64)>()
        for (i in 0..devices.size) {
            let angle = 2.0 * 3.141592653589793 * Float64(i) / Float64(devices.size) - 3.141592653589793 / 2.0
            positions[devices[i].name] = (CENTER_X + RADIUS * cos(angle), CENTER_Y + RADIUS * sin(angle))
        }

        let links = sortedLinks(sample.links)
        let builder = SvgBuilder(WIDTH, HEIGHT)
        for (link in links) {
            let start = positions.get(link.from)
            let end = positions.get(link.to)
            if (start.isNone() || end.isNone()) {
                continue
            }
            let fromPoint = start.getOrThrow()
            let toPoint = end.getOrThrow()
            builder.line(x1: fromPoint[0], y1: fromPoint[1], x2: toPoint[0], y2: toPoint[1])
                .stroke("#9aa5b1").strokeWidth(1.5)
        }

        for (device in devices) {
            let point = positions.get(device.name).getOrThrow()
            builder.circle(cx: point[0], cy: point[1], r: NODE_RADIUS)
                .fill("#4e79a7").stroke("#2c4d6f").strokeWidth(1.0)
            builder.text(content: device.name, x: point[0] - Float64(device.name.size) * 3.0,
                y: point[1] + 4.0).fill("#1f2933")
        }

        Some(builder.toSvgString())
    }

    private static func sortedDevices(devices: Array<TopologyDevice>): Array<TopologyDevice> {
        let values = ArrayList<TopologyDevice>()
        for (device in devices) {
            values.add(device)
        }
        let result = values.toArray()
        var i = 1
        while (i < result.size) {
            let current = result[i]
            var j = i - 1
            while (j >= 0 && result[j].name > current.name) {
                result[j + 1] = result[j]
                j -= 1
            }
            result[j + 1] = current
            i += 1
        }
        result
    }

    private static func sortedLinks(links: Array<TopologyLink>): Array<TopologyLink> {
        let values = ArrayList<TopologyLink>()
        let seen = HashSet<String>()
        for (link in links) {
            let key = linkKey(link)
            if (seen.contains(key)) {
                continue
            }
            seen.add(key)
            values.add(link)
        }
        let result = values.toArray()
        var i = 1
        while (i < result.size) {
            let current = result[i]
            var j = i - 1
            while (j >= 0 && linkKey(result[j]) > linkKey(current)) {
                result[j + 1] = result[j]
                j -= 1
            }
            result[j + 1] = current
            i += 1
        }
        result
    }

    private static func linkKey(link: TopologyLink): String {
        let a = '${link.from}#${link.localPort}'
        let b = '${link.to}#${link.remotePort}'
        if (a > b) {
            '${b}|${a}'
        } else {
            '${a}|${b}'
        }
    }
}
