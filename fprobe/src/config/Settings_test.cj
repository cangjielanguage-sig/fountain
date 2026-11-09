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
package fountain::fprobe.config

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config

/** 配置是进程级全局状态：用例结束后必须还原，避免污染其它用例。 */
private func restore(saved: ArrayList<(String, ?String)>): Unit {
    for ((key, old) in saved) {
        match (old) {
            case Some(text) => Config.set([(key, text)])
            case None => Config.remove(key)
        }
    }
}

private func withKeys(entries: Array<(String, String)>, body: () -> Unit): Unit {
    let saved = ArrayList<(String, ?String)>()
    for ((key, value) in entries) {
        saved.add((key, Config.getString(key)))
        Config.set([(key, value)])
    }
    try {
        body()
    } finally {
        restore(saved)
    }
}

private func withoutKeys(keys: Array<String>, body: () -> Unit): Unit {
    let saved = ArrayList<(String, ?String)>()
    for (key in keys) {
        saved.add((key, Config.getString(key)))
        Config.remove(key)
    }
    try {
        body()
    } finally {
        restore(saved)
    }
}

@Test
public class AgentSettings_test {
    @TestCase
    public func defaultsWhenNothingConfigured(): Unit {
        withoutKeys(["probe_port", "probe_host", "probe_intervalMs", "probe_customDir", "probe_customFailFast"]) {
            let settings = AgentSettings.load()
            @Assert(settings.port, 12323)
            @Assert(settings.intervalMs, 5000)
            @Assert(settings.customDir, "./custom")
            @Assert(settings.customFailFast)
            @Assert(!settings.host.isEmpty())
            @Assert(settings.validate().isEmpty())
        }
    }

    @TestCase
    public func configuredValuesOverrideDefaults(): Unit {
        withKeys([("probe_port", "23456"), ("probe_host", "node-a"), ("probe_intervalMs", "1500"),
            ("probe_customDir", "/opt/fprobe/custom"), ("probe_customFailFast", "false")]) {
            let settings = AgentSettings.load()
            @Assert(settings.port, 23456)
            @Assert(settings.host, "node-a")
            @Assert(settings.intervalMs, 1500)
            @Assert(settings.customDir, "/opt/fprobe/custom")
            @Assert(!settings.customFailFast)
            @Assert(settings.validate().isEmpty())
        }
    }

    @TestCase
    public func portZeroIsRejected(): Unit {
        withKeys([("probe_port", "0")]) {
            let errors = AgentSettings.load().validate()
            @Assert(errors.size == 1)
            @Assert(errors[0].contains("probe_port"))
        }
    }

    @TestCase
    public func portTooLargeIsRejected(): Unit {
        withKeys([("probe_port", "65536")]) {
            let errors = AgentSettings.load().validate()
            @Assert(errors.size == 1)
            @Assert(errors[0].contains("probe_port"))
        }
    }

    @TestCase
    public func nonNumericPortIsRejected(): Unit {
        withKeys([("probe_port", "abc")]) {
            let errors = AgentSettings.load().validate()
            @Assert(errors.size == 1)
            @Assert(errors[0].contains("probe_port"))
        }
    }

    /** 3.4：一次返回全部错误，而不是只报第一条。 */
    @TestCase
    public func validationAggregatesAllErrors(): Unit {
        withKeys([("probe_port", "70000"), ("probe_intervalMs", "0")]) {
            let errors = AgentSettings.load().validate()
            @Assert(errors.size == 2)
            var hasPort = false
            var hasInterval = false
            for (message in errors) {
                if (message.contains("probe_port")) {
                    hasPort = true
                }
                if (message.contains("probe_intervalMs")) {
                    hasInterval = true
                }
            }
            @Assert(hasPort)
            @Assert(hasInterval)
        }
    }

    /** 3.5：agent 启动前把 probe_port 写入 rpcServer_port。 */
    @TestCase
    public func applyMirrorsPortIntoRpcServerPort(): Unit {
        withKeys([("probe_port", "23456")]) {
            let saved = ArrayList<(String, ?String)>()
            saved.add(("rpcServer_port", Config.getString("rpcServer_port")))
            try {
                let settings = AgentSettings.load()
                settings.apply()
                @Assert(Config.getValue<UInt16>("rpcServer_port").getOrThrow(), 23456)
            } finally {
                restore(saved)
            }
        }
    }
}

@Test
public class SupervisorSettings_test {
    @TestCase
    public func defaultNodeWhenNotConfigured(): Unit {
        withoutKeys(["probe_nodes", "probe_pollIntervalMs", "probe_nodeTimeoutMs", "probe_missingThreshold",
            "probe_historyPoints"]) {
            let settings = SupervisorSettings.load()
            @Assert(settings.validate().isEmpty())
            @Assert(settings.nodes.size, 1)
            @Assert(settings.nodes[0].name, "localhost")
            @Assert(settings.nodes[0].host, "127.0.0.1")
            @Assert(settings.nodes[0].port, 12323)
            @Assert(settings.pollIntervalMs, 5000)
            @Assert(settings.nodeTimeoutMs, 3000)
            @Assert(settings.missingThreshold, 2)
            @Assert(settings.historyPoints, 60)
        }
    }

    @TestCase
    public func multipleNodesAreParsed(): Unit {
        withKeys([("probe_nodes", "a@10.0.0.1:12323, b@10.0.0.2:12324")]) {
            let settings = SupervisorSettings.load()
            @Assert(settings.validate().isEmpty())
            @Assert(settings.nodes.size, 2)
            @Assert(settings.nodes[0].name, "a")
            @Assert(settings.nodes[0].host, "10.0.0.1")
            @Assert(settings.nodes[0].port, 12323)
            @Assert(settings.nodes[1].name, "b")
            @Assert(settings.nodes[1].host, "10.0.0.2")
            @Assert(settings.nodes[1].port, 12324)
        }
    }

    @TestCase
    public func nodeWithoutAtIsRejected(): Unit {
        withKeys([("probe_nodes", "bogus")]) {
            let errors = SupervisorSettings.load().validate()
            @Assert(errors.size == 1)
            @Assert(errors[0].contains("bogus"))
        }
    }

    @TestCase
    public func nodeWithInvalidPortIsRejected(): Unit {
        withKeys([("probe_nodes", "n@host:70000")]) {
            let errors = SupervisorSettings.load().validate()
            @Assert(errors.size == 1)
            @Assert(errors[0].contains("n@host:70000"))
        }
        withKeys([("probe_nodes", "n@host:abc")]) {
            let errors = SupervisorSettings.load().validate()
            @Assert(errors.size == 1)
            @Assert(errors[0].contains("n@host:abc"))
        }
    }

    @TestCase
    public func duplicateNodeNameIsRejected(): Unit {
        withKeys([("probe_nodes", "dup@h1:12323,dup@h2:12324")]) {
            let errors = SupervisorSettings.load().validate()
            @Assert(errors.size == 1)
            @Assert(errors[0].contains("dup"))
        }
    }

    @TestCase
    public func supervisorValidationAggregatesAllErrors(): Unit {
        withKeys([("probe_nodes", "bad,other@host:0"), ("probe_historyPoints", "0")]) {
            let errors = SupervisorSettings.load().validate()
            @Assert(errors.size == 3)
        }
    }
}
