package launcher

import fountain.App
import boot.*
import user.controller.*
import user.service.impl.*
import user.util.auth.*

main(): Int64 {
    App(['run'], dynamic: false).boot()
    return 0
}