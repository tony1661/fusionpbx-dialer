# fusionpbx-dialer
A basic dialer that I created for FusionPBX

This works by reading from a database table that I created in postgres and tracking the progress of each call.

This script should be executed by a cron job using the shell command ```fs_cli -x "lua dialer-service.lua"```
