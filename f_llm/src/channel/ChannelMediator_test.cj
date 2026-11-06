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
package fountain::f_llm.channel

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/** 假通道：记录发出的消息，按预设返回收件箱 */
class FakeChannel <: Channel {
    private let platformValue: String
    private let accountValue: String
    public let sent: ArrayList<OutboundMessage> = ArrayList<OutboundMessage>()
    public var inbox: ArrayList<InboundMessage> = ArrayList<InboundMessage>()
    public var lastDownloadDir: String = ''
    public var closed: Bool = false

    public init(platform: String, account: String) {
        this.platformValue = platform
        this.accountValue = account
    }

    public prop platform: String {
        get() {
            platformValue
        }
    }

    public prop account: String {
        get() {
            accountValue
        }
    }

    public func send(message: OutboundMessage): SendReceipt {
        sent.add(message)
        SendReceipt.success(messageId: 'fake-${sent.size}')
    }

    public func receive(limit: Int64, downloadDir: String): ArrayList<InboundMessage> {
        lastDownloadDir = downloadDir
        let result = ArrayList<InboundMessage>()
        for(item in inbox){
            if(Int64(result.size) >= limit){
                break
            }
            result.add(item)
        }
        result
    }

    public func close(): Unit {
        closed = true
    }
}

@Test
class ChannelMediator_test {
    @TestCase
    func testRegisterTwoAccountsAndAddressThem(): Unit {
        ChannelMediator.reset()
        let work = FakeChannel('email', 'work')
        let personal = FakeChannel('email', 'personal')
        ChannelMediator.register(work)
        ChannelMediator.register(personal)

        let platforms = ChannelMediator.platforms()
        @Expect(platforms.size, 1)
        @Expect(platforms[0], 'email')

        let accounts = ChannelMediator.accounts('email')
        @Expect(accounts.size, 2)
        @Expect(accounts[0], 'personal')
        @Expect(accounts[1], 'work')

        let resolved = (ChannelMediator.channel('email', 'work') as FakeChannel).getOrThrow()
        @Expect(resolved.account, 'work')
        @Expect(resolved.sent.size, 0)
    }

    @TestCase
    func testBlankAccountFallsBackWhenSole(): Unit {
        ChannelMediator.reset()
        let only = FakeChannel('sole', 'default')
        ChannelMediator.register(only)

        let lower = (ChannelMediator.channel('sole', '') as FakeChannel).getOrThrow()
        @Expect(lower.account, 'default')
        let upper = (ChannelMediator.channel('SOLE', '') as FakeChannel).getOrThrow()
        @Expect(upper.account, 'default')
    }

    @TestCase
    func testBlankAccountWithMultipleThrows(): Unit {
        ChannelMediator.reset()
        ChannelMediator.register(FakeChannel('multi', 'a'))
        ChannelMediator.register(FakeChannel('multi', 'b'))

        var message = ''
        try{
            let _ = ChannelMediator.channel('multi', '')
        }catch(e: ChannelException){
            message = e.message
        }
        @Expect(message.contains('account is required'), true)
    }

    @TestCase
    func testUnknownChannelThrows(): Unit {
        ChannelMediator.reset()
        var message = ''
        try{
            let _ = ChannelMediator.channel('nope', 'x')
        }catch(e: ChannelException){
            message = e.message
        }
        // 平台没实现时报「不支持」，有实现但没配账号才报「找不到」
        @Expect(message.contains('nope'), true)
    }

    @TestCase
    func testRegisterProviderIsIdempotent(): Unit {
        ChannelMediator.reset()
        let first = { conf: ChannelAccountConf => FakeChannel(conf.platform, conf.account) }
        let second = { conf: ChannelAccountConf => FakeChannel('other', conf.account) }

        @Expect(ChannelMediator.registerProvider('demo', first), true)
        @Expect(ChannelMediator.registerProvider('demo', second), false)

        let created = ChannelMediator.create(ChannelAccountConf('demo', account: 'x'))
        @Expect(created.platform, 'demo')
        ChannelMediator.reset()
    }

    @TestCase
    func testCreateUnknownPlatformThrows(): Unit {
        ChannelMediator.reset()
        var message = ''
        try{
            let _ = ChannelMediator.create(ChannelAccountConf('wecom', account: 'x'))
        }catch(e: ChannelException){
            message = e.message
        }
        @Expect(message.contains('not supported'), true)
        ChannelMediator.reset()
    }

    @TestCase
    func testSendRoutesToAddressedAccount(): Unit {
        ChannelMediator.reset()
        let work = FakeChannel('mail', 'work')
        let personal = FakeChannel('mail', 'personal')
        ChannelMediator.register(work)
        ChannelMediator.register(personal)

        let receipt = ChannelMediator.send('mail', 'personal',
            OutboundMessage('a@b.c', '标题', text: '正文'))
        @Expect(receipt.ok, true)
        @Expect(work.sent.size, 0)
        @Expect(personal.sent.size, 1)
        @Expect(personal.sent[0].subject, '标题')
    }

    @TestCase
    func testReservedPlatformsAreNotImplemented(): Unit {
        @Expect(ChannelPlatforms.isReserved('wecom'), true)
        @Expect(ChannelPlatforms.isReserved('email'), false)
    }

    /** 同键替换：旧实例必须被 close */
    @TestCase
    func testRegisterReplacesAndClosesOld(): Unit {
        ChannelMediator.reset()
        let first = FakeChannel('email', 'work')
        ChannelMediator.register(first)
        let second = FakeChannel('email', 'work')
        ChannelMediator.register(second)

        @Expect(first.closed, true)
        @Expect(second.closed, false)
        @Expect(ChannelMediator.accounts('email').size, 1)
        ChannelMediator.reset()
    }

    /** 空账号重复注册：必须报错，不能互相覆盖 */
    @TestCase
    func testRegisterBlankAccountTwiceThrows(): Unit {
        ChannelMediator.reset()
        ChannelMediator.register(FakeChannel('twitter', ''))
        var message = ''
        try {
            ChannelMediator.register(FakeChannel('twitter', ''))
        } catch (e: ChannelException) {
            message = e.message
        }
        @Expect(message.contains('account'), true)
        ChannelMediator.reset()
    }

    /** closeAll：关闭每个实例并清空注册表 */
    @TestCase
    func testCloseAllClosesEveryInstance(): Unit {
        ChannelMediator.reset()
        let first = FakeChannel('email', 'a')
        let second = FakeChannel('email', 'b')
        ChannelMediator.register(first)
        ChannelMediator.register(second)

        ChannelMediator.closeAll()

        @Expect(first.closed, true)
        @Expect(second.closed, true)
        @Expect(ChannelMediator.accounts('email').size, 0)
    }
}
