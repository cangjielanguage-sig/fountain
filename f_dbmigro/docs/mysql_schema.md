```sql
--索引
SELECT TABLE_SCHEMA,
       TABLE_NAME,
       INDEX_NAME,
       NON_UNIQUE, --0 具有唯一性，1 没有唯一性
       COLUMN_NAME,
       INDEX_TYPE --btree
FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = 'wifiin_server_platform_0' AND TABLE_NAME = 'platform_user_center_device'
--表
SELECT COLUMN_NAME AS '列名',  
       COLUMN_TYPE AS '数据类型',  
       IS_NULLABLE AS '是否为空',  
       COLUMN_DEFAULT AS '默认值',  
       COLUMN_COMMENT AS '注释',  
       CHARACTER_SET_NAME AS '字符集',  
       COLLATION_NAME AS '排序规则'  
  FROM information_schema.COLUMNS  
 WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?  
 ORDER 
    BY ORDINAL_POSITION;
```
