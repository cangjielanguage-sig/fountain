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
package fountain::f_llm.balance

import std.collection.{ArrayList, HashMap}
import std.time.DateTime
import stdx.net.tls.common.*

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.*
import fountain::f_httpclient.*
import fountain::f_time.*

import fountain::f_llm.balance.sign.*
import fountain::f_llm.model.po.*
import fountain::f_llm.util.*

/** HTTP POST 的抽象：单测注入假实现，验签名与解析，不发真请求 */
public type BalancePoster = (String, HashMap<String, String>, String) -> String

func defaultPost(url: String, headers: HashMap<String, String>, body: String): String {
    let client = HttpClient(url)
    for((key, value) in headers){
        client.header(key, value)
    }
    var tls = TlsClientConfig()
    tls.verifyMode = CertificateVerifyMode.TrustAll
    client.tlsConfig(tls)
    resource(client){http =>
        http.post(body).readEntire()
    }
}

/**
 * DeepSeek 余额：`GET /user/balance`。
 *
 * 响应 `{"is_available":bool,"balance_infos":[{currency,total_balance,granted_balance,topped_up_balance}]}`，
 * 金额是**字符串**（如 `"110.00"`）——原样保留，另给 `Float64` 视图做阈值比较；多币种各出一条。
 */
@Bean
public class DeepSeekBalanceQuerier <: BalanceQuerier {
    private let getter: (String, String) -> String

    public init(getter!: (String, String) -> String = defaultBalanceGet) {
        this.getter = getter
    }

    public prop provider: String {
        get() {
            'deepseek'
        }
    }

    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        let url = conf.option('balanceUrl', 'https://api.deepseek.com/user/balance')
        let unit = BalanceUnits.unitOf(BalanceUnits.YUAN, conf.option('balanceUnit', ''))
        parseDeepSeekBalance(getter(url, conf.auth), 'deepseek', unit)
    }
}

func defaultBalanceGet(url: String, auth: String): String {
    http(url, auth){client =>
        client.get().readEntire()
    }
}

/** `unit` 是上游口径：DeepSeek 官方用元，个别代理会按分返回，可用 `conf['balanceUnit']` 覆盖 */
public func parseDeepSeekBalance(body: String, provider: String, unit: String): ArrayList<BalanceSnapshot> {
    let snapshots = ArrayList<BalanceSnapshot>()
    let json = JsonValue.fromStr(body).asObject()
    let available = if(let Some(value) <- json.get('is_available')){
        value.asBool().value
    }else{
        true
    }
    if(let Some(rawInfos) <- json.get('balance_infos')){
        for(item in rawInfos.asArray().getItems()){
            let obj = item.asObject()
            let (total, totalValue) = BalanceUnits.toYuan(balanceTextOf(obj, 'total_balance'), unit)
            let (granted, _) = BalanceUnits.toYuan(balanceTextOf(obj, 'granted_balance'), unit)
            let (toppedUp, _) = BalanceUnits.toYuan(balanceTextOf(obj, 'topped_up_balance'), unit)
            snapshots.add(BalanceSnapshot(
                provider: provider,
                currency: balanceTextOf(obj, 'currency'),
                total: total,
                granted: granted,
                toppedUp: toppedUp,
                available: available,
                low: false,
                totalValue: totalValue
            ))
        }
    }
    snapshots
}

/**
 * 腾讯云余额：`DescribeAccountBalance`（billing，2018-07-09）。
 *
 * 注意单位：**所有金额字段都是「分」**，除以 100 才是元。
 * `Balance` 是历史兼容字段，与 `RealBalance` 相同，新代码只读后者。
 */
@Bean
public class TencentCloudBalanceQuerier <: BalanceQuerier {
    private let poster: BalancePoster

    public init(poster!: BalancePoster = defaultPost) {
        this.poster = poster
    }

    public prop provider: String {
        get() {
            'tencent'
        }
    }

    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        let (secretId, secretKey) = cloudCredentials(conf)
        let payload = '{"TempCredit":true}'
        let timestamp = DateTime.now().toUnixEpochSeconds()
        let headers = TencentSigner.headers(secretId, secretKey, 'DescribeAccountBalance', '2018-07-09', payload, timestamp)
        let body = poster('https://billing.tencentcloudapi.com', headers, payload)
        parseTencentBalance(body)
    }
}

