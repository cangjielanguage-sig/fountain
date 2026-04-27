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
package fountain::f_store

// === 标准库 ===
internal import std.binary.*
internal import std.collection.ArrayList
internal import std.convert.*
internal import std.fs.*
internal import std.io.{IOStream, SeekPosition}
internal import std.sort.*
internal import std.sync.{AtomicBool, AtomicInt64, AtomicReference, AtomicOptionReference, Mutex}
internal import std.time.DateTime
internal import std.env.atExit

// === 项目依赖 ===
internal import fountain::f_base.*
internal import fountain::f_bloom.BloomFilter
internal import fountain::f_concurrent.ConcurrentSkipListMap
internal import fountain::f_concurrent.ExtendAtomicInt64
internal import fountain::f_util.crc32

@When[os == "Linux"]
internal import fountain::f_io.IOUringStream
