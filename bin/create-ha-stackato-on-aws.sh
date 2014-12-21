#!/bin/bash

export DOMAIN_NAME=
export STACK_NAME=
export REGION=eu-central-1
export STACK_DIR=stacks/
export ORGANIZATION=
export LICENSE=
export EMAIL=

function parseCommandLine() {
	USAGE="Usage: $(basename $0) -d domain-name -o organization -l license -u email [-r region] "

	while getopts "r:d:o:u:l:" OPT; do
		case $OPT in
			u)
				EMAIL=$OPTARG
				;;
			o)
				ORGANIZATION=$OPTARG
				;;
			l)
				LICENSE=$OPTARG
				;;
			r)
				REGION=$OPTARG
				;;
			d)
				DOMAIN_NAME=$OPTARG
				STACK_NAME=$(echo $DOMAIN_NAME | sed -e 's/[^a-zA-Z0-9]//g')
				STACK_DIR=stacks/$STACK_NAME
				;;
			\*)
				echo $USAGE >&2
				exit 1
				;;
		esac
	done

	if [  -z "$DOMAIN_NAME" -o -z "$EMAIL" -o -z "$LICENSE" -o -z "$EMAIL" ] ; then
		echo $USAGE >&2
		exit 1
	fi
}

function createKeyPair() {
        SSH_PRIVATE_KEY=$(pwd)/$STACK_DIR/$STACK_NAME.pem
	if [ -z "$(aws --region $REGION ec2 describe-key-pairs  --key-names $STACK_NAME)" ]  ; then
		mkdir -p $STACK_DIR
		aws --region $REGION ec2 create-key-pair --key-name $STACK_NAME | \
			jq -r  '.KeyMaterial' | \
			sed 's/\\n/\r/g' > $STACK_DIR/$STACK_NAME.pem
		 chmod 0700 $STACK_DIR/$STACK_NAME.pem
	else
		if [ ! -f $STACK_DIR/$STACK_NAME.pem ] ; then
			echo ERROR: key pair $STACK_NAME already exist, but I do not have it in $STACK_DIR.
			exit 1
		fi
	fi
}

function getOrGenerateCertificate() {
	SSL_KEY_NAME=$(aws iam list-server-certificates | \
			jq -r "  .ServerCertificateMetadataList[] | select(.ServerCertificateName == \"$DOMAIN_NAME\") | .Arn ")

	if [ -z "$SSL_KEY_NAME" ] ; then
		mkdir -p $STACK_DIR
		SSL_KEY_NAME=$(
		umask 077
		cd $STACK_DIR
		openssl genrsa 1024 > $DOMAIN_NAME.key 2>/dev/null
		openssl req -nodes -newkey rsa:2048 -keyout $DOMAIN_NAME.key -subj /CN=$DOMAIN_NAME > $DOMAIN_NAME.csr 2>/dev/null
		openssl x509 -req -days 365 -in $DOMAIN_NAME.csr -signkey $DOMAIN_NAME.key > $DOMAIN_NAME.crt 2>/dev/null
		aws iam upload-server-certificate --server-certificate-name $DOMAIN_NAME \
						--certificate-body file://./$DOMAIN_NAME.crt  \
						--private-key file://./$DOMAIN_NAME.key | \
			jq -r '.ServerCertificateMetadata | .Arn'
		)
	fi
}

function getStackStatus() {
	aws --region $REGION cloudformation describe-stacks --stack-name $STACK_NAME 2>/dev/null | \
		jq -r '.Stacks[] | .StackStatus' 
}

function getNumberOfInstancesWithoutPrivateIp() {
	getHostTable | awk 'BEGIN { count=0; } { if ($3 == "null") count++; } END { print count; }'
}

