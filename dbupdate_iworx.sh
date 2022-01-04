#! /bin/sh

#Script to update MySQL or MariaDB automatically for Interworx or core managed servers.

if [[ -f "/usr/local/cpanel/cpanel" ]] || [[ -f "/usr/local/psa/version" ]]; then
        echo -e "This is intended to run on Interworx or core managed servers"
        kill -9 $$
else
        :
fi

#Function to execute and print
exe() { echo "\$ $@" ; "$@" ; }

#Function to Stop the script
stopp() {
        echo -e "\nXXX Errors have been detected. The script will stop. Run fg after you check to resume the script. XXX"
        kill -STOP $$
}

#Function to detect exit status
exit_status() {
e_status=`echo $?`
if [[ "$e_status" == "0" ]]; then
        :
else
        stopp
fi
}

#Functions to stop and restart the DBMS
restart_mariadb() {
(systemctl restart mariadb.service 2&> /dev/null && echo -e "Restarted") || (service mariadb restart 2&> /dev/null && echo -e "Restarted*")
}

stop_mariadb() {
(systemctl stop mariadb.service 2&> /dev/null && echo -e "MariaDB has been stopped") || (service mariadb stop 2&> /dev/null && echo -e "MariaDB has been stopped*") 
}

restart_mysql() {
(systemctl restart mysql.service 2&> /dev/null && echo -e "Restarted") || (service mysql restart 2&> /dev/null && echo -e "Restarted**") || (service mysqld restart 2&> /dev/null && echo -e "Restarted*")
}

stop_mysql() {
(systemctl stop mysql.service 2&> /dev/null && echo -e "MySQL has been stopped") || (service mysql stop 2&> /dev/null && echo -e "MySQL has been stopped*") || (service mysqld stop 2&> /dev/null && echo -e "MySQL has been stopped*") 
}

#Backing up my.cnf
echo -e "What's your username?"
read username
clear
if [[ ! -f "/etc/my.cnf.$username" ]]; then
echo -e "\nBacking up the configuration file:"
cp -avr /etc/my.cnf /etc/my.cnf.$username
fi

#SQL mode
echo -e "\n###SQL MODE:"
(grep -Eq 'sql_mode|sql-mode' /etc/my.cnf &&
echo -e "\e[1;92m[PASS] \e[0;32mSQL mode is set explicitly.\e(B\e[m\n" ||
(echo -e "Current effective setting is: sql_mode=\"$(mysql -NBe 'select @@sql_mode;')\"\e(B\e[m"
echo -e "Adding it to my.cnf..."
sql2=$(mysql -NBe 'select @@sql_mode;')
sed -i "6i sql_mode=\"$sql2"\" /etc/my.cnf
echo -e "Confirming: grep -E 'sql_mode|sql-mode' /etc/my.cnf"
grep -E 'sql_mode|sql-mode' /etc/my.cnf
echo -e "\nRestarting for the changes to be effective."
restart_mariadb
restart_mysql
echo -e "Giving a few secs for the database server to start\n" && sleep 2
))

#Checking for Corrupted tables/dbs
  echo -e "\n###Checking for corruption:"
    mychecktemp=$(mysqlcheck -Asc)
    echo -e "\nmysqlcheck -Asc"
    if [[ -z "$mychecktemp" ]]; then
    echo -e "\nNo output. All good.\n"
    else
        echo $mychecktemp
        mychecktemp2=$(echo $mychecktemp | grep -iE "corrupt|crashe" )
        if [[ ! -z "$mychecktemp2" ]]; then
              stopp
        else
                echo -e "\nMinor errors/warnings\n"
        fi
    fi

    echo -e "###Backups:\n"
    if [[ ! -d "/home/temp/mysqldumps.$username" ]]; then
            mkdir -p /home/temp/mysqldumps.$username
    fi
    cd /home/temp/mysqldumps.$username
    (set -x; pwd)
    echo -e "\n-Dumping databases:"
    exe eval '(echo "SHOW DATABASES;" | mysql -Bs | grep -v '^information_schema$' | while read i ; do echo Dumping $i ; mysqldump --single-transaction $i | gzip -c > $i.sql.gz ; done)'
    echo
    error='0';count='';for f in $(/bin/ls *.sql.gz); do if [[ ! $(zegrep 'Dump completed on [0-9]{4}-([0-9]{2}-?){2}' ${f}) ]]; then echo "Possible error: ${f}"; error=$((error+1)); fi ; count=$((count+1)); done; (echo "Error count: ${error}"; echo "Total DB_dumps: ${count}"; echo "Total DBs: $(mysql -NBe 'SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE schema_name NOT IN ("information_schema");')";)|column -t
    if [[ "$error" != 0 ]]; then
    stopp
    fi

    echo -e "\n-Rsync data dir:\n"
    ddir=$(mysql -e "show variables;" |grep datadir| awk {'print $2'})
    bakdir=$(echo "$ddir"|rev | cut -c2-|rev)
    stop_mariadb
    stop_mysql
    sleep 1 && echo
    echo "Path to data dir: $ddir"
    echo "rsync -aHl $ddir $bakdir.backup/"
    rsync -aHl $ddir $bakdir.backup/
    exit_status
    echo -e "Synced\n"
    echo "Restarting..."
    restart_mariadb
    restart_mysql
    sleep 3


