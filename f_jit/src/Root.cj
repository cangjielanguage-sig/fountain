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
// f_jit 门面/桥（plan-m1 P6；用户面 API 冻结点见 S6.11）。
// public import 再导出占位——随 P1+ 各阶段逐步启用：
//   public import fountain::f_jit.base.*
//   public import fountain::f_jit.bytecode.*
//   public import fountain::f_jit.compiler.*
//   public import fountain::f_jit.runtime.*
//   public import fountain::f_jit.backend.*
package fountain::f_jit
