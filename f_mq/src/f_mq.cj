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
package fountain::f_mq

/**
 * 门面包：业务侧只需 `import fountain::f_mq.*`。
 *
 * 设计见 doc/详细设计.md，开发顺序见 doc/开发计划.md。
 */
public import fountain::f_mq.base.*
public import fountain::f_mq.base.model.*
public import fountain::f_mq.base.payload.*
public import fountain::f_mq.exception.*
public import fountain::f_mq.client.*
