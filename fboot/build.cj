import std.env
//构建脚本
func stagePreBuild(): Int64 {
    0
}

@When[os == 'Linux']
func stagePostBuild(): Int64 {
    
    0
}
@When[os != 'Linux']
func stagePostBuild(): Int64 {
    0
}

func stagePreClean(): Int64 {
    println('PRE-CLEAN')
    0
}

func stagePostClean(): Int64 {
    println('PRE-CLEAN')
    0
}

main(args: Array<String>): Int64 {
    match (args[0]) {
        case "pre-build" => stagePreBuild()
        case "post-build" => stagePostBuild()
        case "pre-clean" => stagePreClean()
        case "post-clean" => stagePostClean()
        case _ => 0
    }
}