function createStack() {
	export SSL_KEY_NAME STACK_NAME REGION
	PARAMETERS=$(cat <<!
[ { "ParameterKey": "SSLCertificateId", "ParameterValue": "$SSL_KEY_NAME", "UsePreviousValue": false },
  { "ParameterKey": "KeyName", "ParameterValue": "$STACK_NAME", "UsePreviousValue": false },
  { "ParameterKey": "Region", "ParameterValue": "$REGION", "UsePreviousValue": false }
]
!)
	PARAMETERS="ParameterKey=SSLCertificateId,ParameterValue=$SSL_KEY_NAME,UsePreviousValue=false \
                    ParameterKey=KeyName,ParameterValue=$STACK_NAME,UsePreviousValue=false \
		    ParameterKey=Region,ParameterValue=$REGION,UsePreviousValue=false"

	STATUS=$(getStackStatus)
	if [ -z "$STATUS" ] ; then
		aws --region $REGION cloudformation create-stack \
			--stack-name $STACK_NAME \
			--template-body "$(cat config/cloudformation.template)" \
			--parameters $PARAMETERS \
			--on-failure DO_NOTHING
	else
		echo WARN: Stack $STACK_NAME already exists in status $STATUS
	fi

	while [ CREATE_IN_PROGRESS == "$(getStackStatus)" ] ; do
		echo "INFO: create in progress. sleeping 15 seconds..."
		sleep 15
	done

	if [ $(getStackStatus) != CREATE_COMPLETE ] ; then
		echo "ERROR: failed to create stack: $(getStackStatus)"
		exit 1
	fi

	while [ $(getNumberOfInstancesWithoutPrivateIp) -gt 0 ] ; do
		echo "INFO: not all instances have a private ip address. sleep 10 seconds.."
		getHostTable
		sleep 10
	done
}

function getHostTable() {
	aws --region $REGION ec2 describe-instances --filters  Name=instance-state-name,Values=running Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME | \
	  jq  -r ' .Reservations[] | 
	.Instances[] |  
	select(.Tags[] |  .Key == "aws:cloudformation:logical-id" ) | 
	[
	(.Tags[] | 
		select(.Key == "aws:cloudformation:logical-id") | .Value), 
		if .PublicIpAddress then .PublicIpAddress else "null" end, 
		if .PrivateIpAddress then .PrivateIpAddress else "null" end
	] | 
	join("	")' | \
	sort
}



function getPublicIPAddress() {
	getHostTable | grep $1 | awk '{print $2}' | grep -v null
}

function getBastionIPAddresses() {
	getHostTable | grep -e Bastion | awk '{print $2}' | grep -v null
}

function getAllPrivateIPAddresses() {
	getHostTable | grep -v Bastion -v NAT | awk '{print $2}' | grep -v null
}

function generateSSHConfig() {
	(
	getHostTable | grep -v NAT | while read LINE; do
		NAME=$(echo $LINE | awk '{print $1;}')
		PUBLIC_IP=$(echo $LINE | awk '{print $2;}')
		PRIVATE_IP=$(echo $LINE | awk '{print $3;}')
		case $NAME in
		*Bastion*)
			if [ -z "$FIRST_BASTION" ] ; then
				FIRST_BASTION=$NAME
			fi
			echo "Host $NAME"
			echo "	HostName $PUBLIC_IP"
			echo "	User ec2-user"
			echo "	IdentityFile $(pwd)/$STACK_DIR/$STACK_NAME.pem"
			echo ""
			;;
		
		*)
			echo "Host $NAME"
			echo "	HostName $PRIVATE_IP"
			echo "	User stackato"
			echo "	ProxyCommand  ssh $FIRST_BASTION nc -w 120 %h %p"
			echo "	IdentityFile $(pwd)/$STACK_DIR/$STACK_NAME.pem"
			echo ""
			;;
		esac
	done
	) > stacks/$STACK_NAME/sshconfig
}

function generateAnsibleInventory() {
	(
	HOSTS=$(getHostTable | grep -v -e NAT  -e Bastion | awk '{print $1}')

	echo
	echo '[cloudcontrollers]'
	for HOST in $(echo "$HOSTS" | grep CloudController) ; do
		echo $HOST
	done
	echo
	echo '[routers]'
	for HOST in $(echo "$HOSTS" | grep Router) ; do
		echo $HOST
	done
	echo
	echo '[deas]'
	for HOST in $(echo "$HOSTS" | grep Dea) ; do
		echo $HOST
	done
	echo
	echo '[services]'
	for HOST in $(echo "$HOSTS" | grep Service) ; do
		echo $HOST
	done
	) > stacks/$STACK_NAME/hosts
}

