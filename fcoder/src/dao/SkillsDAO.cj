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
package fountain::fcoder.dao

import fountain::f_orm.macros.*

@DAO
public interface SkillsDAO <: RootDAO {
    func findSkills(agentId: Int64, event: String): ArrayList<Skill> {
        executor.setSql('''
        select s.id,
               ag.agent_id,
               s.accepted_event,
               s.returned_event,
               s.title,
               s.metadata,
               s.details
          from skills as s
         inner 
          join agent_skills as ag
            on s.id = ag.skill_id
         where ag.agent_id = ${arg(agentId)}
           and s.accepted_event = ${arg(event)}
        ''').list<Skill>()
    }
    func loadSkills(title: ArrayList<String>): ArrayList<Skill> {
        executor.setSql('''
        select id,
               agent_id,
               accepted_event,
               returned_event,
               title,
               metadata,
               details
          from skills
         where title ${IN(title)}
        ''').list<Skill>()
    }
    func loadSkillReferences(references: ArrayList<SkillReferenceParam>): ArrayList<SkillReference> {
        func addArgs(){
            let args = StringBuilder()
            for(r in references){
                if(args.size > 0){
                    args.append(',')
                }
                let title = r.skill
                for(rr in r.reference){
                    args.append('(${arg(title)}, ${arg(rr)})')
                }
            }
            args.toString()
        }
        executor.setSql('''
        select s.title as skill_title,
               r.title,
               r.content 
          from skill as s 
         inner 
          join skill_references as r
            on s.id = r.skill_id
         where (s.title, r.title) in (${addArgs()})
        ''').list<SkillReference>()
    }
}