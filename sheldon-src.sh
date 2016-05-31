#!/bin/bash

DEV=0
TEST=1
PROD=2

CORE=7

DEV_MODULES="maillog devel search_krumo field_ui views_ui stage_file_proxy"

ARGV="$@"
ARG="$1"

if [ "x$ARGV" = "x" ] ; then
    ARGV="-h"
fi

if [[ $EUID -eq 0 ]]; then
   echo "This script should NOT be run as root" 1>&2
   exit 1
fi

PROJECT="$(basename *.make .make)"
DATABASE_DEPENDENCIES=""

if [ ! -e "$PROJECT.make" ]
then
  echo ".make file must exist!"
  exit 1;
fi

if grep -q -i 'core \?= \?8.x' "$PROJECT.make"; then
  echo "Sheldon doesn't support drupal 8!"
  exit 1;
elif grep -q -i 'core \?= \?6.x' "$PROJECT.make"; then
	#Drupal 6
	CORE=6
fi

if [[ -e ~/.sheldon.cnf ]]; then
	. ~/.sheldon.cnf
fi

## READ PROPERTIES
if [[ -e "sheldon.conf" ]]; then
. sheldon.conf
elif [[ -e "properties" ]]; then
. properties
echo "properties file is deprecated and will now be renamed to sheldon.conf, please commit the changes."
mv properties sheldon.conf
else
  echo "sheldon.conf file must exist!"
  #echo "" > sheldon.conf
  read -ep "Do you want to create a sheldon.conf now? [Y/n]" CREATE
  if [ "$CREATE" == "Y" -o "$CREATE" == "y" ] ;then
  	echo -e "### sheldon.conf ###
#Local database settings defaluts to: mysql --user="$PROJECT" --host=localhost --password=secret --database="$PROJECT"
#DATABASE_HOST[\$DEV]=localhost
#DATABASE_USER[\$DEV]="$PROJECT"
#DATABASE_PASS[\$DEV]=secret
#DATABASE[\$DEV]="$PROJECT"

#required parameters, you have to outcomment and change this section.
#USER[\$TEST]=www-data
#HOST[\$TEST]=91.123.203.189
#ROOT[\$TEST]=/var/www/"$PROJECT"

#Test database settings defaults to the local database settings.
#DATABASE_HOST[\$TEST]=localhost
#DATABASE_USER[\$TEST]="$PROJECT"
#DATABASE_PASS[\$TEST]=secret
#DATABASE[\$TEST]="$PROJECT"

#required parameters, you have to outcomment and change this section.
#USER[\$PROD]=deploy
#HOST[\$PROD]=www."$PROJECT".se
#ROOT[\$PROD]=/mnt/persist/www/docroot

#Prod database settings defaults to the test database settings.
#DATABASE_HOST[\$PROD]=localhost
#DATABASE_USER[\$PROD]=$PROJECT
#DATABASE_PASS[\$PROD]=secret
#DATABASE[\$PROD]=$PROJECT

#Exclude som extra paths when deploying with rcync (seperated by space). For example google verification file.
#RSYNC_EXCLUDE=\"google* other-file.txt sites/default/test.xml\"
" | tee sheldon.conf
  fi
  exit 1
fi

## READ ARGUMENTS
TEMP=`getopt -o f:t:e:n: --longoptions env:,target:,from:,name:,test,mamp,no-cache -n "sheldon" -- "$@"`

if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

eval set -- "$TEMP"

while true ; do
	case "$1" in
		-f|--from) ARG_FROM=$2 ; shift 2 ;;
		-e|--env) ARG_ENV=$2; shift 2 ;;
		--test) ARG_TEST="TRUE" ; shift ;;
		--mamp) ARG_MAMP="TRUE" ; shift ;;
		--no-cache) ARG_NOCACHE="TRUE" ; shift ;;
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

DATABASES="$DATABASE_DEPENDENCIES default"

