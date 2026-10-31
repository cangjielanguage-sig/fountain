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
package fountain::f_mcp

// `@Mcp` 展开出的 `@Bean` / `lookup` / `TypeInfo` / `ArrayList` 会出现在用户代码里；
// 用户只 import 了 f_mcp 时也要能解析，因此在这里再导出。
public import fountain::f_bean.BeanFactory
public import fountain::f_bean.lookup
public import fountain::f_data.JsonValue
public import fountain::f_data.convert
public import std.collection.ArrayList
public import std.reflect.TypeInfo
