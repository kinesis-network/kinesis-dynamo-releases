@echo off
rem Fallback probe with no internet and no PowerShell one-liner. Same log file.
if not exist C:\Kinesis mkdir C:\Kinesis
echo === %DATE% %TIME% event=%1 host=%COMPUTERNAME% user=%USERNAME% session=%SESSIONNAME% >> C:\Kinesis\hook.log
whoami /groups | findstr /i "S-1-16- S-1-5-4 S-1-5-18" >> C:\Kinesis\hook.log
echo. >> C:\Kinesis\hook.log