SITE_URL=${SITE_URL:-"dev.$PROJECT.se"}
LOCAL_SERVER_ALIAS=${LOCAL_SERVER_ALIAS:-""}

APACHE_CMD=apache2ctl
APACHE_VHOSTS_DIR=/etc/apache2/sites-enabled

GROUP=$(id -gn)

# Handle Mac specifics
if [ "$(uname)" == "Darwin" ]; then
  APACHE_CMD=apachectl
  APACHE_VHOSTS_DIR=/etc/apache2/other
fi

function usage {
    echo "
Usage: $0 install|update|deploy [--env=[TEST|PROD]] [--from=[TEST|PROD]]
COMMANDS
    install		Installs Drupal locally.

    update	Updates local content from test or prod environment
    --from=[TEST|PROD]	Where to get the content.
	--test				Update test envrionment (test-contet-update).

    deploy
	--env=[TEST|PROD]	Where to install remotely.
"
    exit 0
}

containsElement () {
	local array=($2)
  local e
  for e in ${array[@]}; do [[ "$e" == "$1" ]] && return 0;  done
  return 1
}

function set_deploydir {

  if [[ -z "$DEPLOY_DIR" ]]; then
		read -ep "Where is your deploy dir? (/var/www): " DEPLOY_DIR
	if  [ "$DEPLOY_DIR" == "" ]; then
		DEPLOY_DIR="/var/www"
	fi
	if  [ ! -d $DEPLOY_DIR ]; then
		echo "Directory $DEPLOY_DIR was not found. Exiting."
		exit 1
	fi
 fi
}

