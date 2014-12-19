#!/bin/bash

DOMAIN_NAME=
STACK_NAME=
REGION=eu-central-1
STACK_DIR=stacks/
ORGANIZATION=
LICENSE=
EMAIL=

HOSTS="cc-az-1 router-az-1 router-az-2 dea-1-az-1 dea-2-az-2 dea-3-az-1 dea-4-az-2 services-az-1"

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
	if [ -z $(aws --region $REGION ec2 describe-key-pairs  | jq " .KeyPairs[] | select(.KeyName == \"$STACK_NAME\") | .KeyName") ] ; then
		mkdir -p $STACK_DIR
		aws --region $REGION ec2 create-key-pair --key-name $STACK_NAME | \
			jq -r  '.KeyMaterial' | \
			sed 's/\\n/\r/g' > $STACK_DIR/$STACK_NAME.pem
		 chmod 0700 $STACK_DIR/$STACK_NAME.pem
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
	aws --region $REGION cloudformation describe-stacks --stack-name $STACK_NAME | \
		jq -r '.Stacks[] | .StackStatus' 2> /dev/null
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
}

function getHostTable() {
	aws --region $REGION ec2 describe-instances --filters  Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME | \
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
		
		set $LINE
		case $1 in
		*Bastion*)
			if [ -z "$FIRST_BASTION" ] ; then
				FIRST_BASTION=$1
			fi
			echo "Host $1"
			echo "	HostName $2"
			echo "	User ec2-user"
			echo "	IdentityFile $(pwd)/$STACK_DIR/$STACK_NAME.pem"
			echo
			;;
		
		*NAT*)
			;;
		*)
			echo "Host $1"
			echo "	HostName $3"
			echo "	User stackato"
			echo "	ProxyCommand  ssh $FIRST_BASTION nc -w 120 %h %p"
			echo
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
		set $LINE ; HOST=$1
		case $HOST in
		*Bastion*)
			HOST=$2
			if [ -z "$BASTION_HOST" ] ; then
				BASTION_HOST=$HOST
			fi
			KEY=$(ssh-keyscan -t rsa -H $HOST 2>/dev/null)
			;;
		*)
			HOST=$3
			KEY=$(ssh ec2-user@$BASTION_HOST ssh-keyscan -t rsa -H $HOST)
			;;
		esac
		if [ -n "$KEY" ] ; then
			addKeyToKnownHosts $HOST "$KEY"
		else
			echo "WARN: keyscan failed for $HOST."
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
		-e stackato_password=$STACKATO_PASSWORD \
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

