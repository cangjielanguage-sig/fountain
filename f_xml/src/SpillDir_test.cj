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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.{Directory, removeIfExists}
import std.env

@Test
public class SpillDir_test {
    /** 无显式 spillDir 时 TMPDIR 排第一。 */
    @TestCase
    public func tmpdirIsFirstCandidateWithoutExplicit(): Unit {
        let old = env.getVariable("TMPDIR")
        let dir = Directory.createTemp(env.getTempDirectory())
        try {
            env.setVariable("TMPDIR", dir.toString())
            let candidates = SpillDir.candidates(EntityLimits())
            assertTrue(candidates.size >= 1, "至少一个候选")
            assertTrue(candidates[0].toString() == dir.toString(),
                "首个候选应为 TMPDIR ${dir}，实际 ${candidates[0]}")
        } finally {
            match (old) {
                case Some(value) => env.setVariable("TMPDIR", value)
                case None => env.removeVariable("TMPDIR")
            }
            removeIfExists(dir)
        }
    }

    /** 显式 spillDir 优先于 TMPDIR。 */
    @TestCase
    public func explicitBeatsTmpdir(): Unit {
        let old = env.getVariable("TMPDIR")
        let tmp = Directory.createTemp(env.getTempDirectory())
        let explicit = Directory.createTemp(env.getTempDirectory())
        try {
            env.setVariable("TMPDIR", tmp.toString())
            let candidates = SpillDir.candidates(EntityLimits(spillDir: Some(explicit)))
            assertTrue(candidates[0].toString() == explicit.toString(),
                "显式 spillDir 应排第一，实际 ${candidates[0]}")
        } finally {
            match (old) {
                case Some(value) => env.setVariable("TMPDIR", value)
                case None => env.removeVariable("TMPDIR")
            }
            removeIfExists(tmp)
            removeIfExists(explicit)
        }
    }
}
