#!/bin/bash

# pattern可省略，有默认值
export logger_appender_console_level=ERROR
export logger_appender_console_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%m'
export logger_appender_file_level=INFO
export logger_appender_file_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%m'
export logger_appender_file_rotateDuration=DAY

fboot run $1 --dylibPattern='controller|common'