function addKeyToKnownHosts() {
	HOST=$1
	KEY=$2
	if [ -f ~/.ssh/known_hosts ] ; then
		ssh-keygen -R $HOST 2>/dev/null
	fi
	(
		cat ~/.ssh/known_hosts 2>/dev/null
		echo "$KEY"
	) | sort > ~/.ssh/known_hosts.new
	chmod 0700 ~/.ssh/known_hosts.new
	mv -f ~/.ssh/known_hosts{.new,}
}

function updateKnownHosts() {
	
	if [ ! -f ~/.ssh/known_hosts.saved ] ; then
		cp ~/.ssh/known_hosts{,.saved}
		chmod 0700 ~/.ssh/known_hosts.saved
	fi

	getHostTable | grep -v NAT | while read LINE; do
		NAME=$(echo $LINE | awk '{print $1;}')
		PUBLIC_IP=$(echo $LINE | awk '{print $2;}')
		PRIVATE_IP=$(echo $LINE | awk '{print $3;}')
		case $NAME in
		*Bastion*)
			HOST=$PUBLIC_IP
			if [ -z "$BASTION_HOST" ] ; then
				BASTION_HOST=$HOST
			fi
			KEY=$(ssh-keyscan -t rsa -H $HOST)
			;;
		*)
			HOST=$PRIVATE_IP
			KEY=$(ssh -i $STACK_DIR/$STACK_NAME.pem ec2-user@$BASTION_HOST ssh-keyscan -t rsa -H $HOST < /dev/null)
			while [ -z "$KEY" ] ; do
				echo "WARN: ssh-keyscan failed for $HOST. sleep 10 seconds"
				sleep 10
				KEY=$(ssh -i $STACK_DIR/$STACK_NAME.pem ec2-user@$BASTION_HOST ssh-keyscan -t rsa -H $HOST < /dev/null)
			done
			;;
		esac
		if [ -n "$KEY" ] ; then
			addKeyToKnownHosts $HOST "$KEY"
		else
			echo "WARN: ssh-keyscan failed for $HOST."
		fi
	done
}

function generateStackatoPassword() {
	if [ ! -f $STACK_DIR/stackato-password.txt ] ; then
		openssl rand -base64 8 > $STACK_DIR/stackato-password.txt
		chmod 0700 $STACK_DIR/stackato-password.txt
	fi
	STACKATO_PASSWORD=$(cat $STACK_DIR/stackato-password.txt)
}

function installSSHConfig() {
	INSTALL=0
	if [ ! -f ~/.ssh/config ] ; then
		INSTALL=1
	else
		if ! cmp -s $STACK_DIR/sshconfig ~/.ssh/config ; then
			echo "INFO: copy of ~/.ssh/config saved to ~/.ssh/config.saved"
			mv ~/.ssh/config{,.saved}
			INSTALL=1
		fi
	fi
	if [ $INSTALL -eq 1 ] ; then
		cp $STACK_DIR/sshconfig ~/.ssh/config
	fi
}

function changeStackatoSudoer() {
	generateStackatoPassword
	ansible-playbook -i $STACK_DIR/hosts \
		-e "{ \"stackato_password\" : \"$STACKATO_PASSWORD\" }" \
		ansible/sudo.yml
}

function initializeStackato() {
	generateStackatoPassword
	ansible-playbook -v -i $STACK_DIR/hosts \
 		-e "{
			\"external_dns_name\":\"$DOMAIN_NAME\", 
			\"admin_email\":\"$EMAIL\", 
			\"admin_password\":\"$STACKATO_PASSWORD\", 
			\"admin_organization\":\"$ORGANIZATION\", 
			\"stackato_license\":\"$LICENSE\" }" \
		ansible/stackato.yml
}

parseCommandLine $@
getOrGenerateCertificate
createKeyPair
createStack
generateSSHConfig
installSSHConfig
updateKnownHosts
generateAnsibleInventory
changeStackatoSudoer
initializeStackato
