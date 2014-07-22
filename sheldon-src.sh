#!/bin/bash

DEV=0
TEST=1
PROD=2

ARGV="$@"

if [ "x$ARGV" = "x" ] ; then
    ARGV="-h"
fi

if [[ $EUID -eq 0 ]]; then
   echo "This script should NOT be run as root" 1>&2
   exit 1
fi

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


## READ ARGUMENTS
TEMP=`getopt -o f:t:e:n: --longoptions env:,target:,from:,name:,test -n "sheldon" -- "$@"`

if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

eval set -- "$TEMP"

while true ; do
	case "$1" in
		-f|--from) ARG_FROM=$2 ; shift 2 ;;
		-t|--target) ARG_TARGET=$2 ; shift 2 ;;
		-e|--env) ARG_ENV=$2; shift 2 ;;
		-n|--name) ARG_NAME=$2 ; shift 2 ;;
		--test) ARG_TEST="TRUE" ; shift 2 ;;
		--) shift ; break ;;
		*) echo "Internal error!" ; exit 1 ;;
	esac
done

PROJECT_LOCATION="$(pwd)"

DATABASE[$DEV]=${DATABASE[$DEV]:-"$PROJECT"}
DATABASE_USER[$DEV]=${DATABASE_USER[$DEV]:-${DATABASE[$DEV]}}
DATABASE_PASS[$DEV]=${DATABASE_PASS[$DEV]:-"secret"}
DATABASE_HOST[$DEV]=${DATABASE_HOST[$DEV]:-"localhost"}

DATABASE[$TEST]=${DATABASE[$TEST]:-${DATABASE[$DEV]}}
DATABASE_USER[$TEST]=${DATABASE_USER[$TEST]:-${DATABASE_USER[$DEV]}}
DATABASE_PASS[$TEST]=${DATABASE_PASS[$TEST]:-${DATABASE_PASS[$DEV]}}
DATABASE_HOST[$TEST]=${DATABASE_HOST[$TEST]:-${DATABASE_HOST[$DEV]}}

DATABASE[$PROD]=${DATABASE[$PROD]:-${DATABASE[$TEST]}}
DATABASE_USER[$PROD]=${DATABASE_USER[$PROD]:-${DATABASE_USER[$TEST]}}
DATABASE_PASS[$PROD]=${DATABASE_PASS[$PROD]:-${DATABASE_PASS[$TEST]}}
DATABASE_HOST[$PROD]=${DATABASE_HOST[$PROD]:-${DATABASE_HOST[$TEST]}}


SITE_URL="dev.$PROJECT.se"

APACHE_CMD=apache2ctl
APACHE_VHOSTS_DIR=/etc/apache2/sites-enabled

GROUP=$(id -gn)

if [ "$(uname)" == "Darwin" ]; then
  APACHE_CMD=apachectl
  APACHE_VHOSTS_DIR=/etc/apache2/other
fi

function usage {
    echo "
Usage: $0 install|create|content-update [--target=path] [--env=[TEST|PROD]] [--name=sitename] [--from=[TEST|PROD]]
COMMANDS
    install		Installs Drupal locally or remotely.
    	--target=path		Where to install locally. Defaults to current directory.

    create		Creates a fully functional Drupal project. Includes setting up database and Apache config.
    	--name=projectname	The name of the project.

    content-update	Updates local content from test or prod environment
    	--from=[TEST|PROD]	Where to get the content.
	--test			Update test envrionment, defaults to local.
	
    deploy
	--env=[TEST|PROD]	Where to install remotely. 
"
    exit 0
}

