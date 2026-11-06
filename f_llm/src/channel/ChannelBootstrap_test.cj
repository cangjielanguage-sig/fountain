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

import fountain::f_config.Config
import fountain::f_llm.config.LLMConfig

@Test
class ChannelBootstrap_test {
    private static let oneAccount = '[{"platform":"email","account":"work","from":"bot@example.com",' +
        '"user":"bot@example.com","password":"p","smtpHost":"smtp.example.com","smtpPort":465,' +
        '"imapHost":"imap.example.com","imapPort":993}]'

    @TestCase
    func testInstallOneAccount(): Unit {
        ChannelMediator.reset()
        let report = ChannelBootstrap.install(oneAccount)

        @Expect(report.installed, 1)
        @Expect(report.skipped, 0)
        let accounts = ChannelMediator.accounts('email')
        @Expect(accounts.size, 1)
        @Expect(accounts[0], 'work')
        ChannelMediator.reset()
    }

    @TestCase
    func testInstallSkipsBadEntry(): Unit {
        ChannelMediator.reset()
        let json = '[{"account":"no-platform"},{"platform":"email","account":"ops",' +
            '"user":"ops@example.com","password":"p","smtpHost":"smtp.example.com"}]'
        let report = ChannelBootstrap.install(json)

        @Expect(report.installed, 1)
        @Expect(report.skipped, 1)
        @Expect(report.errors.size, 1)
        ChannelMediator.reset()
    }

    @TestCase
    func testInstallInvalidJsonDoesNotThrow(): Unit {
        ChannelMediator.reset()
        let report = ChannelBootstrap.install('not a json array')

        @Expect(report.installed, 0)
        @Expect(report.errors.size, 1)
    }

    @TestCase
    func testInstallSkipsUnimplementedPlatform(): Unit {
        ChannelMediator.reset()
        let json = '[{"platform":"wecom","account":"bot"}]'
        let report = ChannelBootstrap.install(json)

        @Expect(report.installed, 0)
        @Expect(report.skipped, 1)
        @Expect(report.errors[0].contains('not supported'), true)
    }

    @TestCase
    func testInstallFromConfigReadsKey(): Unit {
        ChannelMediator.reset()
        Config.set<String>([(LLMConfig.LLM_CHANNELS, oneAccount)])
        try{
            let report = ChannelBootstrap.installFromConfig()
            @Expect(report.installed, 1)
        }finally{
            Config.remove(LLMConfig.LLM_CHANNELS)
            ChannelMediator.reset()
        }
    }

    @TestCase
    func testInstallFromEmptyConfigIsNoop(): Unit {
        ChannelMediator.reset()
        Config.remove(LLMConfig.LLM_CHANNELS)
        let report = ChannelBootstrap.installFromConfig()
        @Expect(report.installed, 0)
        @Expect(report.skipped, 0)
    }

    /** JSON null 按空串处理，不能变成字面量 "null" */
    @TestCase
    func testNullFieldTreatedAsEmpty(): Unit {
        ChannelMediator.reset()
        let json = '[{"platform":"email","account":null,"from":"bot@example.com",' +
            '"user":"bot@example.com","password":"p","smtpHost":"smtp.example.com"}]'
        let report = ChannelBootstrap.install(json)

        @Expect(report.installed, 1)
        let accounts = ChannelMediator.accounts('email')
        @Expect(accounts.size, 1)
        @Expect(accounts[0], '')
        ChannelMediator.reset()
    }

    /** 端口越界：跳过并说明，不能静默截断 */
    @TestCase
    func testPortOutOfRangeIsSkipped(): Unit {
        ChannelMediator.reset()
        let json = '[{"platform":"email","account":"work","user":"bot@example.com",' +
            '"smtpHost":"smtp.example.com","smtpPort":70000}]'
        let report = ChannelBootstrap.install(json)

        @Expect(report.installed, 0)
        @Expect(report.skipped, 1)
        @Expect(report.errors[0].contains('smtpPort'), true)
        ChannelMediator.reset()
    }

    /** 必填缺失：email 没有 smtpHost，跳过 */
    @TestCase
    func testMissingRequiredFieldIsSkipped(): Unit {
        ChannelMediator.reset()
        let json = '[{"platform":"email","account":"work","user":"bot@example.com"}]'
        let report = ChannelBootstrap.install(json)

        @Expect(report.installed, 0)
        @Expect(report.skipped, 1)
        @Expect(report.errors[0].contains('smtpHost'), true)
        ChannelMediator.reset()
    }

    /** tls=starttls 暂未实现：明确拒绝而不是假装支持 */
    @TestCase
    func testStartTlsIsRejected(): Unit {
        ChannelMediator.reset()
        let json = '[{"platform":"email","account":"work","user":"bot@example.com",' +
            '"smtpHost":"smtp.example.com","tls":"starttls"}]'
        let report = ChannelBootstrap.install(json)

        @Expect(report.installed, 0)
        @Expect(report.skipped, 1)
        @Expect(report.errors[0].contains('starttls'), true)
        ChannelMediator.reset()
    }
}
