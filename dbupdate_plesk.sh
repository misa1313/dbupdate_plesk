#! /bin/sh

#Script to update MySQL or MariaDB automatically for Plesk servers. 
if [[ ! -f "/usr/local/psa/version" ]]; then
        echo -e "This is intended to run on Plesk servers."
        kill -9 $$
else
        :
fi

#Blocking if version is MySQL 5.1/ MariaDB 5.3
v1=$(rpm -qa | grep -iEe mysql.*-server |grep -v plesk|grep  "\-5.1.")
v2=$(rpm -qa | grep -iEe mariadb.*-server |grep -v plesk|grep "\-5.3.")
if [[ ! -z "$v1" ]] || [[ ! -z "$v2" ]]; then
    echo -e "\nMariaDB 5.3 and MySQL 5.1 are not supported."
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
clear
date=$(/usr/bin/date +%s)
if [[ ! -f "/etc/my.cnf.$date" ]]; then
echo -e "\nBacking up the configuration file to my.cnf.$date:"
cp -avr /etc/my.cnf /etc/my.cnf.$date
fi

#SQL mode
echo -e "\n###SQL MODE:"
(grep -Eq 'sql_mode|sql-mode' /etc/my.cnf &&
echo -e "\e[1;92m[PASS] \e[0;32mSQL mode is set explicitly.\e(B\e[m\n" ||
(echo -e "Current effective setting is: sql_mode=\"$(mysql -uadmin -p`cat /etc/psa/.psa.shadow` -NBe 'select @@sql_mode;')\"\e(B\e[m"
echo -e "Adding it to my.cnf..."
sql2=$(mysql -uadmin -p`cat /etc/psa/.psa.shadow` -NBe 'select @@sql_mode;')
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
    mychecktemp=$(mysqlcheck -uadmin -p`cat /etc/psa/.psa.shadow` -Asc)
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
    if [[ ! -d "/home/temp/mysqldumps.$date" ]]; then
            mkdir -p /home/temp/mysqldumps.$date
    fi
    echo "The backup dir is /home/temp/mysqldumps.$date"
    cd /home/temp/mysqldumps.$date
    (set -x; pwd)
    echo -e "\n-Dumping databases:"
    exe eval '(echo "SHOW DATABASES;" | mysql -uadmin -p`cat /etc/psa/.psa.shadow` -Bs | grep -v '^information_schema$' | while read i ; do echo Dumping $i ; mysqldump -uadmin -p`cat /etc/psa/.psa.shadow` --single-transaction $i | gzip -c > $i.sql.gz ; done)'
    echo
    error='0';count='';for f in $(/bin/ls *.sql.gz); do if [[ ! $(zegrep 'Dump completed on [0-9]{4}-([0-9]{2}-?){2}' ${f}) ]]; then echo "Possible error: ${f}"; error=$((error+1)); fi ; count=$((count+1)); done; (echo "Error count: ${error}"; echo "Total DB_dumps: ${count}"; echo "Total DBs: $(mysql -uadmin -p`cat /etc/psa/.psa.shadow` -NBe 'SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE schema_name NOT IN ("information_schema");')";)|column -t
    if [[ "$error" != 0 ]]; then
    stopp
    fi

    echo -e "\n\n-Rsync data dir:"
    ddir=$(mysql -uadmin -p`cat /etc/psa/.psa.shadow` -e "show variables;" |grep datadir| awk {'print $2'})
    bakdir=$(echo "$ddir"|rev | cut -c2-|rev)
    stop_mariadb;stop_mysql
    sleep 1 && echo
    echo "Path to data dir: $ddir"
    echo "rsync -aHl $ddir $bakdir.backup/"
    rsync -aHl $ddir $bakdir.backup/
    exit_status
    echo -e "Synced\n"
    echo "Restarting..."
    restart_mariadb;restart_mysql
    sleep 2

    echo -e "\n\n###Checking HTTP status of all domains prior the upgrade:\n"
    (for i in `mysql -uadmin -p\`cat /etc/psa/.psa.shadow\` psa -Ns -e "select name from domains"`; do echo $i; done) | while read i; do curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i; echo $i; done > /home/temp/mysql_pre_upgrade_http_check
 (set -x; egrep -v '^(0|2)00 ' /home/temp/mysql_pre_upgrade_http_check)

#Post-check (HTTP status)
post_check() {
(for i in `mysql -uadmin -p\`cat /etc/psa/.psa.shadow\` psa -Ns -e "select name from domains"`; do echo $i; done) | while read i; do curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i; echo $i; done > /home/temp/mysql_post_upgrade_http_check
echo -e "\n\nPost check:"
echo "diff /home/temp/mysql_pre_upgrade_http_check /home/temp/mysql_post_upgrade_http_check"
diff /home/temp/mysql_pre_upgrade_http_check /home/temp/mysql_post_upgrade_http_check
}

#Version checking to ensure safe upgrades
safe_diff() {
read versl
vers=$(echo $versl|tr -d '.')
ver_diff=$(echo "$db_ver $vers"| awk '{print $1 - $2}')
ver_diff=$( sed "s/-//" <<< $ver_diff ) #absolute value
}

get_version(){
db_ver=$(mysql -uadmin -p`cat /etc/psa/.psa.shadow` -V| grep -Eo "[0-9]+\.[0-9]+\.[0-9]+"|cut -c1-4) #Get version
echo -e "\nCurrent version is $db_ver\n"
db_ver=$(echo $db_ver|tr -d '.')
}

get_version
#Function to select the version to install
select_version() {
while true; do
        if [[ "${supported_versions[@]}" =~ "$vers" ]] && [[ "$vers" -lt "$db_ver" ]]; then
            echo "Downgrades are not supported at this time, select another version."
            safe_diff
        elif [[ "$whichv" == "mariadb"* ]] && [[ "$vers" == '102' ]] && [[ "$db_ver" == '55' ]] ; then
	    break
	elif [[ "${supported_versions[@]}" =~ "$vers" ]] && [[ $ver_diff == '2' ]] ; then
            echo "Command line upgrades should be done incrementally to avoid damage, like 5.5 -> 5.6 -> 5.7 rather than straight from 5.5 -> 5.7. Please select an older version."
            safe_diff
         elif [[ "${supported_versions[@]}" =~ "$vers" ]] && [[ $ver_diff > '2' ]] ; then
           echo "Command line upgrades should be done incrementally to avoid damage, like 5.5 -> 5.6 -> 5.7 rather than straight from 5.5 -> 5.7. Please select an older version."
           safe_diff
        elif  [[ "${supported_versions[@]}" =~ "$vers" ]] && [[ $ver_diff < '2' ]]; then
            break
        else
            echo "Invalid option, choose again."
            safe_diff
        fi
done
}

#Function containing all the steps for the upgrade of MariaDB
upgrade_mariadb() {
if [ -f "/etc/yum.repos.d/MariaDB.repo" ] ; then
  mv /etc/yum.repos.d/MariaDB.repo /etc/yum.repos.d/mariadb.repo
fi

echo -e "\n###Removing mysql-server package in case it exists"; echo "With rpm e mysql-server"
rpm -e --nodeps "`rpm -q --whatprovides mysql-server`" 2&> /dev/null

echo -e "\n\n###Upgrading MariaDB -"; echo -e "\n-List of available versions:\n\n10.2\n10.3\n10.4\n10.5\n10.6\n"
echo -e "\nWhich one are you installing? Only the version: 10.3, 10.4, etc.)."
safe_diff
supported_versions=(102 103 104 105 106)
select_version

#Adding the repo
if [[ "$versl" == '10.2' ]]; then
	versl=10.2.44 #Repo for 10.2 is broken
fi
echo "#http://downloads.mariadb.org/mariadb/repositories/
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/$versl/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
exclude=MariaDB-Galera*" > /etc/yum.repos.d/mariadb.repo

stop_mariadb
rpm -e --nodeps MariaDB-server

echo -e "\n-yum update"
yum update -y; exit_status
echo -e "\n-yum install MariaDB-server -y"
yum install MariaDB-server -y; exit_status
sed -i 's/::ffff:127.0.0.1/127.0.0.1/g' /etc/my.cnf
systemctl start mariadb; sleep 2
restart_mariadb
MYSQL_PWD=`cat /etc/psa/.psa.shadow` mysql_upgrade -uadmin

echo -e "\nInforming Plesk of the changes (plesk sbin packagemng -sdf):"
plesk sbin packagemng -sdf
systemctl start mariadb # to start MariaDB if not started
systemctl enable mariadb # to make sure that MariaDB will start after the server reboot automatically
restart_mariadb
}

#Function containing all the steps for the upgrade of MySQL
upgrade_mysql() {
echo -e "\n\n###Upgrading MySQL -"; echo -e "\n-List of available versions:\n\n5.6\n5.7\n8.0\n"
echo -e "\nWhich one are you installing? Only the version: 5.6, 8.0, etc.)."
safe_diff
supported_versions=(56 57 80)
select_version

#Adding the repo
echo "[mysql$vers-community]
name=MySQL $versl Community Server
baseurl=http://repo.mysql.com/yum/mysql-$versl-community/el/7/x86_64/
enabled=1
gpgcheck=0" > /etc/yum.repos.d/mysql-community.repo

stop_mysql
rpm -e --nodeps `rpm -q --whatprovides mysql-server` 2&> /dev/null

echo -e "\nyum update"
yum update -y; exit_status
echo -e "\nyum install MySQL-server -y"
yum install mysql-server -y; exit_status
sed -i 's/::ffff:127.0.0.1/127.0.0.1/g' /etc/my.cnf
systemctl start mysql 2&> /dev/null
systemctl start mysqld 2&> /dev/null; sleep 2
restart_mysql
MYSQL_PWD=`cat /etc/psa/.psa.shadow` mysql_upgrade -uadmin

echo -e "\nInforming Plesk of the changes (plesk sbin packagemng -sdf):"
plesk sbin packagemng -sdf
systemctl start mysql 2&> /dev/null
systemctl start mysqld 2&> /dev/null
restart_mysql
}

cloudlinux_governor() {
echo -e "The server is using CloudLinux's MySQL Governor\n"
echo -e "\nTo which version would you like to upgrade?\nOptions:\n\nMYSQL:\nmysql55, mysql56, mysql57, mysql80\n\nMariaDB:\nmariadb100, mariadb101, mariadb102, mariadb103, mariadb104, mariadb105, mariadb106\n"
read clvers
supported_versions=(mysql55 mysql56 mysql57 mysql80 mariadb100 mariadb101 mariadb102 mariadb103 mariadb104 mariadb105 mariadb106)
while true; do
        if [[ "${supported_versions[@]}" =~ "$clvers" ]]; then
		echo -e "\nUpgrading to $clvers using the MySQL Governor script:"
    		exe eval '/usr/share/lve/dbgovernor/mysqlgovernor.py --mysql-version=$clvers'
    		exe eval '/usr/share/lve/dbgovernor/mysqlgovernor.py --install --yes'
		break
        else
            echo "Invalid option, choose again."
	    read clvers
        fi
done
}

#Upgrade execution
up_exec() {
whichv=$(rpm -qa | grep -iEe mysql.*-server -iEe mariadb.*-server |grep -v plesk)
whichv=$(echo "$whichv" | awk '{print tolower($0)}')
rpm -qa|grep -i "cl-mariadb\|cl-mysql" > /dev/null 2>&1 #Checking if there are MySQL Governor packages
if [[ $? -eq 0 ]] && [[ -f "/usr/share/lve/dbgovernor/mysqlgovernor.py" ]]; then
	cloudlinux_governor
elif [[ "$whichv" == "mysql"* ]]; then
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
	echo -e "\nDo you want to start another update process?"
	read answ
    	if [[ $answ == "yes" || $answ == "Yes" || $answ == "YES" || $answ == "y" ]]; then
		get_version
        	up_exec
		post_check
		echo -e "\n\nUpgrade completed."
    	else
        	echo "Ok, we're done."
		break
    	fi
done
