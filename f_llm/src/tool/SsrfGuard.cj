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
package fountain::f_llm.tool

/** 抓取被安全策略拒绝（协议不允许、指向内网、解析到内网等） */
public class FetchRejectedException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * SSRF 防护：`webFetch` 让模型指定任意 URL，等于把内网探测能力交给模型。
 *
 * 当前实现做**字面量级**校验（协议白名单 + 主机名字面量判定）；
 * 完整防护还应在真正建连前用**解析后的 IP** 再校验一次（防 DNS rebinding），
 * 那一步依赖 HTTP 客户端暴露远端地址，等 `f_httpclient` 提供后补上。
 */
public struct SsrfGuard {
    private init(){}

    public static func check(url: String): Unit {
        let trimmed = url.trimAscii()
        let lower = trimmed.toAsciiLower()
        if(!lower.startsWith('http://') && !lower.startsWith('https://')){
            throw FetchRejectedException('only http/https is allowed: ${url}')
        }
        let host = hostOf(trimmed)
        if(host.isEmpty()){
            throw FetchRejectedException('url has no host: ${url}')
        }
        if(blocked(host)){
            throw FetchRejectedException('url points to a private or local address: ${host}')
        }
    }

    /** 取出主机名（去 userinfo、去端口；IPv6 字面量取中括号内） */
    public static func hostOf(url: String): String {
        var rest = url.trimAscii()
        if(let Some(index) <- rest.indexOf('://')){
            rest = rest[(index + 3) ..]
        }
        if(let Some(index) <- rest.indexOf('/')){
            rest = rest[0 .. index]
        }
        if(let Some(index) <- rest.indexOf('@')){
            rest = rest[(index + 1) ..]
        }
        if(rest.startsWith('[')){
            if(let Some(index) <- rest.indexOf(']')){
                return rest[1 .. index].toAsciiLower()
            }
            return rest[1 ..].toAsciiLower()
        }
        if(let Some(index) <- rest.lastIndexOf(':')){
            rest = rest[0 .. index]
        }
        rest.toAsciiLower()
    }

    public static func blocked(host: String): Bool {
        if(host.isEmpty() || host == 'localhost' || host.endsWith('.localhost')){
            return true
        }
        // IPv6：环回、未指定、ULA（fc00::/7）、链路本地（fe80::/10）
        if(host == '::1' || host == '::' || host.startsWith('fc') || host.startsWith('fd') || host.startsWith('fe80')){
            return true
        }
        let parts = host.split('.')
        if(parts.size != 4){
            // 纯数字主机名（如 2130706433）等价于 IPv4，直接拒绝，避免绕过
            var digitsOnly = !host.isEmpty()
            for(rune in host.runes()){
                if(rune < r'0' || rune > r'9'){
                    digitsOnly = false
                    break
                }
            }
            return digitsOnly
        }
        let a = Int64.tryParse(parts[0]) ?? -1
        let b = Int64.tryParse(parts[1]) ?? -1
        if(a < 0 || b < 0){
            return false        // 形如 api.example.com，交给 DNS
        }
        return a == 0 || a == 10 || a == 127 ||
               (a == 172 && b >= 16 && b <= 31) ||
               (a == 192 && b == 168) ||
               (a == 169 && b == 254) ||
               (a == 100 && b >= 64 && b <= 127)
    }
}
