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
package fountain::fcoder.model.entity

internal import std.collection.*

internal import stdx.crypto.digest.MD5
internal import stdx.encoding.hex.toHexString
internal import stdx.encoding.json.*

internal import fountain::f_base.*

internal import fountain::fcoder.constant.*
internal import fountain::fcoder.embedding.*
internal import fountain::fcoder.llm.*
internal import fountain::fcoder.model.*
internal import fountain::fcoder.model.po.*
internal import fountain::fcoder.util.SearchResult