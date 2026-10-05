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
package fountain::f_mvc

import std.unittest.*
import std.unittest.testmacro.*

/**
 * §2.3 / `MVC-C5`：下载任务在 spawn 里跑、`exec` 立即返回，任务失败必须自己收尾
 * （`onFailure` 记录 + `finish` 结束响应体），否则 `pipe.end()` 不执行、响应体永不结束，
 * 客户端一直等。
 *
 * 测的是包内接缝 `runDownloadTask`（`FileDownload.exec` 的 spawn 里唯一的调用点）：
 * 用「抛异常的任务 + 计数 onFailure/finish」驱动；`FileDownload` 构造要读
 * `CurrentHttpContext.instance`，测试里造不出来，故绕开实例、直接驱动接缝。
 */
@Test
class FileDownload_test {
    /** 任务抛异常 ⇒ onFailure 恰好一次 + finish 恰好一次（修前形态：异常直接穿出，两者都是 0） */
    @TestCase
    public func testFailedTaskIsReportedAndFinished(): Unit {
        let failures = Box<Int64>(0)
        let finishes = Box<Int64>(0)
        try {
            runDownloadTask(
                {=> throw Exception('task boom')},
                {_ => failures.value++},
                {=> finishes.value++}
            )
        } catch (_: Exception) {
            // 修前形态：异常穿出接缝（在 spawn 里就是「无人接收」）
        }
        @Assert(1, failures.value)
        @Assert(1, finishes.value)
    }

    /** 成功路径不动 finish（收尾由任务自己调，不能重复收尾） */
    @TestCase
    public func testSuccessfulTaskIsNotFinishedTwice(): Unit {
        let ran = Box<Int64>(0)
        let finishes = Box<Int64>(0)
        runDownloadTask(
            {=> ran.value++},
            {_ => ()},
            {=> finishes.value++}
        )
        @Assert(1, ran.value)
        @Assert(0, finishes.value)
    }

    /** 收尾自身失败 ⇒ 抛出的应是原任务异常（finish 的异常挂在其 suppressed 上，不静默吞掉） */
    @TestCase
    public func testFinishFailureRethrowsTaskException(): Unit {
        let failures = Box<Int64>(0)
        let message = Box<String>('')
        try {
            runDownloadTask(
                {=> throw Exception('task boom')},
                {_ => failures.value++},
                {=> throw Exception('close boom')}
            )
        } catch (e: Exception) {
            message.value = e.message
        }
        @Assert(1, failures.value)
        @Assert('task boom', message.value)
    }
}
