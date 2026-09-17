/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_base

public enum OS <: Equatable<OS> & ToString & Hashable {
    | Linux
    | Windows
    | macOS
    | HarmonyOS
    | OpenHarmony
    | Android
    | iOS

    public operator func ==(other: OS): Bool {
        match ((this, other)) {
            case (Linux, Linux) | 
                 (Windows, Windows) | 
                 (macOS, macOS) | 
                 (HarmonyOS, HarmonyOS) |
                 (OpenHarmony, OpenHarmony) |
                 (Android, Android) | 
                 (iOS, iOS) => true
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
    public prop isOpenHarmony: Bool {
        get() {
            this == OpenHarmony
        }
    }
    public prop isAndroid: Bool {
        get() {
            this == Android
        }
    }
    public prop isiOS: Bool {
        get() {
            this == iOS
        }
    }
    public func toString(): String {
        match (this) {
            case Linux => "Linux"
            case Windows => "Windows"
            case macOS => "macOS"
            case HarmonyOS => "HarmonyOS"
            case OpenHarmony => "OpenHarmony"
            case Android => "Android"
            case iOS => "iOS"
        }
    }
    public static func valueOf(value: String): OS {
        match (value.toAsciiLower()) {
            case "linux" => Linux
            case "windows" => Windows
            case "macos" => macOS
            case "harmonyos" => HarmonyOS
            case "openharmony" => OpenHarmony
            case "android" => Android
            case "ios" => iOS
            case _ => throw IllegalArgumentException("unsupported os name: ${value}")
        }
    }
    public func hashCode(): Int64 {
        'fountain::f_base.OS.${this}'.hashCode()
    }

    @When[os == "Linux" && env == "gnu"]
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

    // @When[os == "Linux" && env == 'hos']
    // public static prop current: OS {
    //     get() {
    //         HarmonyOS
    //     }
    // }
    @When[os == "Linux" && env == 'ohos']
    public static prop current: OS {
        get() {
            OpenHarmony
        }
    }
    @When[os == "Linux" && env == 'android']
    public static prop current: OS {
        get() {
            Android
        }
    }
    @When[os == "iOS"]
    public static prop current: OS {
        get() {
            iOS
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
