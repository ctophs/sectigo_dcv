#!/bin/bash
#
# Domain Control Validation using
# Sectigo and Cloudflare DNS
#
# This script is here in order to be able to maintain it for a former
# customer. Please do not complain if it kills your hamster.
#
# Also: I know bash was not the smartest idea to implement this. Works for me.
#
# What this script does:
#
# In order to buy certificates from sectigo you have to proof
# DNS control over each Domain in it.
#
# First the domain is added to the sectigo delegated
# domains list.
#
# Proof is done by adding a cname to the domain.
# That proof has a limited lifetime and has to be renewed after a while.
# Old proofs will get removed.
#
# It might take a few minutes for that proof to be validated by sectigo.
#
# It reads secrets from a .secrets file
# .secrets.sample included
#
# usage: ./dcv.bash myfancydomain.de
#
#
############################SANITYCHK###########################################

command -v jq >/dev/null 2>&1 || { echo >&2 "jq is not installed. sudo apt install jq"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "curl is not installed. sudo apt install curl"; exit 1; }

# shellcheck disable=SC1091
test -r .secrets && source ".secrets"
if [ -z ${LOGIN+x} ]; then echo "missing secrets"; exit; fi

DOMAIN="$1"
DEBUG="something"

##############################FUNCTIONS#########################################

function sectigo_delegate_domain() {
    if ! [ -z ${DEBUG+x} ]; then
        echo "${FUNCNAME[0]}" >"${FUNCNAME[0]}.debug"
    fi
    echo -n "Sectigo: Adding Domain: $1 "
    OUTPUT=$(
        curl -s 'https://hard.cert-manager.com/api/domain/v1' -X POST \
            -H "customerUri: ${CUSTOMER_URI}" \
            -H 'Content-Type: application/json;charset=utf-8' \
            -H "login: ${LOGIN}" \
            -H @<(echo "password: ${PASSWORD}") \
            -d '{"name":"'*."$1"'","description":"created by script","active":true,"delegations":[{"orgId":6249,"certTypes":["SSL"]}]}'
    )
    if ! [ -z ${DEBUG+x} ]; then
        echo "$OUTPUT" >>"${FUNCNAME[0]}.debug"
    fi
    # the domain add call does not return json unless in case of error
    if [ "$(jq -er '.code ' <<<"${OUTPUT}")" ]; then
        echo "not ok"
        return 1
    fi
    echo "ok"
}

function cloudflare_delete_cname() {
   # IDENTIFIER = $1
   # ZONEID = $2
   OUTPUT=$(
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$2/dns_records/$1" \
        -H @<(echo "Authorization: Bearer ${CFBEARER})" \
        -H "Content-Type:application/json"
   )
   if [ "$(jq -r '.success' <<<"${OUTPUT}")" == "true" ]; then
     echo "ok"
   else
     echo "NOK!"
     echo $OUTPUT
   fi
}

##############################################################################

# 1755: DCV sanity Check $1 parameter
PATTERN='^([a-z0-9-]*)(\.[a-zA-z]{1,3})$'
if ! [[ $1 =~ $PATTERN ]]; then
    echo "Parameter Sanity Check failed for ${1}"
    exit 1
fi

# Get Zone ID from Domain in Cloudflare
OUTPUT=$(
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H @<(echo "Authorization: Bearer ${CFBEARER})" \
        -H "Content-Type:application/json"
)
if ! [ -z ${DEBUG+x} ]; then
    echo "${OUTPUT}" >output.get.zoneid.debug
fi
echo -n "Cloudflare: Find Zone ID for $DOMAIN: "
if [ "$(jq -r '.success' <<<"${OUTPUT}")" == "false" ]; then
    echo "error"
    exit 1
fi
ZONEID=$(jq -r '.result | .[].id' <<<"${OUTPUT}")
echo "ok $ZONEID"
unset OUTPUT

# GET CNAMEs from Domain
OUTPUT=$(
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONEID/dns_records?type=CNAME&match=all" \
        -H @<(echo "Authorization: Bearer ${CFBEARER})" \
        -H "Content-Type:application/json"
)

