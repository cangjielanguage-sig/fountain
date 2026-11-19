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
package fountain::f_llm.balance.sign

import std.collection.HashMap
import stdx.crypto.digest.{HMAC, HashType, SHA256}
import stdx.encoding.hex.*

/** 签名工具：HMAC-SHA256 / SHA256 十六进制 / UTC 日期串 */
public struct SignUtil {
    private init(){}

    public static func sha256Hex(text: String): String {
        let digest = SHA256()
        digest.write(text.toArray())
        toHexString(digest.finish())
    }

    public static func hmacSha256(key: Array<Byte>, text: String): Array<Byte> {
        let hmac = HMAC(key, HashType.SHA256)
        hmac.write(text.toArray())
        hmac.finish()
    }

    public static func hmacSha256Hex(key: Array<Byte>, text: String): String {
        toHexString(hmacSha256(key, text))
    }

    /** UTC 日期：`yyyy-MM-dd`（TC3 用） */
    public static func utcDate(epochSeconds: Int64): String {
        let days = floorDiv(epochSeconds, 86400)
        let (year, month, day) = civilFromDays(days)
        '${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}'
    }

    /** UTC 时间：`yyyyMMdd'T'HHmmss'Z'`（火山 V4 用） */
    public static func utcDateTime(epochSeconds: Int64): String {
        let days = floorDiv(epochSeconds, 86400)
        let seconds = epochSeconds - days * 86400
        let (year, month, day) = civilFromDays(days)
        let hour = seconds / 3600
        let minute = (seconds % 3600) / 60
        let second = seconds % 60
        '${pad(year, 4)}${pad(month, 2)}${pad(day, 2)}T${pad(hour, 2)}${pad(minute, 2)}${pad(second, 2)}Z'
    }

    static func floorDiv(a: Int64, b: Int64): Int64 {
        if(a >= 0){
            a / b
        }else{
            (a - b + 1) / b
        }
    }

    /** Howard Hinnant 的 days→civil 算法，避免为了一个日期串引依赖 */
    static func civilFromDays(days: Int64): (Int64, Int64, Int64) {
        let z = days + 719468
        let era = floorDiv(z, 146097)
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = if(mp < 10){ mp + 3 }else{ mp - 9 }
        let year = if(m <= 2){ y + 1 }else{ y }
        (year, m, d)
    }

    static func pad(value: Int64, width: Int64): String {
        var text = '${value}'
        while(text.size < width){
            text = '0${text}'
        }
        text
    }
}

/**
 * 腾讯云 TC3-HMAC-SHA256。
 *
 * 参考 https://cloud.tencent.com/document/product/555/20253 的公共参数要求：
 * `X-TC-Action` / `X-TC-Version` / `X-TC-Timestamp` / `Authorization`。
 */
public struct TencentSigner {
    private init(){}

    public static func headers(
        secretId: String,
        secretKey: String,
        action: String,
        version: String,
        payload: String,
        timestamp: Int64
    ): HashMap<String, String> {
        let host = 'billing.tencentcloudapi.com'
        let service = 'billing'
        let date = SignUtil.utcDate(timestamp)
        let canonicalHeaders = 'content-type:application/json; charset=utf-8\nhost:${host}\n'
        let signedHeaders = 'content-type;host'
        let canonicalRequest = 'POST\n/\n\n${canonicalHeaders}\n${signedHeaders}\n${SignUtil.sha256Hex(payload)}'
        let credentialScope = '${date}/${service}/tc3_request'
        let stringToSign = 'TC3-HMAC-SHA256\n${timestamp}\n${credentialScope}\n${SignUtil.sha256Hex(canonicalRequest)}'
        let secretDate = SignUtil.hmacSha256(('TC3${secretKey}').toArray(), date)
        let secretService = SignUtil.hmacSha256(secretDate, service)
        let secretSigning = SignUtil.hmacSha256(secretService, 'tc3_request')
        let signature = SignUtil.hmacSha256Hex(secretSigning, stringToSign)

        let headers = HashMap<String, String>()
        headers['Content-Type'] = 'application/json; charset=utf-8'
        headers['Host'] = host
        headers['X-TC-Action'] = action
        headers['X-TC-Version'] = version
        headers['X-TC-Timestamp'] = '${timestamp}'
        headers['Authorization'] = 'TC3-HMAC-SHA256 Credential=${secretId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}'
        headers
    }
}

/**
 * 火山引擎签名 V4（HMAC-SHA256）。
 *
 * 参考 https://docs.volcengine.com/docs/BillingCenter/QueryBalanceAcct 的调用约定：
 * `Action=QueryBalanceAcct&Version=2022-01-01`，Service=`billing`，Region=`cn-north-1`。
 */
public struct VolcSigner {
    private init(){}

    public static func headers(
        accessKey: String,
        secretKey: String,
        action: String,
        version: String,
        body: String,
        timestamp: Int64
    ): HashMap<String, String> {
        let host = 'open.volcengineapi.com'
        let region = 'cn-north-1'
        let service = 'billing'
        let xdate = SignUtil.utcDateTime(timestamp)
        let shortDate = xdate[0 .. 8]
        let query = 'Action=${action}&Version=${version}'
        let signedHeaders = 'content-type;host;x-content-sha256;x-date'
        let canonicalHeaders = 'content-type:application/json\nhost:${host}\nx-content-sha256:${SignUtil.sha256Hex(body)}\nx-date:${xdate}\n'
        let canonicalRequest = 'POST\n/\n${query}\n${canonicalHeaders}\n${signedHeaders}\n${SignUtil.sha256Hex(body)}'
        let credentialScope = '${shortDate}/${region}/${service}/request'
        let stringToSign = 'HMAC-SHA256\n${xdate}\n${credentialScope}\n${SignUtil.sha256Hex(canonicalRequest)}'
        let kDate = SignUtil.hmacSha256(secretKey.toArray(), shortDate)
        let kRegion = SignUtil.hmacSha256(kDate, region)
        let kService = SignUtil.hmacSha256(kRegion, service)
        let kSigning = SignUtil.hmacSha256(kService, 'request')
        let signature = SignUtil.hmacSha256Hex(kSigning, stringToSign)

        let headers = HashMap<String, String>()
        headers['Content-Type'] = 'application/json'
        headers['Host'] = host
        headers['X-Date'] = xdate
        headers['X-Content-Sha256'] = SignUtil.sha256Hex(body)
        headers['Authorization'] = 'HMAC-SHA256 Credential=${accessKey}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}'
        headers
    }
}
