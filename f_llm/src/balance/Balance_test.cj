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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.model.po.*

let BALANCE_JSON = '''
{
  "is_available": true,
  "balance_infos": [
    {"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"},
    {"currency": "USD", "total_balance": "5.00", "granted_balance": "0.00", "topped_up_balance": "5.00"}
  ]
}'''

let BALANCE_UNAVAILABLE = '''
{"is_available": false, "balance_infos": [{"currency": "CNY", "total_balance": "0.00"}]}'''

class FakeBalanceQuerier <: BalanceQuerier {
    FakeBalanceQuerier(private let name: String){}
    public prop provider: String {
        get() {
            name
        }
    }
    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        ArrayList<BalanceSnapshot>([BalanceSnapshot(currency: 'CNY', total: '50.00', totalValue: 50.0f64)])
    }
}

func balanceConf(provider: String): LLMConf {
    let conf = LLMConf()
    conf.id = 3
    conf.provider = provider
    conf.llmName = 'chat-pro'
    conf.actualLlmName = 'model'
    conf.url = 'https://api.example'
    conf.auth = 'sk'
    conf
}

@Test
public class BalanceTest {

    @TestCase
    func testRegisterAndQuery(): Unit {
        let mediator = BalanceMediator.instance
        try{
            mediator.register(FakeBalanceQuerier('fake-balance'))
        }catch(_: Exception){}
        let snapshots = mediator.query('fake-balance', balanceConf('fake-balance'))
        @Expect(snapshots.size, 1)
        @Expect(snapshots[0].provider, 'fake-balance')
        // 50 < 默认阈值 100 ⇒ 标记低余额
        @Expect(snapshots[0].low, true)
    }

    @TestCase
    func testDuplicateRegisterFails(): Unit {
        let mediator = BalanceMediator.instance
        try{
            mediator.register(FakeBalanceQuerier('dup-balance'))
        }catch(_: Exception){}
        var thrown = false
        try{
            mediator.register(FakeBalanceQuerier('dup-balance'))
        }catch(_: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testUnknownProviderThrows(): Unit {
        var message = ''
        try{
            BalanceMediator.instance.query('no-such-provider', balanceConf('no-such-provider'))
        }catch(e: BalanceUnsupportedException){
            message = e.message
        }
        @Expect(message.contains('not supported'), true)
    }

    @TestCase
    func testParseDeepSeekMultiCurrency(): Unit {
        let snapshots = parseBalance(BALANCE_JSON, 'deepseek')
        @Expect(snapshots.size, 2)
        @Expect(snapshots[0].currency, 'CNY')
        @Expect(snapshots[0].total, '110.00')
        @Expect(snapshots[0].granted, '10.00')
        @Expect(snapshots[0].toppedUp, '100.00')
        @Expect(snapshots[0].available, true)
        @Expect(snapshots[1].currency, 'USD')
        @Expect(snapshots[1].total, '5.00')
    }

    @TestCase
    func testParseUnavailableAccount(): Unit {
        let snapshots = parseBalance(BALANCE_UNAVAILABLE, 'deepseek')
        @Expect(snapshots.size, 1)
        @Expect(snapshots[0].available, false)
    }

    @TestCase
    func testPlaceholderQueriersThrow(): Unit {
        let placeholders = ArrayList<BalanceQuerier>()
        placeholders.add(ZhipuBalanceQuerier())
        placeholders.add(SiliconFlowBalanceQuerier())
        placeholders.add(VolcengineBalanceQuerier())
        placeholders.add(TencentCloudBalanceQuerier())
        placeholders.add(AliyunBalanceQuerier())
        var thrown = 0
        for(querier in placeholders){
            try{
                querier.query(balanceConf(querier.provider))
            }catch(_: BalanceUnsupportedException){
                thrown++
            }
        }
        @Expect(thrown, 5)
    }
}
