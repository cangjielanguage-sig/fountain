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
package fountain::f_base


public enum Arch <: Equatable<Arch> & ToString & Hashable { 
    | x86_64
    | aarch64
    
    public func hashCode(): Int64 {
        'fountain::f_base.Arch.${this}'.hashCode()
    }

    public operator func ==(other: Arch): Bool {
        match ((this, other)) {
            case (x86_64, x86_64) | (aarch64, aarch64) => true
            case _ => false
        }
    }


    @When[arch == "x86_64"]
    public static prop current: Arch {
        get() {
            x86_64
        }
    }
    @When[arch == "aarch64"]
    public static prop current: Arch {
        get() {
            aarch64
        }
    }
    public prop isX86_64: Bool {
        get() {
            this == x86_64
        }
    }

    public prop isAarch64: Bool {
        get() {
            this == aarch64
        }
    }

    public func toString(): String {
        match (this) {
            case x86_64 => "x86_64"
            case aarch64 => "aarch64"
        }
    }
}