public func parseTencentBalance(body: String): ArrayList<BalanceSnapshot> {
    let json = JsonValue.fromStr(body).asObject()
    let response = json.get('Response')?.asObject() ?? JsonObject()
    if(let Some(rawError) <- response.get('Error')){
        let error = rawError.asObject()
        throw BalanceUnsupportedException(
            'tencent balance query failed: ${balanceTextOf(error, "Code")} ${balanceTextOf(error, "Message")}'
        )
    }
    let snapshots = ArrayList<BalanceSnapshot>()
    // 腾讯云所有金额都是「分」：统一在 BalanceUnits 里换算成元
    let (total, totalValue) = BalanceUnits.toYuan(balanceTextOf(response, 'RealBalance'), BalanceUnits.FEN)
    let (granted, _) = BalanceUnits.toYuan(balanceTextOf(response, 'PresentAccountBalance'), BalanceUnits.FEN)
    let (toppedUp, _) = BalanceUnits.toYuan(balanceTextOf(response, 'CashAccountBalance'), BalanceUnits.FEN)
    snapshots.add(BalanceSnapshot(
        provider: 'tencent',
        currency: 'CNY',
        total: total,
        granted: granted,
        toppedUp: toppedUp,
        available: true,
        low: false,
        totalValue: totalValue
    ))
    snapshots
}

/**
 * 火山引擎余额：`QueryBalanceAcct`（BillingCenter，2022-01-01，Service=`billing`）。
 *
 * 金额是**字符串、单位元**，原样保留。
 */
@Bean
public class VolcengineBalanceQuerier <: BalanceQuerier {
    private let poster: BalancePoster

    public init(poster!: BalancePoster = defaultPost) {
        this.poster = poster
    }

    public prop provider: String {
        get() {
            'volcengine'
        }
    }

    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        let (accessKey, secretKey) = cloudCredentials(conf)
        let payload = '{}'
        let timestamp = DateTime.now().toUnixEpochSeconds()
        let headers = VolcSigner.headers(accessKey, secretKey, 'QueryBalanceAcct', '2022-01-01', payload, timestamp)
        let url = 'https://open.volcengineapi.com?Action=QueryBalanceAcct&Version=2022-01-01'
        let body = poster(url, headers, payload)
        let unit = BalanceUnits.unitOf(BalanceUnits.YUAN, conf.option('balanceUnit', ''))
        parseVolcengineBalance(body, unit)
    }
}

public func parseVolcengineBalance(body: String, unit: String): ArrayList<BalanceSnapshot> {
    let json = JsonValue.fromStr(body).asObject()
    if(let Some(rawMeta) <- json.get('ResponseMetadata')){
        if(let Some(rawError) <- rawMeta.asObject().get('Error')){
            let error = rawError.asObject()
            throw BalanceUnsupportedException(
                'volcengine balance query failed: ${balanceTextOf(error, "Code")} ${balanceTextOf(error, "Message")}'
            )
        }
    }
    let result = json.get('Result')?.asObject() ?? JsonObject()
    let (total, totalValue) = BalanceUnits.toYuan(balanceTextOf(result, 'AvailableBalance'), unit)
    let (toppedUp, _) = BalanceUnits.toYuan(balanceTextOf(result, 'CashBalance'), unit)
    let snapshots = ArrayList<BalanceSnapshot>()
    snapshots.add(BalanceSnapshot(
        provider: 'volcengine',
        currency: 'CNY',
        total: total,
        granted: '',
        toppedUp: toppedUp,
        available: true,
        low: false,
        totalValue: totalValue
    ))
    snapshots
}

/** AK/SK：优先 `conf['accessKeyId']` + `conf['secretKey']`，否则按 `auth = AK:SK` 拆 */
func cloudCredentials(conf: LLMConf): (String, String) {
    let accessKey = conf.option('accessKeyId', '')
    let secretKey = conf.option('secretKey', '')
    if(!accessKey.isEmpty() && !secretKey.isEmpty()){
        return (accessKey, secretKey)
    }
    if(let Some(index) <- conf.auth.indexOf(':')){
        return (conf.auth[0 .. index], conf.auth[(index + 1) ..])
    }
    throw BalanceUnsupportedException('cloud balance requires accessKeyId/secretKey in conf or auth as AK:SK')
}

func balanceTextOf(obj: JsonObject, key: String): String {
    if(let Some(value) <- obj.get(key)){
        match(value){
            case text: JsonString => text.value
            case _: JsonNull => ''
            case other => other.toString()
        }
    }else{
        ''
    }
}

func numberOf(obj: JsonObject, key: String): Float64 {
    BalanceUnits.parse(balanceTextOf(obj, key))
}

/** 智谱 / 硅基流动 / 阿里云：本期只留可编译占位，调用即抛「不支持」 */
@Bean
public class ZhipuBalanceQuerier <: BalanceQuerier {
    public prop provider: String {
        get() {
            'zhipu'
        }
    }
    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        throw BalanceUnsupportedException('balance query for zhipu is not implemented yet')
    }
}

@Bean
public class SiliconFlowBalanceQuerier <: BalanceQuerier {
    public prop provider: String {
        get() {
            'siliconflow'
        }
    }
    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        throw BalanceUnsupportedException('balance query for siliconflow is not implemented yet')
    }
}

@Bean
public class AliyunBalanceQuerier <: BalanceQuerier {
    public prop provider: String {
        get() {
            'aliyun'
        }
    }
    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        throw BalanceUnsupportedException('balance query for aliyun is not implemented yet')
    }
}