if [[ -f "/var/qmail/control/virtualdomains" ]]; then
#Pre-checks
    echo -e "\n\n###Checking HTTP status of all domains prior the upgrade:\n"
(for i in `cat "/var/qmail/control/virtualdomains"| cut -d ":" -f1`; do echo $i; done) | while read i; do curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i; echo $i; done > /home/temp/mysql_pre_upgrade_http_check
 (set -x; egrep -v '^(0|2)00 ' /home/temp/mysql_pre_upgrade_http_check)
else
        :
fi

#Post-check (HTTP status)
post_check() {
        (for i in `cat "/var/qmail/control/virtualdomains"| cut -d ":" -f1`; do echo $i; done) | while read i; do curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i; echo $i; done > /home/temp/mysql_post_upgrade_http_check
        echo -e "\n\nPost check:"
        echo "diff /home/temp/mysql_pre_upgrade_http_check /home/temp/mysql_post_upgrade_http_check"
        diff /home/temp/mysql_pre_upgrade_http_check /home/temp/mysql_post_upgrade_http_check
}

#Version checking to ensure safe upgrades
safe_diff() {
read vers
ver_diff=$(echo "$db_ver $vers"| awk '{print $1 - $2}')
ver_diff=$( sed "s/-//" <<< $ver_diff )
}

db_ver=$(mysql -V| grep -Eo "[0-9]+\.[0-9]+\.[0-9]+"|cut -c1-4)
echo -e "\nCurrent DB version is $db_ver\n"

#Function containing all the steps for the upgrade of MariaDB
upgrade_mariadb() {
if [ -f "/etc/yum.repos.d/MariaDB.repo" ] ; then
  mv /etc/yum.repos.d/MariaDB.repo /etc/yum.repos.d/mariadb.repo
fi

echo -e "\n###Removing mysql-server package in case it exists"
echo "With rpm e mysql-server"
rpm -e --nodeps "`rpm -q --whatprovides mysql-server`" 2&> /dev/null

echo -e "\n\n###Upgrading MariaDB -"
echo -e "\n-List of available versions:\n\n10.2\n10.3\n10.4\n10.5\n10.6\n"
echo -e "\nWhich one are you installing? Only the version: 10.3, 10.4, etc.)."
db_ver=$(mysql -V| grep -Eo "[0-9]+\.[0-9]+\.[0-9]+"|cut -c1-4)
safe_diff
while true; do
        if [[ "$vers" == '10.2' ]] || [[ "$vers" == '10.3' ]] || [[ "$vers" == '10.4' ]] || [[ "$vers" == '10.5' ]] || [[ "$vers" == '10.6' ]] && [[ $vers < $db_ver ]]; then
            echo "Downgrades are not supported at this time, select another version."
            safe_diff
        elif [[ "$vers" == '10.2' ]] || [[ "$vers" == '10.3' ]] || [[ "$vers" == '10.4' ]] || [[ "$vers" == '10.5' ]] || [[ "$vers" == '10.6' ]] && [[ $ver_diff == '0.2' ]] ; then
            echo "Command line upgrades should be done incrementally to avoid damage, like 5.5 -> 5.6 -> 5.7 rather than straight from 5.5 -> 5.7. Please select an older version."
            safe_diff
         elif [[ "$vers" == '10.2' ]] || [[ "$vers" == '10.3' ]] || [[ "$vers" == '10.4' ]] || [[ "$vers" == '10.5' ]] || [[ "$vers" == '10.6' ]] && [[ $ver_diff > '0.2' ]] ; then
            echo "Command line upgrades should be done incrementally to avoid damage, like 5.5 -> 5.6 -> 5.7 rather than straight from 5.5 -> 5.7. Please select an older version."
            safe_diff
        elif  [[ "$vers" == '10.2' ]] || [[ "$vers" == '10.3' ]] || [[ "$vers" == '10.4' ]] || [[ "$vers" == '10.5' ]] || [[ "$vers" == '10.6' ]] && [[ $ver_diff < '0.2' ]]; then
            break
        else
            echo "Invalid option, choose again."
            safe_diff
        fi
done

#Adding the repo
echo "#http://downloads.mariadb.org/mariadb/repositories/
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/$vers/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1" > /etc/yum.repos.d/mariadb.repo

stop_mariadb
rpm -e --nodeps MariaDB-server

echo -e "\n-yum update -y"
yum update -y
exit_status
echo -e "\n-yum install MariaDB-server -y"
yum install MariaDB-server -y
exit_status
systemctl start mariadb
sleep 2
mysql_upgrade
restart_mariadb

/usr/bin/systemctl start mariadb # to start MariaDB if not started
/usr/bin/systemctl enable mariadb # to make sure that MariaDB will start after the server reboot automatically
}

