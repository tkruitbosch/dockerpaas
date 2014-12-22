#!/bin/bash
if [ $# -ne 1 ] ; then
	echo $(basename $0) domain-name
	exit 1
fi
export DOMAIN_NAME=$1

SSL_KEY_NAME=$(aws iam list-server-certificates | jq -r "  .ServerCertificateMetadataList[] | select(.ServerCertificateName == \"$DOMAIN_NAME\") | .Arn ")

if [ -z "$SSL_KEY_NAME" ] ; then
	SSL_KEY_NAME=$(
	cd /tmp
	umask 077
	openssl genrsa 1024 > $DOMAIN_NAME.key 2>/dev/null
	openssl req -nodes -newkey rsa:2048 -keyout $DOMAIN_NAME.key -subj /CN=$DOMAIN_NAME > $DOMAIN_NAME.csr 2>/dev/null
	openssl x509 -req -days 365 -in $DOMAIN_NAME.csr -signkey $DOMAIN_NAME.key > $DOMAIN_NAME.crt 2>/dev/null
	aws iam upload-server-certificate --server-certificate-name $DOMAIN_NAME \
					--certificate-body file://./$DOMAIN_NAME.crt  \
					--private-key file://./$DOMAIN_NAME.key | \
		jq -r '.ServerCertificateMetadata | .Arn'

	rm -f $DOMAIN_NAME{.key,.csr,.crt}
	)
fi
echo $SSL_KEY_NAME

