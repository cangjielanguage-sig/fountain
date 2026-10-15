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
// 差分测试层：同一单元跑 Interp / BackendX86_64 / BackendAArch64 并逐位对比（plan-m1 S0.2）。
// 约束：只放三引擎对照，禁止放单层语义断言（单层语义归各包 *_test.cj）。
package fountain::f_jit.test.diff
