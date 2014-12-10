#!/bin/bash

DEV=0
TEST=1
PROD=2

DEV_MODULES="devel field_ui views_ui stage_file_proxy"
PROD_MODULES="memcahce varnish openx"


ARGV="$@"
ARG="$1"

if [ "x$ARGV" = "x" ] ; then
    ARGV="-h"
fi

if [[ $EUID -eq 0 ]]; then
   echo "This script should NOT be run as root" 1>&2
   exit 1
fi

PROJECT=${PROJECT:-"$(basename *.make .make)"}

if [ ! -e "$PROJECT.make" ]
then
  echo ".make file must exist!"
  exit 1;
fi

## READ PROPERTIES

if [[ -e "sheldon.conf" ]]; then
. sheldon.conf
elif [[ -e "properties" ]]; then
. properties
echo "properties file is deprecated and will be now be renamed to sheldon.conf, please commit the changes."
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
#DATABASE_HOST[\$DEV]=localhost
#DATABASE_USER[\$DEV]="$PROJECT"
#DATABASE_PASS[\$DEV]=secret
#DATABASE[\$DEV]="$PROJECT"

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
		-t|--target) ARG_TARGET=$2 ; shift 2 ;;
		-e|--env) ARG_ENV=$2; shift 2 ;;
		-n|--name) ARG_NAME=$2 ; shift 2 ;;
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


