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

import std.collection.ArrayList

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.*
import fountain::f_httpclient.*

import fountain::f_llm.model.po.*
import fountain::f_llm.util.*

/**
 * DeepSeek 余额：`GET /user/balance`。
 *
 * 响应形如 `{"is_available":true,"balance_infos":[{currency,total_balance,granted_balance,topped_up_balance}]}`，
 * 金额是**字符串**（如 `"110.00"`）——原样保留在快照里，另给一个 `Float64` 视图供阈值比较。
 * 多币种各出一条，不取下标 0。
 */
@Bean
public class DeepSeekBalanceQuerier <: BalanceQuerier {
    private let getter: (String, String) -> String

    /** getter 可注入，单测喂固定 JSON，不发真请求 */
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
        let body = getter(url, conf.auth)
        parseBalance(body, 'deepseek')
    }
}

func defaultBalanceGet(url: String, auth: String): String {
    http(url, auth){client =>
        client.get().readEntire()
    }
}

/** 解析 DeepSeek 的余额响应；`is_available=false` 时所有快照标为不可用 */
public func parseBalance(body: String, provider: String): ArrayList<BalanceSnapshot> {
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
            let total = balanceTextOf(obj, 'total_balance')
            snapshots.add(BalanceSnapshot(
                provider: provider,
                currency: balanceTextOf(obj, 'currency'),
                total: total,
                granted: balanceTextOf(obj, 'granted_balance'),
                toppedUp: balanceTextOf(obj, 'topped_up_balance'),
                available: available,
                low: false,
                totalValue: decimalValue(total)
            ))
        }
    }
    snapshots
}

func balanceTextOf(obj: JsonObject, key: String): String {
    if(let Some(value) <- obj.get(key)){
        match(value){
            case _: JsonNull => ''
            case _ => value.asString().value
        }
    }else{
        ''
    }
}

func decimalValue(text: String): Float64 {
    try{
        Float64.parse(text)
    }catch(_: Exception){
        0.0f64
    }
}

/** 金山云、腾讯云、阿里云、智谱、硅基流动：本期只留可编译占位，调用即抛「不支持」 */
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
public class VolcengineBalanceQuerier <: BalanceQuerier {
    public prop provider: String {
        get() {
            'volcengine'
        }
    }
    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        throw BalanceUnsupportedException('balance query for volcengine is not implemented yet')
    }
}

@Bean
public class TencentCloudBalanceQuerier <: BalanceQuerier {
    public prop provider: String {
        get() {
            'tencent'
        }
    }
    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        throw BalanceUnsupportedException('balance query for tencent is not implemented yet')
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
