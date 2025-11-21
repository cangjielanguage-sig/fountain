#!/bin/bash

rand(){
    randstr=$(tr -dc 'a-zA-Z0-9_' < /dev/urandom | head -c 10)
    echo $randstr
}
host='http://localhost:8080'
### db first
echo '============================1'
curl -XPOST $host/api/db/first \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "123"
}'
echo
echo '============================2'

### get value of first reacord
curl -XPOST $host/api/db/singleFirstDemo \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "123"
}'
echo
echo '============================3'

### 复杂查询 password= ? and (id=1 or id=2)
curl -XPOST $host/api/db/pageWithSubCondition \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "456"
}'
echo
echo '============================4'


### update user_info set save_time =null where username = ?
curl -XPOST $host/api/db/updateNull \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin"
}'
echo
echo '============================5'




### id=1 用户更新密码。包含更新日期类型
curl -XPUT $host/api/db/updatePassword \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "id": 1,
  "password": 456
}'
echo
echo '============================6'



### id=1 用户更新数据-map的形式。
curl -XPUT $host/api/db/updateMap \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "id": 1,
  "username": "admin",
  "password": "map"
}' 
echo
echo '============================7'


### updateMapDemo
curl -XPOST $host/api/db/updateMapDemo \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "id": 1,
  "username": "admin",
  "password": "map"
}'
echo
echo '============================8'

### updateMapDemo2
curl -XPOST $host/api/db/updateMapDemo2 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "id": 1,
  "username": "admin",
  "password": "map"
}' 
echo
echo '============================9'

### updateMapDemo3
curl -XPOST $host/api/db/updateMapDemo3 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "id": 1,
  "username": "admin",
  "password": "map"
}' 
echo
echo '============================10'



### id=1 用户更新数据- sql语句的形式。包含 Option None
curl -XPUT $host/api/db/updateSql \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "id": 1,
  "username": "admin-upate-sql",
  "password": 456
}' 
echo
echo '============================11'



### whereDemo
curl -XPOST $host/api/db/whereDemo \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "6"
}' 
echo
echo '============================12'




### db page
curl -XPOST $host/api/db/page \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "123"
}'
echo
echo '============================13'




### db list
curl -XPOST $host/api/db/listDemo \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "123"
}'
echo
echo '============================15'


### db list 2
curl -XPOST $host/api/db/listDemo2 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "123"
}' 
echo
echo '============================16'



### in demo 1
curl -XPOST $host/api/db/inDemo1 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "ids": [
    1,
    2
  ]
}' 
echo
echo '============================17'


### in demo 2
curl -XPOST $host/api/db/inDemo2 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "ids": [
    1,
    2,
    3,
    4,
    5,
    65
  ]
}'
echo
echo '============================18'


### in demo 3
curl -XPOST $host/api/db/inDemo3 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "ids": [
    1,
    2,
    3,
    4,
    5,
    65
  ]
}' 
echo
echo '============================19'




### like demo 1
curl -XPOST $host/api/db/likeDemo1 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin"
}'
echo
echo '============================20'



### like demo 2
curl -XPOST $host/api/db/likeDemo2 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin"
}' 
echo
echo '============================21'



### not like demo 1
curl -XPOST $host/api/db/notLikeDemo1 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin"
}'
echo
echo '============================22'


### meet demo
curl -XPOST $host/api/db/meetDemo \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "6"
}'
echo
echo '============================23'

### meet demo 2
curl -XPOST $host/api/db/meetDemo2 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin",
  "password": "6"
}' 
echo
echo '============================24'



### transaction
curl -XPOST $host/api/db/transaction \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "transaction_$(rand)",
  "password": "6"
}' 
echo
echo '============================25'

### transactionDemo2
curl -XPOST $host/api/db/transactionDemo2 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "transactionDemo2_$(rand)",
  "password": "6"
}' 
echo
echo '============================26'


### transactionDemo3
curl -XPOST $host/api/db/transactionDemo3 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "transactionDemo3_$(rand)",
  "password": "transactionDemo3"
}' 
echo
echo '============================27'

### expectExceptionDemo
curl -XPOST $host/api/db/expectExceptionDemo \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "expectException$(rand)",
  "password": "expectException"
}' 
echo
echo '============================'



### insertDemo
curl -XPOST $host/api/db/insert \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "insert_$(rand)",
  "password": "123456"
}' 
echo
echo '============================29'


### insertDemo2
curl -XPOST $host/api/db/insertDemo2 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "insert2_$(rand)",
  "password": "123456"
}' 
echo
echo '============================30'



### delete
curl -XPOST $host/api/db/delete \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{
  "username": "admin110701",
  "password": "123456"
}' 
echo
echo '============================31'



### deleteDemo2
curl -XPOST $host/api/db/deleteDemo2 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{ "username": "admin110701", "password": "123456" }' 
echo
echo '============================32'

### deleteDemo3
curl -XDELETE $host/api/db/deleteDemo3 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{}'
echo
echo '============================33'

### deleteDemo4
curl -XDELETE $host/api/db/deleteDemo4 \
-H'Accept:application/json' \
-d'{ "username": "admin110701", "password": "123456" }'
echo
echo '============================34'


### deleteDemo5
curl -XDELETE $host/api/db/deleteDemo5/1 \
-H'Content-Type:application/x-www-form-urlencoded' \
-H'Accept:application/json' \
-d'{ "username": "admin110701", "password": "123456" }' 
echo
echo '============================35'

### deleteDemo6
curl -XDELETE $host/api/db/deleteDemo6/1 \
-H'Content-Type:application/x-www-form-urlencoded' \
-H'Accept:text/plain' 
echo
echo '============================36'

### deleteDemo7
curl -XDELETE $host/api/db/deleteDemo7/1 \
-H'Content-Type:application/json' \
-H'Accept:application/json' \
-d'{}'
echo
echo '============================37'



