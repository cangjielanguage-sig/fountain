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
package f_base

import std.env.{getStdOut, getStdIn, ConsoleWriter, ConsoleReader}
public import std.env.ConsoleWriter

public let console = Console()
public struct Console {
    init(){}
    private let output = getStdOut()
    private let input = getStdIn()
    public func write<T>(v: T): Unit where T <: ToString {
        output.write<T>(v)
    }
    public func writeln<T>(v: T): Unit where T <: ToString {
        output.writeln<T>(v)
    }
    public func write<T>(fn: () -> T): Unit where T <: ToString {
        output.write<T>(fn())
    }
    public func writeln<T>(fn: () -> T): Unit where T <: ToString {
        output.writeln<T>(fn())
    }
    public func read(): ?Rune {
        input.read()
    }
    public func readUntil(r: Rune): ?String {
        input.readUntil(r)
    }
    public func readUntil(predicate: (Rune) -> Bool): ?String {
        input.readUntil(predicate)
    }
    public func readln(): ?String {
        input.readln()
    }
}