function mysql_root_access {
  if [[ ! $MYSQL_ROOT_PASS_HAS_RUN ]] && [ -z ${MYSQL_ROOT_PASS+x} ]; then
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

	if [ -n "$RSYNC_EXCLUDE" ]; then
		RSYNC_EXCLUDE=( $RSYNC_EXCLUDE )
		for EX in ${RSYNC_EXCLUDE[@]}; do
			EXCLUDE="$EXCLUDE --exclude=$EX"
		done
	fi

	for SITE in $PROJECT_LOCATION/sites/*/
	do
		SITE_NAME="$(basename $SITE)"

		if [ $SITE_NAME != "all" ]
		then
			EXCLUDE="$EXCLUDE --exclude=sites/$SITE_NAME/files"

		fi

	done
}


# Can be called from Bamboo or locally
function build_drupal {

	if [ "$ARG_ENV" == "DEV" ]; then
		REMOTE=$DEV;
	fi

	## DRUSH MAKE

	rm -rf tmp || true

	if [[ ~/.sheldoncache/$PROJECT.tar.gz -ot $PROJECT.make ]] || [[ -e composer.json && ~/.sheldoncache/$PROJECT.tar.gz -ot composer.json ]]; then

	  rm ~/.sheldoncache/$PROJECT.tar.gz || true
	  echo "
	  Bulding $PROJECT.make...
		"
	  drush make $PROJECT.make tmp > /dev/null || exit 1

	  if [[ -e composer.json ]]; then
	  	if type composer >/dev/null 2>&1; then
	  		cp composer.json tmp/composer.json
	  		composer install --ignore-platform-reqs --working-dir=tmp
	  	else
	  		echo "This project requires composer!"
	  		echo "Install, and try again:"
	  		echo "curl -sS https://getcomposer.org/installer | php"
				echo "sudo mv composer.phar /usr/local/bin/composer"
				exit 1;
	  	fi
	  fi
	  echo "Drush make complete."
	  mkdir -p ~/.sheldoncache
	  tar cfz  ~/.sheldoncache/$PROJECT.tar.gz tmp
	else
	  echo -e "\nMake file not changed since last build, fetching from cache.\n"
		tar xf ~/.sheldoncache/$PROJECT.tar.gz
	fi

	echo "Copy custom profiles, modules, themes, .htaccess, robots.txt etc."

	## COPY .htaccess
	if [[ -e  "$PROJECT_LOCATION/htaccess.htaccess" ]]; then
		cp "$PROJECT_LOCATION/htaccess.htaccess" "tmp/.htaccess"
	fi

	## COPY root_files/*
	if [[ -d  "$PROJECT_LOCATION/root_files" ]]; then
		cp -r $PROJECT_LOCATION/root_files/* tmp/
	fi

	## COPY CUSTOM PROFILES
	cp -r "$PROJECT_LOCATION/profiles" "tmp/" > /dev/null 2>&1 || true

	## COPY robots.txt
	if [[ -e  "$PROJECT_LOCATION/robots.txt" ]]; then
		cp "$PROJECT_LOCATION/robots.txt" "tmp/"
	fi

	## COPY SITES
	cp -r "$PROJECT_LOCATION/sites" "tmp/" || true > /dev/null 2>&1

	## COPY scripts directory
	if [[ -d  "$PROJECT_LOCATION/scripts" ]]; then
		cp -r $PROJECT_LOCATION/scripts tmp
	fi

	for SITE in $PROJECT_LOCATION/sites/*/
		do
			SITE_NAME="$(basename $SITE)"

			if [ $SITE_NAME != "all" ]
			then
				echo "Copy and filter sites/$SITE_NAME/settings.php"
				mkdir -p "tmp/sites/$SITE_NAME/files"
				if ! grep -q "define('ENVIRONMENT'" tmp/sites/$SITE_NAME/settings.php; then
					echo "set ENVIRONMENT = $ARG_ENV in /sites/$SITE_NAME/settings.php"
					sed -i.bak -e "s/<?php/<?php define(\'ENVIRONMENT\', \'$ARG_ENV\');/g" tmp/sites/$SITE_NAME/settings.php
				fi

				## FILTER SETTINGS.PHP
				REPLACE=(${DATABASE[$REMOTE]} ${DATABASE_USER[$REMOTE]} ${DATABASE_HOST[$REMOTE]} ${DATABASE_PASS[$REMOTE]} "$ARG_ENV"); i=0;
				for SEARCH in $(echo "@db.database@ @db.username@ @db.host@ @db.password@ @settings.ENVIRONMENT@" | tr " " "\n")
				do
					## escape / to get sed to work
					REPLACED_VALUE=${REPLACE[$i]//\//\\\/};
					sed -i.bak -e s/$SEARCH/$REPLACED_VALUE/g tmp/sites/$SITE_NAME/*settings.php; ((i++));
				done

				rm -f tmp/sites/$SITE_NAME/*.bak
			fi
		done

}

function apache_install {

	echo "Creating apache config file: $APACHE_VHOSTS_DIR/$PROJECT.conf"

	VHOST="<VirtualHost *:80>
	ServerName $SITE_URL
	ServerAlias admin.${PROJECT}.se ${LOCAL_SERVER_ALIAS}"

	for SITE in $PROJECT_LOCATION/sites/*/
	do
		SITE_NAME=$(basename "$SITE")

		if [[ $SITE_NAME == "default" || $SITE_NAME == "all" ]]
		then
	  	  continue
		else
		  SITE_URL="$SITE_URL dev.$SITE_NAME admin.$SITE_NAME"
		  VHOST="$VHOST
		  ServerAlias dev.$SITE_NAME admin.$SITE_NAME"
		fi
	done


	echo "$VHOST
	DocumentRoot $DEPLOY_DIR/$PROJECT/

		<Directory />
		        Options +FollowSymLinks
		        AllowOverride All
		</Directory>
		<Directory $DEPLOY_DIR/$PROJECT>
		        Options +FollowSymLinks -Indexes
		        AllowOverride All
			Require all granted
		        Order allow,deny
		        allow from all
		</Directory>

		ErrorLog /var/log/apache2/$PROJECT-error.log
		LogLevel info

                <IfModule mod_php5.c>
                  php_flag  display_errors        on
		  php_flag  log_errors        	  on
		  php_flag  mysql.trace_mode      on
                  php_value error_reporting       32767
                </IfModule>


	</VirtualHost>" | sudo tee $APACHE_VHOSTS_DIR/$PROJECT.conf > /dev/null

	for host_name in $(echo "$SITE_URL admin.${PROJECT}.se ${LOCAL_SERVER_ALIAS}" | tr " " "\n"); do
		if grep -q -E "127.0.0.1(\s*)$host_name" /etc/hosts; then
		  echo "$host_name already exists in host file.";
		else
		   echo "Adding domain to /etc/hosts"
		   echo -e "127.0.0.1 ${host_name}" | sudo tee -a /etc/hosts
		fi
	done

	echo -e "Restarting apache...\n"
	sudo $APACHE_CMD restart > /dev/null 2>&1
}

function mysql_install {

	for SITE in $PROJECT_LOCATION/sites/*/; do

	  SITE_NAME=$(basename "$SITE")
	  if [[ $SITE_NAME != "all" ]]; then

	  	if [[ "$UPDATE_SITES" != "" ]]; then
				 if ! containsElement "$SITE_NAME" "${UPDATE_SITES}"; then
				 		continue;
				 fi
			fi

			drushargs="-l $SITE_NAME -r $DEPLOY_DIR/$PROJECT"
			for database in $DATABASES; do
				DB_NAME=$(drush $drushargs sql-connect --database=$database | sed 's#.*database=\([^ ]*\).*#\1#g')
				DB_PASS=$(drush $drushargs sql-connect --database=$database | sed 's#.*password=\([^ ]*\).*#\1#g')
				DB_USER=$(drush $drushargs sql-connect --database=$database | sed 's#.*user=\([^ ]*\).*#\1#g')
				DB_HOST=$(drush $drushargs sql-connect --database=$database | sed 's#.*host=\([^ ]*\).*#\1#g')

				if [[ $(echo "$DB_NAME" | tr -d ' ') != "" ]]; then
					QUERY="CREATE DATABASE IF NOT EXISTS $DB_NAME;"
					if [[ "$DB_USER" != "root" ]]; then
						QUERY="$QUERY GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASS';"
					fi
					echo -e "\nSet up the database and database user\nmysql > $QUERY"
					mysql -u root $MYSQL_ROOT_PASS -e "$QUERY"  > /dev/null 2>&1 || exit 0
				fi
			done
	  fi
	done


}

function install_drupal {

	ARG_ENV="DEV"

	echo "
 _______  __   __  _______  ___      ______   _______  __    _
|       ||  | |  ||       ||   |    |      | |       ||  |  | |
|  _____||  |_|  ||    ___||   |    |  _    ||   _   ||   |_| |
| |_____ |       ||   |___ |   |    | | |   ||  | |  ||       |
|_____  ||       ||    ___||   |___ | |_|   ||  |_|  ||  _    |
 _____| ||   _   ||   |___ |       ||       ||       || | |   |
|_______||__| |__||_______||_______||______| |_______||_|  |__|

                  Installing $PROJECT...
                  Core = Drupal $CORE
"

	set_deploydir;
	mysql_root_access;

	if [ "$ARG_MAMP" != "TRUE" ]; then
		apache_install;
	fi

	read -ep "Do you want to update the database when the build is finished?
(P = from PROD, T = from TEST, n = No) [P/T/n] " UPDATE

	if [[ "$UPDATE" == "P" || "$UPDATE" == "T" ]] && [[ "$DATABASE_DEPENDENCIES" != "" ]]; then
		read -ep "Do you want to update all the depending databases ($DATABASE_DEPENDENCIES) as well? [Y/n] " UPDATE_ALL
	fi

	read -ep "Do you want to revert all features when the build is finished? [Y/n] " FRA
	read -ep "Do you want to run drush updb when the build is finished? [Y/n] " UPDB

	build_drupal;
	exclude_files;

	sudo mkdir -p $DEPLOY_DIR/$PROJECT/
	sudo chown -R $USER:$GROUP "$DEPLOY_DIR/$PROJECT"

	#RSYNC with delete,
	rsync --delete -al $EXCLUDE tmp/ $DEPLOY_DIR/$PROJECT/
	rm -rf tmp

	## MAKE SURE THESE FOLDERS EXISTS
	sudo mkdir -p "$DEPLOY_DIR/$PROJECT/sites/all/modules"
	sudo mkdir -p "$DEPLOY_DIR/$PROJECT/sites/all/themes"

	echo "Creating symlinks into workspace:"
	echo -e "\t$DEPLOY_DIR/$PROJECT/sites/all/modules/custom -> $PROJECT_LOCATION/sites/all/modules/custom"
	echo -e "\t$DEPLOY_DIR/$PROJECT/sites/all/themes/custom -> $PROJECT_LOCATION/sites/all/themes/custom"

	## SYMLINK CUSTOM MODULES AND THEMES IN TO WORKSPACE
	cd "$DEPLOY_DIR/$PROJECT/sites/all/modules";sudo rm -rf custom || true; sudo ln -s "$PROJECT_LOCATION/sites/all/modules/custom" custom
	cd "$DEPLOY_DIR/$PROJECT/sites/all/themes";sudo rm -rf custom || true; sudo ln -s "$PROJECT_LOCATION/sites/all/themes/custom" custom

	sudo chown -R $USER:$GROUP "$DEPLOY_DIR/$PROJECT"

	mysql_install;

	echo -e "BUILD complete\n"

	if [ "$UPDATE" == "T" ]; then
		ARG_FROM="TEST"
		content_update;
	elif [ "$UPDATE" == "P" ];then
		ARG_FROM="PROD"
		content_update;
	fi

	for SITE in $PROJECT_LOCATION/sites/*/; do

		SITE_NAME="$(basename $SITE)"

		if [ "$SITE_NAME" != "all" ]; then
			if [[ "$FRA" == "Y" ||  "$FRA" == "y" ]]; then
				drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME -y fra
			fi

			if [[ "$UPDB" == "Y" ||  "$UPDB" == "y" ]]; then
				drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME -y updb
			fi

		fi
	done

	echo "You can now visit http://dev.$PROJECT.se"
	echo "Bazinga!"

}

# Only called from Bamboo
function deploy {

	if [ "$ARG_ENV" == "PROD" ]; then
	  REMOTE=$PROD
	else
	  ARG_ENV="TEST"
	  REMOTE=$TEST
	fi

	if [[ -z "${HOST[$REMOTE]}" || -z "${USER[$REMOTE]}" || -z "${ROOT[$REMOTE]}" ]]; then
		echo "Missing remote settings for the environment you try to connect to, check your sheldon.conf."
		exit 1;
	fi

	echo -e "\n\n####################\n"
	echo "This deploy will update ${USER[$REMOTE]}@${HOST[$REMOTE]}:${ROOT[$REMOTE]}";
	echo -e "\n####################\n\n"

	build_drupal;
	exclude_files;

	#RSYNC with delete,
	rsync --delete -alz $EXCLUDE tmp/ ${USER[$REMOTE]}@${HOST[$REMOTE]}:${ROOT[$REMOTE]}/ || exit 1
	rm -rf tmp

  ## Install Drush plugin drush_language (https://www.drupal.org/project/drush_language)
  if echo $(ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "drush") | grep -q -v "language-import"; then
    ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "drush dl drush_language-7.x-1.4"
    ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "drush cache-clear drush"
  fi
  ## Look for language files for all modules and themes
  LANG_CMDS=()
  for f in $(find sites/all/modules/custom/ sites/all/themes/custom/ -name '*.po')
  do
    file=$(basename $f)
    dir=$(basename $(dirname $f))
    lang=$(echo $file | sed -e "s/\.po$//g" | sed -e "s/^.*\.//g")
    LANG_CMDS=("${LANG_CMDS[@]}" "language-import $lang $f --replace")
  done

  for SITE in $PROJECT_LOCATION/sites/*/
	do
		SITE_NAME="$(basename $SITE)"

		if [[ "$SITE_NAME" != "all" ]]; then

			DRUSH_CMD="drush -l $SITE_NAME -r ${ROOT[$REMOTE]}"


			echo -e "\n\n####################\nRunning updates for $SITE_NAME \n"
			if echo $(ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$DRUSH_CMD status bootstrap Database") | grep -q -E "Connected|Successful" ; then

				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$DRUSH_CMD vset 'maintenance_mode' 1 --exact --yes && $DRUSH_CMD vset 'elysia_cron_disabled' 1 --exact --yes"
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$DRUSH_CMD fra --yes"
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$DRUSH_CMD updb --yes"
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$DRUSH_CMD vset 'maintenance_mode' 0 --exact --yes && $DRUSH_CMD vset 'elysia_cron_disabled' 0 --exact --yes"
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$DRUSH_CMD cc all"

        echo -e "\n\n####################\nImporting language files for $SITE_NAME \n"
        for LANG_CMD in "${LANG_CMDS[@]}"
        do
            ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$DRUSH_CMD $LANG_CMD"
        done

 				#echo "Sleep for 15 sec"
				#sleep 15
			else
				echo "Problems with $SITE_NAME, no database connection."
			fi
		fi
	done

	if [[ -e  "scripts/varnish.vcl" ]]; then

    VCL_REMOTE=/mnt/persist/www/varnish.vcl
    VCL_NEW="VCL_"$(date "+%Y%m%d_%H%M%S")

    echo "Reloading Varnish conf file..."
		ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "varnishadm -S /etc/varnish/secret -T localhost:6082 vcl.load $VCL_NEW $VCL_REMOTE"
		ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "varnishadm -S /etc/varnish/secret -T localhost:6082 vcl.use $VCL_NEW"

    echo "Clearing Varnish cache (without restart!)..."
		ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "varnishadm -S /etc/varnish/secret -T localhost:6082 ban.url ."

	fi

	if [[ -d  "scripts" ]]; then

    echo "Making shell scripts executable..."
		ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "chmod a+x ${ROOT[$REMOTE]}/scripts/*.sh"

	fi

	rm -rf /tmp/$PROJECT

}

function content_update {

	if [[ "$ARG_FROM" == "PROD" || "$ARG_TEST" == "TRUE" ]]; then
	  REMOTE=$PROD
	else
	  REMOTE=$TEST
	fi

	if [[ -z "${HOST[$REMOTE]}" || -z "${USER[$REMOTE]}" || -z "${ROOT[$REMOTE]}" ]]; then
		echo "Missing remote settings for the environment you try to connect to, check your sheldon.conf."
		exit 1;
 	fi

	if [[ "$ARG_TEST" == "TRUE" ]] && [[ -z "${HOST[$TEST]}" || -z "${USER[$REMOTE]}" || -z "${ROOT[$REMOTE]}" ]]; then
		echo "Missing remote settings for the environment you try to connect to, check your sheldon.conf."
		exit 1;
	fi

	if [[ "$ARG_TEST" != "TRUE" ]]; then
		set_deploydir;
	fi

	if [[ "$ARG_TEST" == "TRUE" || "$UPDATE_ALL" != "Y" ]]; then
		DATABASES="default";
	fi
	#mysql_root_access;

	if [[ "$(which ssh-copy-id)" && "$(which ssh-keygen)" && "$ARG_TEST" != "TRUE" ]];then

		if [ ! $(ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER[$REMOTE]}@${HOST[$REMOTE]} 'echo TRUE 2>&1') ]; then
		read -ep "You do not seem to have ssh keys to ${HOST[$REMOTE]}, do you want to add it? [Y/n]" ADD_KEYS
			if [[ $ADD_KEYS == "Y" || $ADD_KEYS == "y" ]] ;then

				if [[ ! -a ~/.ssh/id_dsa.pub ]]; then
				 	ssh-keygen -t dsa
				fi
				ssh-copy-id -i ~/.ssh/id_dsa.pub ${USER[$REMOTE]}@${HOST[$REMOTE]}
			fi
		fi
	fi

	# Check amount of free disk space!
	# Require 2gb
	diskspace=$(ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} "df -k /var/tmp | tail -1 | awk '{ print \$4 }' ")

	if [[ "$diskspace" < "$((1024*1024))" ]]; then
		echo "The disk on the server is too full, $(( $diskspace / 1024 )) MB Avail. Clean up!"
		exit 1;
	else
		echo "It's $(( $diskspace / 1024 )) MB free disk space on the server..."
	fi

	for SITE in $PROJECT_LOCATION/sites/*/
	do
		SITE_NAME="$(basename $SITE)"

		if [ "$SITE_NAME" != "all" ]; then

			if [[ "$UPDATE_SITES" != "" ]]; then
				 if ! containsElement "$SITE_NAME" "${UPDATE_SITES}"; then
				 		continue;
				 fi
			fi

			for database in $DATABASES; do

		   	CONNECTION=$(ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} "drush sql-connect --database=$database -r ${ROOT[$REMOTE]} -l $SITE_NAME" | sed 's#--database=##g' | sed 's#mysql ##g')

		   	OPTIONS="--no-autocommit --single-transaction --opt -Q"
		   	DUMPNAME="$PROJECT-$SITE_NAME.sql.gz"
		   	DUMPFILE="/var/tmp/$DUMPNAME"

		   	if [[ "$ARG_TEST" != "TRUE" ]]; then

			   	mtime="$(ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} stat -c %Y $DUMPFILE)";

			   	if [[ "$mtime" != "" && "$mtime" > "$((`date +"%s"` - 3600 ))" ]]; then
			   		echo "WARNING!"
				   	echo "A file named $DUMPFILE already existst on the server and is less than 1h old."
				   	echo ""
				   	read -ep "Continue anyway? [Y/n] " FORCE_DUMP
				   	if [[ "$FORCE_DUMP" != 'Y' && "$FORCE_DUMP" != 'y' ]]; then
				   		echo "Abort";
				   	 	exit 1;
				   	fi
					fi
				fi
		   	echo "Running mysqldump command on server (site: $SITE_NAME db: $database)"

		   	TABLES=$(ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} "mysql $CONNECTION -Bse \"SHOW TABLES\"" || echo "ERROR");

		   	if echo $TABLES | grep -q "ERROR" ; then
					echo "Couldn't connect to: mysql $CONNECTION"
					continue;
		   	fi
				EMPTY_TABLES="";
				DATA_TABLES="";

		   	for T in $TABLES
				do
					case "$T" in
					  #ONLY MIGRATE TABLE STRUCTURE FROM THESE TABLES
					  *search_index|*cache_*|*cache|*watchdog|*sessions|*accesslog|*ctools_object_cache)
					    EMPTY_TABLES="$EMPTY_TABLES $T"
					    ;;
					  *)
					    DATA_TABLES="$DATA_TABLES $T"
					    ;;
					esac
		   	done

				QUERY="mysqldump $OPTIONS --add-drop-table $CONNECTION $DATA_TABLES | gzip > $DUMPFILE"
				QUERY="$QUERY && mysqldump --no-data $OPTIONS $CONNECTION $EMPTY_TABLES | gzip >> $DUMPFILE"

				ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} $QUERY || exit 1

				echo "Rsync sql-dump-file from server."
				rsync -akq ${USER[$REMOTE]}@${HOST[$REMOTE]}:$DUMPFILE /var/tmp/$DUMPNAME || exit 1

				#Clean up by removing the sql-dump.
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "rm $DUMPFILE"

				if [ "$ARG_TEST" == "TRUE" ]; then # Test content update

					TESTCONNECTION=$(ssh -q ${USER[$TEST]}@${HOST[$TEST]} "drush sql-connect --database=$database -r ${ROOT[$TEST]} -l $SITE_NAME")

					echo "Pushing sql-dump-file to TEST server."
					rsync -akq /var/tmp/$DUMPNAME ${USER[$TEST]}@${HOST[$TEST]}:/var/tmp/$DUMPNAME || exit 1

					echo "Drop all tables in the TEST database."
					ALL_TABLES=$(ssh ${USER[$TEST]}@${HOST[$TEST]} "$TESTCONNECTION -BNe \"show tables\" | tr '\n' ',' | sed -e 's/,$//'" 2> /dev/null);
					if [[ "$ALL_TABLES" != "" ]]; then
						DROP_COMMAND="SET FOREIGN_KEY_CHECKS = 0;DROP TABLE IF EXISTS $ALL_TABLES;SET FOREIGN_KEY_CHECKS = 1;"
						ssh ${USER[$TEST]}@${HOST[$TEST]} "$TESTCONNECTION -e \"$DROP_COMMAND\"" || { echo "failed to drop all tables."; exit 1;}
					fi
					echo "Imports the sql-dump into the TEST database."
					ssh ${USER[$TEST]}@${HOST[$TEST]} "gunzip -c /var/tmp/$DUMPNAME | $TESTCONNECTION --silent" || exit 1

					#Remove local file
					rm /var/tmp/$DUMPNAME || false
					#Remove from the test server
					ssh ${USER[$TEST]}@${HOST[$TEST]} "rm /var/tmp/$DUMPNAME"


				else # local update from PROD/TEST

					DEVCONNECTION=$(drush sql-connect --database=$database -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME)

					echo "Dropping all tables in local database."
					$DEVCONNECTION -BNe "show tables" | tr '\n' ',' | sed -e 's/,$//' | awk '{print "SET FOREIGN_KEY_CHECKS = 0;DROP TABLE IF EXISTS " $1 ";SET FOREIGN_KEY_CHECKS = 1;"}' | $DEVCONNECTION > /dev/null 2>&1

					echo "Updating local database."
					gunzip -c /var/tmp/$DUMPNAME | $DEVCONNECTION --silent > /dev/null 2>&1

				fi
			done
		fi
	done

	for SITE in $PROJECT_LOCATION/sites/*/; do
		SITE_NAME="$(basename $SITE)"

		if [ "$SITE_NAME" != "all" ]; then

			if [[ "$UPDATE_SITES" != "" ]]; then
				 if ! containsElement "$SITE_NAME" "${UPDATE_SITES}"; then
				 		continue;
				 fi
			fi

			if [ "$ARG_TEST" == "TRUE" ]; then
				echo "Enable dev modules"
				ssh ${USER[$TEST]}@${HOST[$TEST]} "drush -r ${ROOT[$TEST]} -l $SITE_NAME en --resolve-dependencies $DEV_MODULES -y" 2> /dev/null || exit 1

			else
				echo "Enabling following modules: $DEV_MODULES"
				for module in $DEV_MODULES; do
					drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME en --resolve-dependencies $module -y
				done

				drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME role-add-perm 1 "access devel information" > /dev/null 2>&1
				drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME role-add-perm 2 "access devel information" > /dev/null 2>&1
		  fi
		fi
	done

}


case $ARG in
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
	;;
esac

exit $ERROR
