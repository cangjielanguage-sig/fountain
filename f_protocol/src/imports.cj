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
package f_protocol

internal import std.collection.ArrayList
internal import std.env.getProcessId
internal import std.io.{InputStream, OutputStream, BufferedInputStream}
internal import std.net.{IPAddress, TcpSocket, IPSocketAddress}
internal import std.reflect.*
internal import std.time.DateTime
internal import f_base.*
internal import f_codec.*
internal import f_codec.default.*
internal import f_data.*
internal import f_exception.UnreachableException
internal import f_pool.BytesCopyTo
internal import f_protocol.exception.*