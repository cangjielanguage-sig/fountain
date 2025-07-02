/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

public enum OS <: Equatable<OS> & ToString & Hashable {
    | Linux
    | Windows
    | macOS
    | HarmonyOS

    public operator func ==(other: OS): Bool {
        match ((this, other)) {
            case (Linux, Linux) | (Windows, Windows) | (macOS, macOS) | (HarmonyOS, HarmonyOS) => true
            case _ => false
        }
    }
    public prop isWindows: Bool {
        get() {
            this == Windows
        }
    }
    public prop isLinux: Bool {
        get() {
            this == Linux
        }
    }
    public prop isMacOS: Bool {
        get() {
            this == macOS
        }
    }
    public prop isHarmonyOS: Bool {
        get() {
            this == HarmonyOS
        }
    }
    public func toString(): String {
        match (this) {
            case Linux => "Linux"
            case Windows => "Windows"
            case macOS => "macOS"
            case HarmonyOS => "HarmonyOS"
        }
    }
    public static func valueOf(value: String): OS {
        match (value.toAsciiLower()) {
            case "linux" => Linux
            case "windows" => Windows
            case "macos" => macOS
            case "harmonyos" => HarmonyOS
            case _ => throw IllegalArgumentException("unsupported os name: ${value}")
        }
    }
    public func hashCode(): Int64 {
        'fountain.base.OS.${this}'.hashCode()
    }

    @When[os == "Linux"]
    public static prop current: OS {
        get() {
            Linux
        }
    }

    @When[os == "Windows"]
    public static prop current: OS {
        get() {
            Windows
        }
    }

    @When[os == "macOS"]
    public static prop current: OS {
        get() {
            macOS
        }
    }

    @When[os == "HarmonyOS"]
    public static prop current: OS {
        get() {
            HarmonyOS
        }
    }

    @When[os != "Windows"]
    public prop nextLine: String {
        get() {
            '\n'
        }
    }

    @When[os == "Windows"]
    public prop nextLine: String {
        get() {
            '\r\n'
        }
    }
}
