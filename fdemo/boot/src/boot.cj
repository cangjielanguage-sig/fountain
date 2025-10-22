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
package boot

import std.env
import opengauss.driver.*
import opengauss.slog
import fountain.data.*
import fountain.data.macros.*
import fountain.log.LoggerFactory
import fountain.orm.*

private let _ = {=>
    let logger = LoggerFactory.getLogger("opengauss")
    slog.setDefault(logger)
    let driver = DriverManager.getDriver("opengauss").getOrThrow()
    let url = env.getVariable('POSTGRES') ?? ''
    ORM.register(driver, url, [])
}()
///////////////////////////////////////////////////////////////////////////////
/**这一行往下单纯只是为了演示实例复制和类实例与json互相转换的功能*******************/
@DataAssist[equal hash tostring props fields]
public open class TestData1 {
    private var a: Int64 = 1
    private var b: String = 'asfd'
    private var c: Bool = true
    private var d: Float64 = 3.1415926
}
@DataAssist[equal hash tostring props fields]
public class TestData2 <: TestData1 {
    private var e: DateTime = DateTime.now()
    private var f: Array<Int64> = [1, 2, 3, 4, 5]
    private var g: ArrayList<String> = ArrayList<String>(['a','b','c','d','e'])
}

@DataAssist[equal hash tostring props fields]
public class TestData3 {
    private var a: Int64 = 0
    private var b: String = ''
    private var c: Bool = false
    private var d: Float64 = 0.0
    private var e: ?DateTime = None<DateTime>
    private var f: Array<Int64> = []
    private var g: ArrayList<String> = ArrayList<String>()
}
private let _ = {=>
    let data2 = TestData2()
    var data3 = DataObject<TestData3>.populate(data2).getOrThrow()
    println('AAAAAAAAAAAAAAAAAAAAAAAAAAAAA ${data2}')
    println('AAAAAAAAAAAAAAAAAAAAAAAAAAAAA ${data3}')
    let dobj = DataObject<TestData2>(data2)
    let json = JsonValue.tryFromData(dobj)
    println('AAAAAAAAAAAAAAAAAAAAAAAAAAAAA ${json}')
    let data = json.toData()
    data3 = DataObject<TestData3>.populate(data2).getOrThrow()
    println('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ${data3}')
}()