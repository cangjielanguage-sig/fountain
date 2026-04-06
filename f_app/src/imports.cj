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

internal import fountain::f_version.*
internal import std.ast.*
internal import std.collection.*
internal import std.collection.concurrent.{ConcurrentHashMap, ConcurrentLinkedQueue}
internal import std.convert.*
internal import std.env.{getWorkingDirectory, getCommand, atExit, getStdOut}
internal import std.fs.*
internal import std.io.{StringReader, ByteBuffer, InputStream}
internal import std.process.*
internal import std.reflect.*
internal import std.regex.Regex
internal import std.sync.Mutex
internal import std.time.MonoTime
internal import stdx.encoding.json.*
internal import stdx.net.http.*
internal import stdx.net.tls.*
internal import stdx.net.tls.common.*
internal import fountain::f_base.*
internal import fountain::f_log.impl.*

internal let log = LoggerFactory.getLogger<App>()