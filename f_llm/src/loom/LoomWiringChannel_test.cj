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
package fountain::f_llm.loom

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_config.Config
import fountain::f_llm.channel.ChannelMediator
import fountain::f_llm.config.LLMConfig

@Test
class LoomWiringChannel_test {
    private static let oneAccount = '[{"platform":"email","account":"work","from":"bot@example.com",' +
        '"user":"bot@example.com","password":"p","smtpHost":"smtp.example.com","smtpPort":465,' +
        '"imapHost":"imap.example.com","imapPort":993}]'

    @TestCase
    func testWireInstallsChannelsFromConfig(): Unit {
        ChannelMediator.reset()
        LoomServices.reset()
        Config.set<String>([(LLMConfig.LLM_CHANNELS, oneAccount)])
        try{
            let _ = LoomWiring.wire({ _, _, _ => '{"status":"planned","steps":[],"edges":[]}' },
                store: MemoryLoomStore())
            let accounts = ChannelMediator.accounts('email')
            @Expect(accounts.size, 1)
            @Expect(accounts[0], 'work')
        }finally{
            Config.remove(LLMConfig.LLM_CHANNELS)
            ChannelMediator.reset()
            LoomServices.reset()
        }
    }
}
