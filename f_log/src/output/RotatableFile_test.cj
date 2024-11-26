/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_log.output

import std.unittest.*
import std.unittest.testmacro.*

import compress.zlib.*

import f_time.TimeUnit as TU

@Test
public class RotatableFileTest {
    @TestCase
    public func test(): Unit {
        let param = RotatableFileParams()
        param.compress = LogFileCompressFormat.GZip(CompressLevel.DefaultCompression)
        param.fileSize = 0
        param.timeunit = TU.SECOND
        param.path = '/tmp/test.log'
        let file = RotatableFile(param)
        spawn{
            while(true){
                file.write('hello\n'.toArray())
                sleep(Duration.millisecond * 100)
            }
        }
        sleep(Duration.second * 5)
        // throw Exception()
    }
}