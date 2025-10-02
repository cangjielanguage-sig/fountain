package fdemo_App__vErsIOn___Impl____
import fountain.AppVersion
import fountain.bean.macros.Bean
import fountain.bean.*
@Bean
public class fdemo_AppVersionImpl <: AppVersion {
    public prop version: String {
        get() {
            '1.0.0'
        }
    }
    public prop banner: String {
        get() {
            #'  _____   .___                     
_/ ____\__| _/____   _____   ____  
\   __\/ __ |/ __ \ /     \ /  _ \ 
 |  | / /_/ \  ___/|  Y Y  (  <_> )
 |__| \____ |\___  >__|_|  /\____/ 
           \/    \/      \/        '#
        }
    }
}
