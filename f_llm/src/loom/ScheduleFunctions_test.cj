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
package fountain::f_llm.loom

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*
import fountain::f_llm.tool.*

/** 记录注册/取消的假调度器 */
class FakeScheduler <: LoomScheduler {
    public var scheduled: HashMap<String, String> = HashMap<String, String>()
    public var cancelled: ArrayList<String> = ArrayList<String>()

    public func schedule(name: String, cron: String, body: () -> Unit): Unit {
        scheduled[name] = cron
    }

    public func cancel(name: String): Unit {
        cancelled.add(name)
    }
}

/** scheduleCreate / scheduleDelete */
@Test
class ScheduleFunctions_test {
    private static func createParam(json: String): ScheduleCreateParam {
        match(DataObject<ScheduleCreateParam>.populate(JsonValue.fromStr(json).toData())){
            case Some(value) => value
            case None => throw IllegalStateException('bad param: ${json}')
        }
    }

    private static func deleteParam(json: String): ScheduleDeleteParam {
        match(DataObject<ScheduleDeleteParam>.populate(JsonValue.fromStr(json).toData())){
            case Some(value) => value
            case None => throw IllegalStateException('bad param: ${json}')
        }
    }

    private static func textOf(result: FunctionResult): String {
        match(result.result as JsonString){
            case Some(value) => value.value
            case None => ''
        }
    }

    @TestCase
    func testCreateRegistersTask(): Unit {
        let scheduler = FakeScheduler()
        LoomSchedules.install(scheduler)
        let result = ScheduleCreateFunction().call(createParam(
            '{"nextEvent":"next","name":"daily","cron":"0 0 9 * * * *"}'))
        @Expect(textOf(result).contains('scheduled: daily'), true)
        @Expect(scheduler.scheduled.get('daily').getOrThrow(), '0 0 9 * * * *')
        LoomSchedules.reset()
    }

    @TestCase
    func testDeleteCancelsTask(): Unit {
        let scheduler = FakeScheduler()
        LoomSchedules.install(scheduler)
        let result = ScheduleDeleteFunction().call(deleteParam('{"nextEvent":"next","name":"daily"}'))
        @Expect(textOf(result).contains('cancelled: daily'), true)
        @Expect(scheduler.cancelled.contains('daily'), true)
        LoomSchedules.reset()
    }

    @TestCase
    func testCreateRequiresNameAndCron(): Unit {
        LoomSchedules.install(FakeScheduler())
        let missingName = ScheduleCreateFunction().call(createParam('{"nextEvent":"next"}'))
        @Expect(textOf(missingName).contains('requires name'), true)
        let missingCron = ScheduleCreateFunction().call(createParam(
            '{"nextEvent":"next","name":"x"}'))
        @Expect(textOf(missingCron).contains('requires cron'), true)
        LoomSchedules.reset()
    }

    @TestCase
    func testWithoutSchedulerReturnsText(): Unit {
        LoomSchedules.reset()
        let result = ScheduleDeleteFunction().call(deleteParam('{"nextEvent":"next","name":"x"}'))
        @Expect(textOf(result).contains('no loom scheduler installed'), true)
    }
}