function mysql_root_access {
  if [[ ! $MYSQL_ROOT_PASS_HAS_RUN ]]
 
 then
    read -sp "Enter your MySQL password (ENTER for none): " MYSQL_ROOT_PASS
    echo;

    if [ -n "$MYSQL_ROOT_PASS" ]; then
	MYSQL_ROOT_PASS="--password=$MYSQL_ROOT_PASS"
    else
	MYSQL_ROOT_PASS=""
    fi

    while ! mysql -u root $MYSQL_ROOT_PASS  -e ";" ; do
        read -sp "Can't connect, please retry: " MYSQL_ROOT_PASS
	if [ -n "$MYSQL_ROOT_PASS" ]; then
		MYSQL_ROOT_PASS="--password=$MYSQL_ROOT_PASS"
	else
		MYSQL_ROOT_PASS=""
	fi
	echo;
    done
 	
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
	drush make $PROJECT.make /tmp/$PROJECT || exit "Drush make failed"

	echo "Drush make complete."

	echo "Copy custom profiles, modules, themes etc..."

	## COPY CUSTOM PROFILE
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
			#REPLACE=(${DATABASE[$DEV]} ${DATABASE_USER[$DEV]} ${DATABASE_HOST[$DEV]} ${DATABASE_PASS[$DEV]} "DEV"); i=0;
			#for SEARCH in $(echo "@db.database@ @db.username@ @db.host@ @db.password@ @settings.ENVIRONMENT@" | tr " " "\n")
			#do
			#	sed -i '.bak' s/$SEARCH/${REPLACE[$i]}/g /tmp/$PROJECT/sites/$SITE_NAME/settings.php; ((i++));
			#done
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
	  echo "$SITE_URL already exists in host file, didn't add anything";
	else
	   echo "Adding $SITE_URL to /etc/hosts"
	   echo -e "127.0.0.1 $SITE_URL" | sudo tee -a /etc/hosts
	fi

	echo -e "Restarting apache...\n"
	sudo $APACHE_CMD restart > /dev/null 2>&1
}

function mysql_install {
	mysql -u root $MYSQL_ROOT_PASS -e "CREATE DATABASE IF NOT EXISTS ${DATABASE[$DEV]};GRANT ALL PRIVILEGES ON ${DATABASE[$DEV]}.* TO '${DATABASE_USER[$DEV]}'@'${DATABASE_HOST[$DEV]}' IDENTIFIED BY '${DATABASE_PASS[$DEV]}';" || exit 0
}

function install_drupal {

	echo "Start installing $PROJECT"

	read -ep "Where is your deploy dir? (/var/www): " DEPLOY_DIR
	if  [ "$DEPLOY_DIR" == "" ]; then
		DEPLOY_DIR="/var/www"
	fi
	if  [ ! -d $DEPLOY_DIR ]; then
		echo "Directory $DEPLOY_DIR was not found. Exiting."
		exit 1
	fi

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
	
	sudo chown -R $USER:$GROUP "$DEPLOY_DIR/$PROJECT"

	echo "BUILD successfull"
	

	read -ep "Do you want to update the database? 
(P = from PROD, T = from TEST, n = No) [P/T/n] " UPDATE

	if [ "$UPDATE" == "T" ]; then
		ARG_FROM="TEST"
		content_update;
	elif [ "$UPDATE" == "P" ];then	
		ARG_FROM="PROD"	
		content_update;
	fi
	
	echo "You can now visit http://dev.$PROJECT.se"
	echo "Bazinga!"

}


