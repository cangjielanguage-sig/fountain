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

import fountain::f_llm.store.*

/**
 * 技能演进报告：把一轮 `SkillEvolutionReport` 落成独立表里的多行记录。
 *
 * 表由 [EvolutionStore] 提供（`f_store` 或内存实现），不做向量检索——
 * 审计只需要「按技能 + 时间」查，关键词/前缀扫描足够，也就无需 `f_hydra`。
 */
public class SkillEvolutionLedger {
    private init() {
    }

    /** 把一轮报告写进报告表，返回写入条数 */
    public static func write(store: EvolutionStore, report: SkillEvolutionReport,
                             at: Int64): Int64 {
        var written: Int64 = 0
        if(save(store, report.evolved, 'evolved', at)){
            written += Int64(report.evolved.size)
        }
        if(save(store, report.created, 'created', at)){
            written += Int64(report.created.size)
        }
        if(save(store, report.rejected, 'rejected', at)){
            written += Int64(report.rejected.size)
        }
        if(save(store, report.skipped, 'skipped', at)){
            written += Int64(report.skipped.size)
        }
        written
    }

    /** 最近的记录（按 at 倒序） */
    public static func list(store: EvolutionStore, limit!: Int64 = 20): ArrayList<EvolutionEntry> {
        store.list(0, limit)
    }

    /** 某个技能的历史演进记录 */
    public static func history(store: EvolutionStore, skillTitle: String,
                               limit!: Int64 = 20): ArrayList<EvolutionEntry> {
        store.bySkill(skillTitle, limit)
    }

    private static func save(store: EvolutionStore, lines: ArrayList<String>,
                             action: String, at: Int64): Bool {
        if(lines.isEmpty()){
            return false
        }
        for(line in lines){
            // 报告行形如 `技能名: 原因`，标题取冒号前那段
            let title = if(line.contains(':')){ line.split(':')[0].trimAscii() }else{ line }
            store.save(EvolutionEntry(0, title, action, line, at))
        }
        true
    }
}
