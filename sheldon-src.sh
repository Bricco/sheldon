#!/bin/bash


ARGV="$@"

if [ "x$ARGV" = "x" ] ; then
    ARGV="-h"
fi

if [[ $EUID -eq 0 ]]; then
   echo "This script should NOT be run as root" 1>&2
   exit 1
fi

function usage {
    echo "
Usage: $0 install|create|content-update [--target=path] [--env=[TEST|PROD]] [--name=sitename] [--from=[TEST|PROD]]
COMMANDS
    install		Installs Drupal locally or remotely.
    	--target=path		Where to install locally. Defaults to current directory.
    	--env=[TEST|PROD]	Where to install remotely. 

    create		Creates a fully functional Drupal project. Includes setting up database and Apache config.
    	--name=projectname	The name of the project.

    content-update	Updates local content from test or prod environment
    	--from=[TEST|PROD]	Where to get the content.	
"
    exit 0
}


#if [[ ${#@} -ne 2 &&  "$1" != "upgrade" ]]; then
#  usage;
#fi



## READ PROPERTIES
if [ -e "properties" ]
then
. properties
else
  echo "properties file must exist!"
  exit 
fi

PROJECT=${PROJECT:-"$(basename *.make .make)"}

if [ ! -e "$PROJECT.make" ]
then
  echo ".make file must exist!"
  exit;
fi


PROJECT=${PROJECT:-"$(basename *.make .make)"}
PROJECT_LOCATION="$(pwd)"

DATABASE=${DATABASE:-"$PROJECT"}
DATABASE_USER=${DATABASE_USER:-"$DATABASE"}
DATABASE_PASS=${DATABASE_PASS:-"secret"}
SITE_URL="dev.$PROJECT.se"

APACHE_CMD=apache2ctl
APACHE_VHOSTS_DIR=/etc/apache2/sites-enabled

if [ "$(uname)" == "Darwin" ]; then
  APACHE_CMD=apachectl
  APACHE_VHOSTS_DIR=/etc/apache2/other
fi



function mysql_root_access {
  if [[ ! $MYSQL_ROOT_PASS_HAS_RUN ]]
  then
    read -sp "Enter your MySQL password (ENTER for none): " MYSQL_ROOT_PASS
    if [ -n "$MYSQL_ROOT_PASS" ]; then
      while ! mysql -u root -p$MYSQL_ROOT_PASS  -e ";" ; do
        read -p "Can't connect, please retry: " MYSQL_ROOT_PASS
      done
      MYSQL_ROOT_PASS="--password=$MYSQL_ROOT_PASS"
    else
      $MYSQL_ROOT_PASS=""
    fi
	
    MYSQL_ROOT_PASS_HAS_RUN=1
  fi
}