function deploy { 

	build_drupal;
	exclude_files;

	if [ "$ARG_ENV" == "PROD" ]; then
	  REMOTE=$PROD
	else 
	  REMOTE=$TEST
	fi

	#RSYNC with delete,
	rsync "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" --delete --cvs-exclude -akz $EXCLUDE /tmp/$PROJECT ${USER[$REMOTE]}@${HOST[$REMOTE]}:"$(dirname ${ROOT[$REMOTE]})/"

	for SITE in $PROJECT_LOCATION/sites/*
	do
		SITE_NAME="$(basename $SITE)"

		if [ $SITE_NAME != "all " ]
		then
			DRUSH_CMD="drush -l $SITE_NAME -r ${ROOT[$REMOTE]}"

			COMMAND="$DRUSH_CMD vset 'maintenance_mode' 1 --exact --yes"
			COMMAND="$COMMAND && $DRUSH_CMD vset 'elysia_cron_disabled' 1 --exact --yes"
			COMMAND="$COMMAND && $DRUSH_CMD fra --yes"
			COMMAND="$COMMAND && $DRUSH_CMD updb --yes"
			COMMAND="$COMMAND && $DRUSH_CMD vset 'maintenance_mode' 0 --exact --yes"
			COMMAND="$COMMAND && $DRUSH_CMD vset 'elysia_cron_disabled' 0 --exact --yes"
			COMMAND="$COMMAND && $DRUSH_CMD cc all"

			ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER[$REMOTE]}@${HOST[$REMOTE]} "$COMMAND"
			
			echo "Sleep for 15 sec" 			
			sleep 15
		fi
	done
	
	rm -rf /tmp/$PROJECT
	
}


function content_update { 

	if [ "$ARG_FROM" == "PROD" -o "$ARG_TEST" == "TRUE" ]; then
	  REMOTE=$PROD
	else 
	  REMOTE=$TEST
	fi
	
	mysql_root_access
	
	if [ "$(which ssh-copy-id)" -a "$(which ssh-keygen)" -a "$ARG_TEST" != "TRUE" ];then

		if [ ! $(ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER[$TEST]}@${HOST[$REMOTE]} 'echo TRUE 2>&1') ]; then
		echo -ep "Du verkar inta ha ssh-nycklar uppsatta till ${HOST[$REMOTE]}, vill du lägga till det? [Y/n]" ADD_KEYS
			if [ $ADD_KEYS == "Y" -o $ADD_KEYS == "y" ] ;then

				if [ ! -a ~/.ssh/id_dsa.pub ]; then
				 	ssh-keygen -t dsa
				fi
				ssh-copy-id -i ~/.ssh/id_dsa.pub ${USER[$REMOTE]}@${HOST[$REMOTE]}
			fi
		fi
	fi

	DATESTAMP=$(date +%s)
	CONNECTION="--user=${DATABASE_USER[$REMOTE]} --host=${DATABASE_HOST[$REMOTE]} --password=${DATABASE_PASS[$REMOTE]}"
	OPTIONS="--no-autocommit --single-transaction --opt -Q"
	

	echo "Running mysqldump command on server..."

	TABLES=$(ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} "mysql $CONNECTION -D ${DATABASE[$REMOTE]} -Bse \"SHOW TABLES\"")


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


	QUERY="mysqldump $OPTIONS --add-drop-table $CONNECTION ${DATABASE[$REMOTE]} $DATA_TABLES > /var/tmp/$PROJECT.sql-$DATESTAMP"
	QUERY="$QUERY && mysqldump --no-data $OPTIONS $CONNECTION ${DATABASE[$REMOTE]} $EMPTY_TABLES >> /var/tmp/$PROJECT.sql-$DATESTAMP"
	QUERY="$QUERY && mv -f /var/tmp/$PROJECT.sql-$DATESTAMP /var/tmp/$PROJECT.sql"

	ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} $QUERY;

	DROP_CREATE="DROP DATABASE IF EXISTS ${DATABASE[$DEV]}; CREATE DATABASE ${DATABASE[$DEV]} /*!40100 DEFAULT CHARACTER SET utf8 */;"
	DROP_CREATE="$DROP_CREATE GRANT ALL PRIVILEGES ON ${DATABASE[$DEV]}.* TO '${DATABASE_USER[$DEV]}'@'localhost' IDENTIFIED BY '${DATABASE_PASS[$DEV]}'; FLUSH PRIVILEGES;"

	if [ "$ARG_TEST" == "TRUE" ]; then
		ssh ${USER[$TEST]}@${HOST[$TEST]} "rsync -akz --progress ${USER[$REMOTE]}@${HOST[$REMOTE]}:/var/tmp/$PROJECT.sql /var/tmp/$PROJECT.sql"
		ssh ${USER[$TEST]}@${HOST[$TEST]} "echo $DROP_CREATE | mysql --database=information_schema --host=${DATABASE_HOST[$TEST]} --user=${DATABASE_USER[$TEST]} --password=${DATABASE_PASS[$TEST]};"
		ssh ${USER[$TEST]}@${HOST[$TEST]} "mysql --database=${DATABASE[$TEST]} --host=${DATABASE_HOST[$TEST]} --user=${DATABASE_USER[$TEST]} --password=${DATABASE_PASS[$TEST]} --silent < /var/tmp/$PROJECT.sql"
	else		
		echo "Rsync sql-dump-file from server..."
		rsync -akz --progress ${USER[$REMOTE]}@${HOST[$REMOTE]}:/var/tmp/$PROJECT.sql /var/tmp/$PROJECT.sql
		
		echo $DROP_CREATE | mysql --database=information_schema --host=${DATABASE_HOST[$DEV]} --user=root $MYSQL_ROOT_PASS;
		
		echo "Updateing local database"
		
		if type pv &> /dev/null ; then
			pv /var/tmp/$PROJECT.sql | mysql --database=${DATABASE[$DEV]} --host=${DATABASE_HOST[$DEV]} --user=${DATABASE_USER[$DEV]} --password=${DATABASE_PASS[$DEV]} --silent
		else
			echo "Tip! Get a nice progress bar: sudo apt-get install pv"
			mysql --database=${DATABASE[$DEV]} --host=${DATABASE_HOST[$DEV]} --user=${DATABASE_USER[$DEV]} --password=${DATABASE_PASS[$DEV]} --silent < /var/tmp/$PROJECT.sql
		fi
	fi




	echo "complete!"

}


case $ARGV in
install)
   install_drupal
    ;;
update|content-update)
   content_update
    ;;
deploy)
   deploy
    ;;
*)
usage
esac

exit $ERROR
