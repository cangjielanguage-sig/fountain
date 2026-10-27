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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.balance.sign.*
import fountain::f_llm.model.po.*

let DEEPSEEK_JSON = '''
{
  "is_available": true,
  "balance_infos": [
    {"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"},
    {"currency": "USD", "total_balance": "5.00", "granted_balance": "0.00", "topped_up_balance": "5.00"}
  ]
}'''

let DEEPSEEK_UNAVAILABLE = '''
{"is_available": false, "balance_infos": [{"currency": "CNY", "total_balance": "0.00"}]}'''

let TENCENT_JSON = '''
{
  "Response": {
    "Balance": 1000000,
    "RealBalance": 1000000,
    "CashAccountBalance": 1200000,
    "PresentAccountBalance": 30000,
    "CreditAmount": 0,
    "FreezeAmount": 0,
    "OweAmount": 0,
    "RequestId": "req-1"
  }
}'''

let TENCENT_ERROR = '''
{"Response": {"Error": {"Code": "UnauthorizedOperation.CamNoAuth", "Message": "no auth"}}}'''

let VOLC_JSON = '''
{
  "ResponseMetadata": {"RequestId": "volc-1", "Action": "QueryBalanceAcct"},
  "Result": {"AccountID": "2100", "AvailableBalance": "100.00", "CashBalance": "120.00", "CreditLimit": "0.00", "FreezeAmount": "20.00"}
}'''

let VOLC_ERROR = '''
{"ResponseMetadata": {"Error": {"Code": "AccessDenied", "Message": "denied"}}}'''

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
    func testDeepSeekMultiCurrency(): Unit {
        let snapshots = parseDeepSeekBalance(DEEPSEEK_JSON, 'deepseek')
        @Expect(snapshots.size, 2)
        @Expect(snapshots[0].currency, 'CNY')
        @Expect(snapshots[0].total, '110.00')
        @Expect(snapshots[0].granted, '10.00')
        @Expect(snapshots[0].toppedUp, '100.00')
        @Expect(snapshots[1].currency, 'USD')
        @Expect(snapshots[1].total, '5.00')
    }

    @TestCase
    func testDeepSeekUnavailable(): Unit {
        let snapshots = parseDeepSeekBalance(DEEPSEEK_UNAVAILABLE, 'deepseek')
        @Expect(snapshots.size, 1)
        @Expect(snapshots[0].available, false)
    }

    @TestCase
    func testTencentParsesFenToYuan(): Unit {
        let snapshots = parseTencentBalance(TENCENT_JSON)
        @Expect(snapshots.size, 1)
        @Expect(snapshots[0].provider, 'tencent')
        @Expect(snapshots[0].total, '10000.00')
        @Expect(snapshots[0].toppedUp, '12000.00')
        @Expect(snapshots[0].granted, '300.00')
        @Expect(snapshots[0].totalValue, 10000.0f64)
    }

    @TestCase
    func testTencentErrorThrows(): Unit {
        var message = ''
        try{
            parseTencentBalance(TENCENT_ERROR)
        }catch(e: BalanceUnsupportedException){
            message = e.message
        }
        @Expect(message.contains('UnauthorizedOperation.CamNoAuth'), true)
    }

    @TestCase
    func testVolcengineParsesYuan(): Unit {
        let snapshots = parseVolcengineBalance(VOLC_JSON)
        @Expect(snapshots.size, 1)
        @Expect(snapshots[0].provider, 'volcengine')
        @Expect(snapshots[0].total, '100.00')
        @Expect(snapshots[0].toppedUp, '120.00')
        @Expect(snapshots[0].totalValue, 100.0f64)
    }

    @TestCase
    func testVolcengineErrorThrows(): Unit {
        var thrown = false
        try{
            parseVolcengineBalance(VOLC_ERROR)
        }catch(_: BalanceUnsupportedException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testTencentSignatureShape(): Unit {
        let headers = TencentSigner.headers('AKID', 'SECRET', 'DescribeAccountBalance', '2018-07-09', '{"TempCredit":true}', 1793000000)
        let auth = headers.get('Authorization') ?? ''
        @Expect(auth.startsWith('TC3-HMAC-SHA256 Credential=AKID/'), true)
        @Expect(auth.contains('/billing/tc3_request'), true)
        @Expect(headers.get('X-TC-Action') ?? '', 'DescribeAccountBalance')
        let signature = auth.split('Signature=')[1]
        @Expect(signature.size, 64)
        // 同样的输入必须得到同样的签名（纯函数）
        let again = TencentSigner.headers('AKID', 'SECRET', 'DescribeAccountBalance', '2018-07-09', '{"TempCredit":true}', 1793000000)
        @Expect(again.get('Authorization') ?? '', auth)
    }

    @TestCase
    func testVolcSignatureShape(): Unit {
        let headers = VolcSigner.headers('AK', 'SK', 'QueryBalanceAcct', '2022-01-01', '{}', 1793000000)
        let auth = headers.get('Authorization') ?? ''
        @Expect(auth.startsWith('HMAC-SHA256 Credential=AK/'), true)
        @Expect(auth.contains('/cn-north-1/billing/request'), true)
        let xdate = headers.get('X-Date') ?? ''
        @Expect(xdate.size, 16)
        @Expect(xdate.endsWith('Z'), true)
        let signature = auth.split('Signature=')[1]
        @Expect(signature.size, 64)
    }

    @TestCase
    func testPlaceholderQueriersThrow(): Unit {
        let placeholders = ArrayList<BalanceQuerier>()
        placeholders.add(ZhipuBalanceQuerier())
        placeholders.add(SiliconFlowBalanceQuerier())
        placeholders.add(AliyunBalanceQuerier())
        var thrown = 0
        for(querier in placeholders){
            try{
                querier.query(balanceConf(querier.provider))
            }catch(_: BalanceUnsupportedException){
                thrown++
            }
        }
        @Expect(thrown, 3)
    }

    @TestCase
    func testCloudCredentialsFromAuth(): Unit {
        let conf = balanceConf('tencent')
        conf.auth = 'AKID:SECRET'
        let (ak, sk) = cloudCredentials(conf)
        @Expect(ak, 'AKID')
        @Expect(sk, 'SECRET')
    }
}