function exclude_files {

	for SITE in $PROJECT_LOCATION/sites/*
	do
		SITE_NAME="$(basename $SITE)"

		if [ $SITE_NAME != "all" ]
		then
			EXCLUDE="$EXCLUDE --exclude=sites/$SITE_NAME/files"
	
		fi
	
	done
}

function build_drupal {

	## DRUSH MAKE
	echo "Bulding $PROJECT.make, this can take a while..."
	rm -rf /tmp/$PROJECT || true
	drush make $PROJECT.make /tmp/$PROJECT > /dev/null 2>&1

	echo "Drush make complete."

	echo "Copy custom profiles, modules, themes etc..."

	## COPY CUSTOM PROFILES
	cp -r "$PROJECT_LOCATION/profiles" "/tmp/$PROJECT/" > /dev/null 2>&1 || true

	## COPY SITES
	cp -r "$PROJECT_LOCATION/sites" "/tmp/$PROJECT/" || true > /dev/null 2>&1

	for SITE in $PROJECT_LOCATION/sites/*
	do
		SITE_NAME="$(basename $SITE)"

		if [ $SITE_NAME != "all" ]
		then
			echo "Copy and filter sites/$SITE_NAME/settings.php"
			mkdir -p "/tmp/$PROJECT/sites/$SITE_NAME/files"
			cp $SITE/settings.php /tmp/$PROJECT/sites/$SITE_NAME/settings.php > /dev/null 2>&1
			
			## FILTER SETTINGS.PHP
			REPLACE=($DATABASE $DATABASE_USER $DATABASE_HOST $DATABASE_PASS "DEV"); i=0;
			for SEARCH in $(echo "@db.database@ @db.username@ @db.host@ @db.password@ @settings.ENVIRONMENT@" | tr " " "\n")
			do
				sed -i s/$SEARCH/${REPLACE[$i]}/g /tmp/$PROJECT/sites/$SITE_NAME/settings.php; ((i++));
			done
		fi
	done

}

function apache_install {

	echo "Creating apache config file: /etc/apache2/sites-enabled/$PROJECT.conf"
	
	VHOST="<VirtualHost *:80>
	ServerName $SITE_URL"

	for SITE in "$PROJECT_LOCATION/sites/*"
	do
		SITE_NAME="$(basename $SITE)"
		if [[ $SITE_NAME == "default" || $SITE_NAME == "all" ]]
		then
	  	  continue
		else	
		  SITE_URL="$SITE_URL dev.$SITE_NAME"
		  VHOST="$VHOST
		  ServerAlias dev.$SITE_NAME"
		fi
	done

	echo "$VHOST
	DocumentRoot $DEPLOY_DIR/$PROJECT/

		<Directory />
		        Options FollowSymLinks
		        AllowOverride All
		</Directory>
		<Directory $DEPLOY_DIR/$PROJECT>
		        Options +Indexes +FollowSymLinks +MultiViews +ExecCGI
		        AllowOverride All
		        Order allow,deny
		        allow from all
		</Directory>
		ErrorLog /var/log/apache2/$PROJECT-error.log
		LogLevel warn
		CustomLog /var/log/apache2/$PROJECT.log combined

	</VirtualHost>" | sudo tee $APACHE_VHOSTS_DIR/$PROJECT.conf > /dev/null

	echo "Adding $SITE_URL to /etc/hosts"

	grep -E "127.0.0.1(\s*)$SITE_URL" /etc/hosts

	if [ $? -eq 0 ]
	then 
	  echo "$SITE_URL allready exists in host file, didn't add anything";
	else
	   echo "Adding $SITE_URL to /etc/hosts"
	   echo -e "\n127.0.0.1 $SITE_URL\n" >> /etc/hosts
	fi

	echo -e "Restarting apache...\n"
	sudo $APACHE_CMD restart > /dev/null 2>&1
}

function mysql_install {
	
	for DB in $(echo ${DATABASE[*]} | tr " " "\n")
	do
	  mysql -u root -e $MYSQL_ROOT_PASS "CREATE DATABASE IF NOT EXISTS $DB;GRANT ALL PRIVILEGES ON $DB.* TO '$DATABASE_USER'@'$DATABASE_HOST' IDENTIFIED BY '$DATABASE_PASS';"
	done

}

function install_drupal {

	echo "Start installing $PROJECT"

	read -ep "DEPLOY DIR?: " -i "/var/www" DEPLOY_DIR
	
	mysql_root_access;
	apache_install;
	mysql_install;
	build_drupal;
	exclude_files;

	#RSYNC with delete,
	rsync --delete --cvs-exclude -akz $EXCLUDE /tmp/$PROJECT $DEPLOY_DIR/

	## MAKE SURE THESE FOLDERS EXISTS
	sudo mkdir -p "$DEPLOY_DIR/$PROJECT/sites/all/modules"
	sudo mkdir -p "$DEPLOY_DIR/$PROJECT/sites/all/themes"
	
	echo "Creating symlinks into workspace..."
	echo "$DEPLOY_DIR/$PROJECT/sites/all/modules/custom -> $PROJECT_LOCATION/sites/all/modules/custom"
	echo "$DEPLOY_DIR/$PROJECT/sites/all/modules/custom -> $PROJECT_LOCATION/sites/all/modules/custom"

	## SYMLINK CUSTOM MODULES AND THEMES IN TO WORKSPACE
	cd "$DEPLOY_DIR/$PROJECT/sites/all/modules";sudo rm -rf custom || true; sudo ln -s "$PROJECT_LOCATION/sites/all/modules/custom" custom
	cd "$DEPLOY_DIR/$PROJECT/sites/all/themes";sudo rm -rf custom || true; sudo ln -s "$PROJECT_LOCATION/sites/all/themes/custom" custom
	
	sudo chown -R $USER:$USER "$DEPLOY_DIR/$PROJECT"

	echo "BUILD successfull"

	read -ep "Do you want to update the database? 
(P = from PROD, T = from TEST, n = No) [P/T/n] " UPDATE

	if [ $UPDATE == "T" ]
	then
		content_update;
	fi
	
	echo "You can now visit http://dev.$PROJECT.se"
	echo "Bazinga!"

}


function deploy { 

	build_drupal;
	exclude_files;

	#RSYNC with delete,
	rsync --delete --cvs-exclude -akz $EXCLUDE /tmp/$PROJECT $TEST_USER@$TEST_HOST:"$(dirname $TEST_ROOT)/"

	for SITE in $PROJECT_LOCATION/sites/*
	do
		SITE_NAME="$(basename $SITE)"

		if [ $SITE_NAME != "all" ]
		then
			DRUSH_CMD="drush -l $SITE_NAME -r $TEST_ROOT"

			COMMAND="echo 'Put $SITE_NAME in maintenance mode' && $DRUSH_CMD vset 'maintenance_mode' 1 --exact --yes"
			COMMAND="$COMMAND && echo 'Disable elysia cron' && $DRUSH_CMD vset 'elysia_cron_disabled' 1 --exact --yes"
			COMMAND="$COMMAND && echo 'Revert all features' &&  $DRUSH_CMD fra --yes"
			COMMAND="$COMMAND && echo 'Run all updates' &&  $DRUSH_CMD updb --yes"
			COMMAND="$COMMAND && echo 'Turn off maintenance mode' &&  $DRUSH_CMD vset 'maintenance_mode' 0 --exact --yes"
			COMMAND="$COMMAND && echo 'Enable elysia cron' &&  $DRUSH_CMD vset 'elysia_cron_disabled' 0 --exact --yes"
			COMMAND="$COMMAND && echo 'Clear all cache' && $DRUSH_CMD cc all"

			ssh $TEST_USER@$TEST_HOST "$COMMAND"
			
			echo "Sleep for 15 sec" 			
			sleep 15
		fi
	done
	
	rm -rf /tmp/$PROJECT
	
}


function content_update { 
	mysql_root_access

	DATESTAMP=$(date +%s)
	CONNECTION="--user=$TEST_DATABASE_USER --host=$TEST_DATABASE_HOST --password=$TEST_DATABASE_PASS"
	OPTIONS="--no-autocommit --single-transaction --opt -Q"
	
	for(( i=0; i<${#DATABASE[@]}; i++ ))
	do
		echo "Running mysqldump command on server..."

		TABLES=$(ssh -q $TEST_USER@$TEST_HOST "mysql $CONNECTION -D ${TEST_DATABASE[i]} -Bse \"SHOW TABLES\"")


		for T in $TABLES
		do
			case "$T" in 
			  #ONLY MIGRATE TABLE STRUCTURE FROM THESE TABLES
			  *search_*|*cache_*|*watchdog|*history|*sessions)
			    EMPTY_TABLES="$EMPTY_TABLES $T"
			    ;;
			  *)
			    DATA_TABLES="$DATA_TABLES $T"
			    ;;
			esac		
		done


		QUERY="mysqldump $OPTIONS --add-drop-table $CONNECTION ${TEST_DATABASE[i]} $DATA_TABLES > /var/tmp/$PROJECT.sql-$DATESTAMP"
		QUERY="$QUERY && mysqldump --no-data $OPTIONS $CONNECTION ${TEST_DATABASE[i]} $EMPTY_TABLES >> /var/tmp/$PROJECT.sql-$DATESTAMP"
		QUERY="$QUERY && mv -f /var/tmp/$PROJECT.sql-$DATESTAMP /var/tmp/$PROJECT.sql"

		ssh -q $TEST_USER@$TEST_HOST $QUERY;

		echo "Rsync sql-dump-file from server..."
		rsync -akz --progress $TEST_USER@$TEST_HOST:/var/tmp/$PROJECT.sql /var/tmp/$PROJECT.sql

		echo "Updateing local database"

		DROP_CREATE="DROP DATABASE IF EXISTS $DATABASE; CREATE DATABASE $DATABASE /*!40100 DEFAULT CHARACTER SET utf8 */;"
		DROP_CREATE="$DROP_CREATE GRANT ALL PRIVILEGES ON $DATABASE.* TO '$DATABASE_USER'@'localhost' IDENTIFIED BY '$DATABASE_PASS'; FLUSH PRIVILEGES;"

		echo $DROP_CREATE | mysql --database=information_schema --host=$DATABASE_HOST --user=root $MYSQL_ROOT_PASS; 

		if [[ `dpkg -l | grep -w "ii  pv "` ]]; then
			pv /var/tmp/$PROJECT.sql | mysql --database=${DATABASE[i]} --host=$DATABASE_HOST --user=$DATABASE_USER --password=$DATABASE_PASS --silent
		else
			mysql --database=${DATABASE[i]} --host=$DATABASE_HOST --user=$DATABASE_USER --password=$DATABASE_PASS --silent < /var/tmp/$PROJECT.sql
		fi
	
	
		echo "complete!"
	done
}


case $ARGV in
install)
   install_drupal
    ;;
update)
   content_update
    ;;
deploy)
   deploy
    ;;
*)
usage
esac

exit $ERROR
