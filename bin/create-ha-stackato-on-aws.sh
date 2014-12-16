#!/bin/bash

DOMAIN_NAME=
STACK_NAME=
REGION=eu-central-1

function parseCommandLine() {
	USAGE="Usage: $(basename $0) -d domain-name [-r region]"

	while getopts "r:d:" OPT; do
		case $OPT in
			r)
				REGION=$OPTARG
				;;
			d)
				DOMAIN_NAME=$OPTARG
				STACK_NAME=$(echo $DOMAIN_NAME | sed -e 's/[^a-zA-Z0-9\-]//g')
				;;
			\*)
				echo $USAGE >&2
				exit 1
				;;
		esac
	done

	if [  -z "$DOMAIN_NAME" ] ; then
		echo $USAGE >&2
		exit 1
	fi
}

function createKeyPair() {
	if [ -z $(aws --region $REGION ec2 describe-key-pairs  | jq " .KeyPairs[] | select(.KeyName == \"$STACK_NAME\") | .KeyName") ] ; then
		mkdir -p $STACK_NAME
		aws --region $REGION ec2 create-key-pair --key-name $STACK_NAME | \
			jq -r  '.KeyMaterial' | \
			sed 's/\\n/\r/g' > $STACK_NAME/$STACK_NAME.pem
		 chmod 0700 $STACK_NAME/$STACK_NAME.pem
	fi
}

function getOrGenerateCertificate() {
	SSL_KEY_NAME=$(aws iam list-server-certificates | \
			jq -r "  .ServerCertificateMetadataList[] | select(.ServerCertificateName == \"$DOMAIN_NAME\") | .Arn ")

	if [ -z "$SSL_KEY_NAME" ] ; then
		mkdir -p $STACK_NAME
		SSL_KEY_NAME=$(
		umask 077
		cd $STACK_NAME
		openssl genrsa 1024 > $DOMAIN_NAME.key 2>/dev/null
		openssl req -nodes -newkey rsa:2048 -keyout $DOMAIN_NAME.key -subj /CN=$DOMAIN_NAME > $DOMAIN_NAME.csr 2>/dev/null
		openssl x509 -req -days 365 -in $DOMAIN_NAME.csr -signkey $DOMAIN_NAME.key > $DOMAIN_NAME.crt 2>/dev/null
		aws iam upload-server-certificate --server-certificate-name $DOMAIN_NAME \
						--certificate-body file://./$DOMAIN_NAME.crt  \
						--private-key file://./$DOMAIN_NAME.key | \
			jq -r '.ServerCertificateMetadata | .Arn'
		)
	fi
	echo $SSL_KEY_NAME
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

	aws --region $REGION cloudformation create-stack \
		--stack-name $(echo $DOMAIN_NAME  | sed -e 's/[.-]//g') \
		--template-body "$(cat config/cloudformation.template)" \
		--parameters $PARAMETERS \
		--on-failure DO_NOTHING
}

parseCommandLine $@
getOrGenerateCertificate
createKeyPair
createStack