CNAMEIDS_TO_DELETE="$(jq -j '.result[] | .id+" ",.name+" ", .content+"\n"' <<<"${OUTPUT}" | egrep '^[a-z0-9]{32}\s_[a-z0-9]{32}\..*\s[a-z0-9]{32}\.[a-z0-9]{32}\.(sectigo.com|comodoca.com)' | cut -d" " -f1)"

if [ ! "$CNAMEIDS_TO_DELETE" ]; then echo "No DCV CNAMEs to delete in $DOMAIN"
else
 for ID in ${CNAMEIDS_TO_DELETE}; do
  echo -n "Delete CNAME ID $ID from $DOMAIN (Zone ID:) $ZONEID ";
  cloudflare_delete_cname $ID $ZONEID
 done
fi

OUTPUT=""
# Start DCV for Domain in sectigo
until [ "$(jq -er '.host ' <<<"${OUTPUT}")" ]; do

    echo -n "Sectigo: Start DCV for $DOMAIN is: "
    OUTPUT=$(
        curl -s 'https://hard.cert-manager.com/api/dcv/v1/validation/start/domain/cname' -X POST \
            -H "customerUri: ${CUSTOMER_URI}" \
            -H 'Content-Type: application/json;charset=utf-8' \
            -H "login: ${LOGIN}" \
            -H @<(echo "password: ${PASSWORD}") \
            -d '{"domain":"'"$DOMAIN"'"}'
    )

    if ! [ -z ${DEBUG+x} ]; then
        echo "${OUTPUT}" >output.dcv.start.debug
    fi

    DCV_ERROR=$(jq -r '.code' <<<"${OUTPUT}")
    if [ "$DCV_ERROR" == '-727' ]; then
        echo "Sectigo: Domain $DOMAIN does not exist (delegate?)"
        sectigo_delegate_domain "$DOMAIN"
    fi

done

TMPHOST=$(jq -r '.host ' <<<"${OUTPUT}")
CNAME_HOST=${TMPHOST::${#TMPHOST}-1}
TMPPOINT=$(jq -r '.point ' <<<"${OUTPUT}")
CNAME_POINT=${TMPPOINT::${#TMPPOINT}-1}
echo "ok"

# Add CNAME to Domain in Cloudflare
echo -n "Cloudflare: Add DCV CNAME to $DOMAIN in Cloudflare: "
OUTPUT=$(
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONEID/dns_records" \
        -H @<(echo "Authorization: Bearer ${CFBEARER})" \
        -H "Content-Type:application/json" \
        --data '{"type":"CNAME","name":"'"$CNAME_HOST"'","content":"'"$CNAME_POINT"'","ttl":120}'
)
if ! [ -z ${DEBUG+x} ]; then
    echo "${OUTPUT}" >output.add.cname.debug
fi
if [ "$(jq -r '.success' <<<"${OUTPUT}")" == "false" ]; then
    echo "error"
    exit 1
fi
echo "ok"

# Submit DCV for Domain in sectigo
echo -n "Sectigo: Submit DCV for $DOMAIN: "
OUTPUT=$(
    curl -s 'https://hard.cert-manager.com/api/dcv/v1/validation/submit/domain/cname' -X POST \
        -H "customerUri: ${CUSTOMER_URI}" \
        -H 'Content-Type: application/json;charset=utf-8' \
        -H "login: ${LOGIN}" \
        -H @<(echo "password: ${PASSWORD}") \
        -d '{"domain":"'"$DOMAIN"'"}'
)
if ! [ -z ${DEBUG+x} ]; then
    echo "${OUTPUT}" >output.submit.dcv.debug
fi
if [ "$(jq -r '.orderStatus' <<<"${OUTPUT}")" != "SUBMITTED" ]; then
    echo "error"
    exit 1
fi
echo "ok"
