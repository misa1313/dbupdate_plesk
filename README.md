# dbupdate_plesk

A bash script to automatically upgrade the database management system on Plesk servers. Tested on CentOS 7.


## Usage:

Enter any username (this is for reference).
Select the proper MYSQL/MariaDB version:
```
    5.6 (MySQL)
    5.7 (MySQL)
    8.0 (MySQL)
    10.2 (MariaDB)
    10.3 (MariaDB)
    10.4 (MariaDB)
    10.5 (MariaDB)
    10.6 (MariaDB)
 ```
 
## Features:

The script will first check the SQL mode to set it explicitly in the my.cnf file (if it's not already there), then it will check for corruption, dump all the databases, back up the data dir, and lastly proceed with the upgrade. The script will be automatically stopped if an issue is detected during the backup or upgrade process.
Can be executed directly with the following command via SSH:

```bash <(curl -s https://repo.stardustziggy.com/dbupdate_plesk.sh)```
