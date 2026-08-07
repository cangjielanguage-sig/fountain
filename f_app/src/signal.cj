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
package fountain::f_app

import std.env.exit
public import std.runtime.{registerSignalHandler, resetSignalHandler, Signal}

internal let log = LoggerFactory.getLogger<App>()

@When[os != "Windows"]
private let _ = {=>
    // 必须有这个才能响应kill -15和CTRL+C，atExit函数调用才能生效
    registerSignalHandler([Signal.SIGTERM, Signal.SIGINT]){
        exit(0)
        false
    }
}()

@When[os != "Windows"]
public func registerSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit {
    registerSignalHandler(signals){_ => handler()}
}
@When[os != "Windows"]
public func registerSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {
    for(signal in signals){
        registerSignalHandler(signal, handler)
    }
}
@When[os != "Windows"]
public func registerSignalHandler(signal: Signal, handler: () -> Bool): Unit {
    registerSignalHandler(signal){_ => handler()}
}

@When[os != "Windows"]
public func resetAndRegisterSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit {
    resetSignalHandler(signals)
    registerSignalHandler(signals){_ => handler()}
}
@When[os != "Windows"]
public func resetAndRegisterSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {
    resetSignalHandler(signals)
    for(signal in signals){
        registerSignalHandler(signal, handler)
    }
}
@When[os != "Windows"]
public func resetAndRegisterSignalHandler(signal: Signal, handler: () -> Bool): Unit {
    resetSignalHandler([signal])
    registerSignalHandler(signal){_ => handler()}
}

@When[os == "Windows"]
public func registerSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit{}
@When[os == "Windows"]
public func registerSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {}
@When[os == "Windows"]
public func registerSignalHandler(signal: Signal, handler: () -> Bool): Unit {}

@When[os == "Windows"]
public func resetAndRegisterSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit{}
@When[os == "Windows"]
public func resetAndRegisterSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {}
@When[os == "Windows"]
public func resetAndRegisterSignalHandler(signal: Signal, handler: () -> Bool): Unit {}