SITE_URL="dev.$PROJECT.se"

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
  if [[ ! $MYSQL_ROOT_PASS_HAS_RUN ]]; then
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

	for SITE in $PROJECT_LOCATION/sites/*
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
	echo "Bulding $PROJECT.make, this can take a while..."
	rm -rf tmp || true

	if [[ ~/.sheldoncache/$PROJECT.tar.gz -ot $PROJECT.make ]] || [[ -e composer.json && ~/.sheldoncache/$PROJECT.tar.gz -ot composer.json ]];then
	  rm ~/.sheldoncache/$PROJECT.tar.gz || true
	  if [ "$ARG_NOCACHE" == "TRUE" ]; then
		drush make --no-cache $PROJECT.make tmp > /dev/null || exit 1
	  else
	  	drush make $PROJECT.make tmp > /dev/null || exit 1
	  fi

	  if [[ -e composer.json ]]; then
	  	if type foo >/dev/null 2>&1; then
	  		cp composer.json tmp/composer.json
	  		composer install --working-dir=tmp
	  	else
	  		echo "This project requires composer!"
	  		echo "Install, and try again:"
	  		echo "curl -sS https://getcomposer.org/installer | php"
			echo "sudo mv composer.phar /usr/local/bin/composer"
			exit 1;
	  	fi
	  fi

	  mkdir -p ~/.sheldoncache
	  tar cfz  ~/.sheldoncache/$PROJECT.tar.gz tmp
	else
	  	echo "Make file not changed since last build, fetching from cache..."
		tar xfz ~/.sheldoncache/$PROJECT.tar.gz
	fi

	echo "Drush make complete."

	echo "Copy custom profiles, modules, themes, .htaccess, robots.txt etc..."

	## COPY CUSTOM PROFILE
	cp -r "$PROJECT_LOCATION/profiles" "tmp/" > /dev/null 2>&1 || true

	## COPY SITES
	cp -r "$PROJECT_LOCATION/sites" "tmp/" || true > /dev/null 2>&1

	## COPY .htaccess
	if [[ -e  "$PROJECT_LOCATION/htaccess.htaccess" ]]; then
		cp "$PROJECT_LOCATION/htaccess.htaccess" "tmp/.htaccess"
	fi

	## COPY robots.txt
	if [[ -e  "$PROJECT_LOCATION/robots.txt" ]]; then
		cp "$PROJECT_LOCATION/robots.txt" "tmp/"
	fi

	for SITE in $PROJECT_LOCATION/sites/*
	do
		SITE_NAME="$(basename $SITE)"

		if [ $SITE_NAME != "all" ]
		then
			echo "Copy and filter sites/$SITE_NAME/settings.php"
			mkdir -p "tmp/sites/$SITE_NAME/files"
			if ! grep -q "define('ENVIRONMENT'" tmp/sites/$SITE_NAME/settings.php; then
				echo "Append environment constant \"define('ENVIRONMENT', '$ARG_ENV');\" to /sites/$SITE_NAME/settings.php"
				sed -i.bak -e "s/<?php/<?php define(\'ENVIRONMENT\', \'$ARG_ENV\');/g" tmp/sites/$SITE_NAME/settings.php
			fi
			## FILTER SETTINGS.PHP
			REPLACE=(${DATABASE[$REMOTE]} ${DATABASE_USER[$REMOTE]} ${DATABASE_HOST[$REMOTE]} ${DATABASE_PASS[$REMOTE]} "$ARG_ENV"); i=0;
			for SEARCH in $(echo "@db.database@ @db.username@ @db.host@ @db.password@ @settings.ENVIRONMENT@" | tr " " "\n")
			do
				sed -i.bak -e s/$SEARCH/${REPLACE[$i]}/g tmp/sites/$SITE_NAME/*settings.php; ((i++));
			done

			rm -f tmp/sites/$SITE_NAME/*.bak
		fi
	done

}

function apache_install {

	echo "Creating apache config file: $APACHE_VHOSTS_DIR/$PROJECT.conf"

	VHOST="<VirtualHost *:80>
	ServerName $SITE_URL"

	for SITE in $PROJECT_LOCATION/sites/*
	do
		SITE_NAME=$(basename "$SITE")

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

		ScriptAlias /cgi-bin/ /usr/lib/cgi-bin/
		<Directory \"/usr/lib/cgi-bin\">
		        AllowOverride All
		        Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
		        Require all granted
		        #Order allow,deny
		        #Allow from all
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

	if grep -q -E "127.0.0.1(\s*)$SITE_URL" /etc/hosts; then
	  echo "domain already exists in host file, didn't add anything";
	else
	   echo "Adding domain(s) to /etc/hosts"
	   echo -e "127.0.0.1 $SITE_URL" | sudo tee -a /etc/hosts
	fi

	echo -e "Restarting apache...\n"
	sudo $APACHE_CMD restart > /dev/null 2>&1
}

function mysql_install {

	for SITE in $PROJECT_LOCATION/sites/*
	do

	  SITE_NAME=$(basename "$SITE")
	  if [[ $SITE_NAME != "all" ]]; then

		drushargs="-l $SITE_NAME -r $DEPLOY_DIR/$PROJECT"

		DB_NAME=$(drush $drushargs sql-connect | sed 's#.*database=\([^ ]*\).*#\1#g')
		DB_PASS=$(drush $drushargs sql-connect | sed 's#.*password=\([^ ]*\).*#\1#g')
		DB_USER=$(drush $drushargs sql-connect | sed 's#.*user=\([^ ]*\).*#\1#g')
		DB_HOST=$(drush $drushargs sql-connect | sed 's#.*host=\([^ ]*\).*#\1#g')

		if [[ $(echo "$DB_NAME" | tr -d ' ') != "" ]]; then
		QUERY="CREATE DATABASE IF NOT EXISTS $DB_NAME;"
			if [[ "$DB_USER" != "root" ]]; then
			QUERY="$QUERY GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASS';"
			fi
		echo "mysql > $QUERY"
		mysql -u root $MYSQL_ROOT_PASS -e "$QUERY" || exit 0
		fi
	  fi
	done


}

function install_drupal {

	ARG_ENV="DEV"

	echo "Start installing $PROJECT"

	set_deploydir;
	mysql_root_access;

	if [ "$ARG_MAMP" != "TRUE" ]; then
		apache_install;
	fi


	build_drupal;
	exclude_files;

	#RSYNC with delete,
	rsync --delete -alz $EXCLUDE tmp/ $DEPLOY_DIR/$PROJECT/
	rm -rf tmp

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

	mysql_install;

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

	build_drupal;
	exclude_files;

	#RSYNC with delete,
	rsync --delete --cvs-exclude -alz $EXCLUDE tmp/ ${USER[$REMOTE]}@${HOST[$REMOTE]}:${ROOT[$REMOTE]}/ || exit 1
	rm -rf tmp

	for SITE in $PROJECT_LOCATION/sites/*
	do
		SITE_NAME="$(basename $SITE)"

		if [ $SITE_NAME != "all" ]
		then
			DRUSH_CMD="drush -l $SITE_NAME -r ${ROOT[$REMOTE]}"

			COMMAND1="$DRUSH_CMD vset 'maintenance_mode' 1 --exact --yes && $DRUSH_CMD vset 'elysia_cron_disabled' 1 --exact --yes"
			COMMAND2="$DRUSH_CMD fra --yes"
			COMMAND3="$DRUSH_CMD updb --yes"
			COMMAND4="$DRUSH_CMD vset 'maintenance_mode' 0 --exact --yes && $DRUSH_CMD vset 'elysia_cron_disabled' 0 --exact --yes"
			COMMAND5="$DRUSH_CMD cc all"


			echo -e "\n\n####################\nRunning updates for $SITE_NAME \n"
			if echo $(ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$DRUSH_CMD status Database") | grep -q "Connected" ; then
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$COMMAND1"
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$COMMAND2"
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$COMMAND3"
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$COMMAND4"
				ssh ${USER[$REMOTE]}@${HOST[$REMOTE]} "$COMMAND5"

				echo "Sleep for 15 sec"
				sleep 15
			else
				echo "Problems with $SITE_NAME, no database connection."
			fi

		fi
	done

	rm -rf /tmp/$PROJECT

}

function reset_drupal {
	set_deploydir;

	if [[  ~/.sheldoncache/$PROJECT.tar.gz -ot $PROJECT.make ]];then
		echo "Make file updated, running install."
		install_drupal;
	fi

	for SITE in $PROJECT_LOCATION/sites/*
		do
			SITE_NAME="$(basename $SITE)"

			if [ $SITE_NAME != "all" ]; then

				if [[ $(drush -r $DEPLOY_DIR/$PROJECT -l $SITE_NAME status Database | tail -2 | head -1 | sed -e 's/.*\?\(Connected\)/\1/g') == "Connected" ]]; then

					drush -r $DEPLOY_DIR/$PROJECT -l $SITE_NAME fra -y
					drush -r $DEPLOY_DIR/$PROJECT -l $SITE_NAME updb -y
					drush -r $DEPLOY_DIR/$PROJECT -l $SITE_NAME cc all -y
				fi
			fi
		done

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

	for SITE in $PROJECT_LOCATION/sites/*
	do
		SITE_NAME="$(basename $SITE)"

		if [ "$SITE_NAME" != "all" ]; then
		   DATESTAMP=$(date +%s)
		   CONNECTION=$(ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} "drush sql-connect -r ${ROOT[$REMOTE]} -l $SITE_NAME" | sed 's#--database=##g' | sed 's#mysql ##g')

		   OPTIONS="--no-autocommit --single-transaction --opt -Q"

		   echo "Running mysqldump command on server ($SITE_NAME)..."
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
				  *search_index|*cache_*|*watchdog|*history|*sessions|*accesslog)
				    EMPTY_TABLES="$EMPTY_TABLES $T"
				    ;;
				  *)
				    DATA_TABLES="$DATA_TABLES $T"
				    ;;
				esac
		   	done

			QUERY="mysqldump $OPTIONS --add-drop-table $CONNECTION $DATA_TABLES > /var/tmp/$PROJECT-$SITE_NAME.sql-$DATESTAMP"
			QUERY="$QUERY && mysqldump --no-data $OPTIONS $CONNECTION $EMPTY_TABLES >> /var/tmp/$PROJECT-$SITE_NAME.sql-$DATESTAMP"
			QUERY="$QUERY && mv -f /var/tmp/$PROJECT-$SITE_NAME.sql-$DATESTAMP /var/tmp/$PROJECT-$SITE_NAME.sql"

			ssh -q ${USER[$REMOTE]}@${HOST[$REMOTE]} $QUERY 2> /dev/null || exit 1

			echo "Rsync sql-dump-file from server..."
			rsync -akzq ${USER[$REMOTE]}@${HOST[$REMOTE]}:/var/tmp/$PROJECT-$SITE_NAME.sql /var/tmp/$PROJECT-$SITE_NAME.sql 2> /dev/null || exit 1

			if [ "$ARG_TEST" == "TRUE" ]; then # Test content update

				TESTCONNECTION=$(ssh -q ${USER[$TEST]}@${HOST[$TEST]} "drush sql-connect -r ${ROOT[$TEST]} -l $SITE_NAME")

				echo "Pushing sql-dump-file to TEST server..."
				rsync -akzq /var/tmp/$PROJECT-$SITE_NAME.sql ${USER[$TEST]}@${HOST[$TEST]}:/var/tmp/$PROJECT-$SITE_NAME.sql 2> /dev/null || exit 1

				echo "Drop all tables in the TEST database"
				ALL_TABLES=$(ssh ${USER[$TEST]}@${HOST[$TEST]} "$TESTCONNECTION -BNe \"show tables\" | tr '\n' ',' | sed -e 's/,$//'" 2> /dev/null);
				DROP_COMMAND="SET FOREIGN_KEY_CHECKS = 0;DROP TABLE IF EXISTS $ALL_TABLES;SET FOREIGN_KEY_CHECKS = 1;"
				ssh ${USER[$TEST]}@${HOST[$TEST]} "$TESTCONNECTION -e \"$DROP_COMMAND\"" 2> /dev/null || { echo "failed to drop all tables."; exit 1;}

				echo "Imports the sql-dump into the TEST database"
				ssh ${USER[$TEST]}@${HOST[$TEST]} "$TESTCONNECTION --silent < /var/tmp/$PROJECT-$SITE_NAME.sql" 2> /dev/null || exit 1

				echo "Enable dev modules and disable prod modules"
				ssh ${USER[$TEST]}@${HOST[$TEST]} "drush -r ${ROOT[$TEST]} -l $SITE_NAME en --resolve-dependencies $DEV_MODULES -y" 2> /dev/null || exit 1
				#ssh ${USER[$TEST]}@${HOST[$TEST]} "drush -r ${ROOT[$TEST]} -l $SITE_NAME dis $PROD_MODULES -y"
				rm /var/tmp/$PROJECT-$SITE_NAME.sql

			else # local update from PROD/TEST

				DEVCONNECTION=$(drush sql-connect -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME)

				echo "Dropping all tables in local database"
				$DEVCONNECTION -BNe "show tables" | tr '\n' ',' | sed -e 's/,$//' | awk '{print "SET FOREIGN_KEY_CHECKS = 0;DROP TABLE IF EXISTS " $1 ";SET FOREIGN_KEY_CHECKS = 1;"}' | $DEVCONNECTION

				echo "Updating local database"

				if type pv &> /dev/null ; then
					pv /var/tmp/$PROJECT-$SITE_NAME.sql | $DEVCONNECTION --silent
				else
					echo "Tip! Get a nice progress bar: sudo apt-get install pv"
					$DEVCONNECTION --silent < /var/tmp/$PROJECT-$SITE_NAME.sql
				fi

				#echo "Try to disable any of following modules: $PROD_MODULES"
				#drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME dis $PROD_MODULES -y

				echo "Enabling following modules: $DEV_MODULES"
				drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME en --resolve-dependencies $DEV_MODULES -y

				echo "Change admin login to: admin/admin"
				drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME sql-query --db-prefix "UPDATE {users} SET name = 'admin' WHERE uid=1"
				drush -r "$DEPLOY_DIR/$PROJECT" -l $SITE_NAME user-password admin --password=admin

			fi
		fi
	done



	echo "Bazinga!"

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
reset)
   reset_drupal
    ;;
*)
	usage
	;;
esac

exit $ERROR
