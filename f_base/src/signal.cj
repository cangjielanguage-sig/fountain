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

import std.collection.{TreeMap, ArrayList}
import std.env.exit
import std.sync.Mutex

public import std.runtime.{registerSignalHandler, resetSignalHandler, Signal}

@When[os != "Windows"]
public struct ExitCallbacks {
    private static let mutex = Mutex()
    private static let callbacks = TreeMap<UInt16, ArrayList<() -> Unit>>()
    public static func exitGracefully(): Unit {
        let signals = [Signal.SIGTERM, Signal.SIGINT]
        resetSignalHandler(signals)
        registerSignalHandler(signals){
            onExit()
            exit(0)
            false
        }
    }
    public static func atExit(priority: UInt16, atexit: () -> Unit): Unit {
        synchronized(mutex){
            let view = callbacks.entryView(priority)
            if(let Some(list) <- view.value){
                list
            }else{
                let list = ArrayList<() -> Unit>()
                view.value = list
                list
            }.add(atexit)
        }
    }
    private static func onExit(): Unit {
        synchronized(mutex){
            for((_, atexits) in callbacks){
                for(atexit in atexits){
                    atexit()
                }
            }
        }
    }
}
@When[os == "Windows"]
public struct ExitCallbacks {
    public static func exitGracefully(): Unit {}
    public static func atExit(_: UInt16, _: () -> Unit): Unit {}
}

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
public func registerSignalHandler(_: Array<Signal>, _: () -> Bool): Unit{}
@When[os == "Windows"]
public func registerSignalHandler(_: Array<Signal>, _: (Int32) -> Bool): Unit {}
@When[os == "Windows"]
public func registerSignalHandler(_: Signal, _: () -> Bool): Unit {}

@When[os == "Windows"]
public func resetAndRegisterSignalHandler(_: Array<Signal>, _: () -> Bool): Unit{}
@When[os == "Windows"]
public func resetAndRegisterSignalHandler(_: Array<Signal>, _: (Int32) -> Bool): Unit {}
@When[os == "Windows"]
public func resetAndRegisterSignalHandler(_: Signal, _: () -> Bool): Unit {}