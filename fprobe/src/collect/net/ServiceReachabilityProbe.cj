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
package fountain::fprobe.collect.net

import std.collection.ArrayList
import std.convert.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.ProbeAgent
import fountain::fprobe.collect.health.{HttpProbe, HttpProbeResult}

/** 单个服务目标的探测结果。 */
@DataAssist[props fields]
public class ServiceTargetResult {
    private var name: String = ""
    private var url: String = ""
    private var reachable: Bool = false
    private var latencyMs: Float64 = 0.0
    private var statusCode: Int64 = 0
    private var error: String = ""

    public init() {}

    public init(name: String, url: String, reachable: Bool, latencyMs: Float64, statusCode: Int64, error: String) {
        this.name = name
        this.url = url
        this.reachable = reachable
        this.latencyMs = latencyMs
        this.statusCode = statusCode
        this.error = error
    }
}

/** `service` 监控项的数据形状。 */
@DataAssist[props fields]
public class ServiceSample {
    private var targets: Array<ServiceTargetResult> = []

    public init() {}

    public init(targets: Array<ServiceTargetResult>) {
        this.targets = targets
    }
}

private class TargetSpec {
    let name: String
    let url: String
    let scheme: String
    let host: String
    let port: UInt16

    init(name: String, url: String, scheme: String, host: String, port: UInt16) {
        this.name = name
        this.url = url
        this.scheme = scheme
        this.host = host
        this.port = port
    }
}

/**
 * 服务可达性：`probe_serviceTargets` 的 `name@url` 目标。
 *
 * HTTP/HTTPS 走 `HttpProbe`（生产实现为 f_httpclient），TCP 走 `TcpProbe`。
 * 任一目标失败只记录该目标的 `reachable=false` 与原因，不影响其它目标。
 */
public class ServiceReachabilityProbe <: ProbeAgent {
    private let http: HttpProbe
    private let tcp: TcpProbe
    private let targets: Array<String>
    private let timeoutMs: Int64

    public init(http: HttpProbe, tcp: TcpProbe, targets: Array<String>, timeoutMs!: Int64 = 2000) {
        this.http = http
        this.tcp = tcp
        this.targets = targets
        this.timeoutMs = timeoutMs
    }

    public prop kind: String {
        get() {
            "service"
        }
    }

    public prop data: JsonObject {
        get() {
            let results = ArrayList<ServiceTargetResult>()
            for (spec in targets) {
                match (parseTarget(spec)) {
                    case Some(target) => results.add(probe(target))
                    case None => results.add(ServiceTargetResult(spec, spec, false, 0.0, 0,
                            '目标格式非法，应为 name@http(s)://host[:port] 或 name@tcp://host:port: "${spec}"'))
                }
            }
            JsonValue.from(ServiceSample(results.toArray()).toData()).asObject()
        }
    }

    private func probe(target: TargetSpec): ServiceTargetResult {
        if (target.scheme == "tcp") {
            let result = tcp.connect(target.host, target.port, timeoutMs)
            return ServiceTargetResult(target.name, target.url, result.reachable, result.latencyMs, 0, result.error)
        }
        let result = http.get(target.url, timeoutMs)
        if (result.timedOut) {
            return ServiceTargetResult(target.name, target.url, false, result.latencyMs, result.statusCode,
                result.error)
        }
        if (!result.error.isEmpty()) {
            return ServiceTargetResult(target.name, target.url, false, result.latencyMs, result.statusCode,
                result.error)
        }
        let reachable = result.statusCode >= 200 && result.statusCode < 400
        let error = if (reachable) {
            ""
        } else {
            'HTTP 状态码 ${result.statusCode}'
        }
        ServiceTargetResult(target.name, target.url, reachable, result.latencyMs, result.statusCode, error)
    }
}

private func parseTarget(spec: String): ?TargetSpec {
    let text = spec.trimAscii()
    let at = match (text.indexOf('@')) {
        case Some(index) => index
        case None => return None
    }
    let name = text[0..at].trimAscii()
    let url = text[at + 1..].trimAscii()
    if (name.isEmpty() || url.isEmpty()) {
        return None
    }
    let schemeEnd = match (url.indexOf("://")) {
        case Some(index) => index
        case None => return None
    }
    let scheme = url[0..schemeEnd].toAsciiLower()
    if (scheme != "http" && scheme != "https" && scheme != "tcp") {
        return None
    }
    let authority = authorityOf(url[schemeEnd + 3..])
    if (authority.isEmpty()) {
        return None
    }
    let (host, portText) = splitAuthority(authority)
    if (host.isEmpty()) {
        return None
    }
    let port = if (portText.isEmpty()) {
        match (scheme) {
            case "http" => 80
            case "https" => 443
            case _ => 0
        }
    } else {
        match (Int64.tryParse(portText)) {
            case Some(value) => if (value >= 1 && value <= 65535) {
                Int64(value)
            } else {
                return None
            }
            case None => return None
        }
    }
    if (port <= 0) {
        return None
    }
    Some(TargetSpec(name, url, scheme, host, UInt16(port)))
}

private func authorityOf(rest: String): String {
    var end = rest.size
    for (mark in ["/", "?", "#"]) {
        match (rest.indexOf(mark)) {
            case Some(index) => if (index < end) {
                end = index
            }
            case None => ()
        }
    }
    rest[0..end].trimAscii()
}

private func splitAuthority(authority: String): (String, String) {
    let colon = match (authority.lastIndexOf(':')) {
        case Some(index) => index
        case None => return (authority, "")
    }
    (authority[0..colon].trimAscii(), authority[colon + 1..].trimAscii())
}