#Function containing all the steps for the upgrade of MySQL
upgrade_mysql() {
echo -e "\n\n###Upgrading MySQL -"
echo -e "\n-List of available versions:\n\n5.6\n5.7\n8.0\n"
echo -e "\nWhich one are you installing? Only the version: 5.6, 8.0, etc.)."
db_ver=$(mysql -V| grep -Eo "[0-9]+\.[0-9]+\.[0-9]+"|cut -c1-3)
safe_diff
while true; do
        if [[ "$vers" == '5.6' ]] || [[ "$vers" == '5.7' ]] || [[ "$vers" == '8.0' ]] && [[ $vers < $db_ver ]]; then
            echo "Downgrades are not supported at this time, select another version."
            safe_diff
        elif [[ "$vers" == '5.6' ]] || [[ "$vers" == '5.7' ]] || [[ "$vers" == '8.0' ]] && [[ $ver_diff == '0.2' ]] ; then
            echo "Command line upgrades should be done incrementally to avoid damage, like 5.5 -> 5.6 -> 5.7 rather than straight from 5.5 -> 5.7. Please select an older version."
            safe_diff
        elif [[ "$vers" == '5.6' ]] || [[ "$vers" == '5.7' ]] || [[ "$vers" == '8.0' ]] && [[ $ver_diff > '0.2' ]] ; then
            echo "Command line upgrades should be done incrementally to avoid damage, like 5.5 -> 5.6 -> 5.7 rather than straight from 5.5 -> 5.7. Please select an older version."
            safe_diff
        elif [[ "$vers" == '5.6' ]] || [[ "$vers" == '5.7' ]] || [[ "$vers" == '8.0' ]] && [[ $ver_diff < '0.2' ]]; then
            break
        else
            echo "Invalid option, choose again."
            safe_diff
        fi
done
vers2=$(echo $vers|sed -e 's/\.//g')

#Adding the repo
echo "[mysql$vers2-community]
name=MySQL $vers Community Server
baseurl=http://repo.mysql.com/yum/mysql-$vers-community/el/7/x86_64/
enabled=1
gpgcheck=0" > /etc/yum.repos.d/mysql-community.repo

stop_mysql
rpm -e --nodeps `rpm -q --whatprovides mysql-server` 2&> /dev/null

echo -e "\nyum update -y"
yum update -y
exit_status
echo -e "\nyum install MySQL-server -y"
yum install mysql-server -y
exit_status
systemctl start mysql 2&> /dev/null
systemctl start mysqld 2&> /dev/null
sleep 2
mysql_upgrade
restart_mysql

systemctl start mysql 2&> /dev/null
systemctl start mysqld 2&> /dev/null
}

#Upgrade execution
up_exec() {
whichv=$(rpm -qa | grep -iEe mysql.*-server -iEe mariadb.*-server)
whichv=$(echo "$whichv" | awk '{print tolower($0)}')
if [[ "$whichv" == "mysql"* ]]; then
	upgrade_mysql
elif [[ "$whichv" == "mariadb"* ]]; then
	upgrade_mariadb
else
	echo "This server does not meet the requirements for this script to run (no MySQL or MariaDB installed)."
	stopp
fi
}

up_exec
post_check

echo -e "\n\nUpgrade completed."

while true; do
	echo -e "\nWant to upgrade to an even most recent version?"
	read answ
    	if [[ $answ == "yes" || $answ == "Yes" || $answ == "YES" || $answ == "y" ]]; then
        	up_exec
		post_check
		echo -e "\n\nUpgrade completed."
    	else
        	echo "Ok, we're done."
		break
    	fi
done
