#!/bin/bash

echo "Insatlling Lamassu"

#Export .env variables
export $(grep -v '^#' .env | xargs)

echo "1) Generating upstream certificates"
cd tls-certificates
bash gen-upstream-certs.sh > /dev/null 2>&1

echo "2) Generating downstream certificates"
bash gen-downstream-certs.sh > /dev/null 2>&1
cd ..

echo "3) Generating the docker network"
docker network create lamassu-iot-network -d bridge

echo "4) Launching Auth server and Api-Gateway"
docker-compose up -d auth api-gateway

echo "5) Provisioning Auth server"
successful_auth_status="false"

while [ $successful_auth_status == "false" ]; do
    auth_status=$(curl -k -s https://auth.$DOMAIN/auth/realms/lamassu)
    echo $auth_status
    if [[ $(echo $auth_status | jq .realm -r) == "lamassu" ]]; then
        successful_auth_status="true"
    else 
        sleep 5s
    fi
done

docker-compose exec -T auth /opt/jboss/keycloak/bin/add-user-keycloak.sh -r lamassu -u enroller -p enroller --roles admin > /dev/null 2>&1
docker-compose exec -T auth /opt/jboss/keycloak/bin/add-user-keycloak.sh -r lamassu -u operator -p operator --roles operator > /dev/null 2>&1

successful_auth_reload="false"
expected_auth_reload=$(echo '{"outcome" : "success", "result" : null}' | jq -r)

while [ $successful_auth_reload == "false" ]; do
    reload_status=$(docker-compose exec -T auth /opt/jboss/keycloak/bin/jboss-cli.sh --connect command=:reload --output-json)
    echo $reload_status
    if jq -e . >/dev/null 2>&1 <<<"$reload_status" && [[ "$reload_status" != "" ]]; then #Check if reload_status is json string
        reload_status=$(echo $reload_status | jq -r)
        if [ "$reload_status" == "$expected_auth_reload" ]; then
            successful_auth_reload="true"
        else
            sleep 3s
        fi
    else
        sleep 3s
    fi
done

echo "6) Launching main services"
docker-compose up -d vault consul-server api-gateway

successful_vault_health="false"
while [ $successful_vault_health == "false" ]; do
    vault_status=$(curl --silent -k https://vault.$DOMAIN/v1/sys/health)
    echo $vault_status
    if jq -e . >/dev/null 2>&1 <<<"$vault_status" && [[ "$vault_status" != "" ]]; then #Check if reload_status is json string
        echo $vault_status
        successful_vault_health="true"
    else 
        sleep 5s
    fi
done

echo "7) Initializing and provisioning vault"

successful_vault_credentials="false"
while [ $successful_vault_credentials == "false" ]; do
    vault_creds=$(docker-compose exec -T vault vault operator init -key-shares=5 -key-threshold=3 -tls-skip-verify -format=json)
    echo $vault_creds
    if jq -e . >/dev/null 2>&1 <<<"$vault_creds" && [[ "$vault_creds" != "" ]]; then #Check if reload_status is json string
        echo $vault_creds > vault-credentials.json
        successful_vault_credentials="true"
    else 
        sleep 5s
    fi
done

cat vault-credentials.json | jq .unseal_keys_hex -r > vault-ca-credentials.json

export VAULT_TOKEN=$(cat vault-credentials.json | jq .root_token -r)
export VAULT_ADDR=https://vault.$DOMAIN

curl --request PUT "$VAULT_ADDR/v1/sys/unseal" -k --header 'Content-Type: application/json' --data-raw "{\"key\": \"$(cat vault-credentials.json | jq -r .unseal_keys_hex[0])\" }"
curl --request PUT "$VAULT_ADDR/v1/sys/unseal" -k --header 'Content-Type: application/json' --data-raw "{\"key\": \"$(cat vault-credentials.json | jq -r .unseal_keys_hex[1])\" }"
curl --request PUT "$VAULT_ADDR/v1/sys/unseal" -k --header 'Content-Type: application/json' --data-raw "{\"key\": \"$(cat vault-credentials.json | jq -r .unseal_keys_hex[2])\" }"

sleep 5s

cd config/vault/provision/
curl --silent -k https://vault.$DOMAIN/v1/sys/health -I
bash provisioner.sh
cd ../../../

sleep 5s

export CA_VAULT_ROLEID_RESP=$(curl -k --header "X-Vault-Token: ${VAULT_TOKEN}" ${VAULT_ADDR}/v1/auth/approle/role/lamassu-ca-role/role-id)
export CA_VAULT_ROLEID=$(echo $CA_VAULT_ROLEID_RESP | jq -r .data.role_id)
export CA_VAULT_SECRETID_RESP=$(curl -k --header "X-Vault-Token: ${VAULT_TOKEN}" --request POST ${VAULT_ADDR}/v1/auth/approle/role/lamassu-ca-role/secret-id)
export CA_VAULT_SECRETID=$(echo $CA_VAULT_SECRETID_RESP  | jq -r .data.secret_id)

sed -i 's/<LAMASSU_CA_VAULT_ROLE_ID>/'$CA_VAULT_ROLEID'/g' docker-compose.yml
sed -i 's/<LAMASSU_CA_VAULT_SECRET_ID>/'$CA_VAULT_SECRETID'/g' docker-compose.yml

echo "8) Launching remainig services"

mkdir -p lamassu-default-dms/devices-crypto-material
mkdir -p lamassu-default-dms/config
touch lamassu-default-dms/config/dms.key
touch lamassu-default-dms/config/dms.crt

docker-compose up -d opa-server ui lamassu-dms-enroller lamassu-device-manager rabbitmq
sleep 20s 
docker-compose up -d

sleep 5s 

echo "9) Create CAs"

successful_ca_health="false"
export AUTH_ADDR=auth.$DOMAIN
while [ $successful_ca_health == "false" ]; do
    export TOKEN=$(curl -k -s --location --request POST "https://$AUTH_ADDR/auth/realms/lamassu/protocol/openid-connect/token" --header 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'grant_type=password' --data-urlencode 'client_id=frontend' --data-urlencode 'username=enroller' --data-urlencode 'password=enroller' | jq -r .access_token)
    ca_status=$(curl -k -s --location --request GET "https://$DOMAIN/api/ca/v1/health" --header "Authorization: Bearer ${TOKEN}" --header 'Accept: application/json')
    echo $ca_status
    if [[ $(echo $ca_status | jq .healthy -r) == "true" ]]; then
        successful_ca_health="true"
    else 
        sleep 5s
    fi
done

export TOKEN=$(curl -k --location --request POST "https://$AUTH_ADDR/auth/realms/lamassu/protocol/openid-connect/token" --header 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'grant_type=password' --data-urlencode 'client_id=frontend' --data-urlencode 'username=enroller' --data-urlencode 'password=enroller' | jq -r .access_token)

export CA_ADDR=$DOMAIN/api/ca
export CREATE_CA_RESP=$(curl -k -s --location --request POST "https://$CA_ADDR/v1/pki/LamassuRSA4096" --header "Authorization: Bearer ${TOKEN}" --header 'Content-Type: application/json' --data-raw "{\"ca_ttl\": 262800, \"enroller_ttl\": 175200, \"subject\":{ \"common_name\": \"LamassuRSA4096\",\"country\": \"ES\",\"locality\": \"Arrasate\",\"organization\": \"LKS Next, S. Coop\",\"state\": \"Gipuzkoa\"},\"key_metadata\":{\"bits\": 4096,\"type\": \"RSA\"}}")
echo $CREATE_CA_RESP
export CREATE_CA_RESP=$(curl -k -s --location --request POST "https://$CA_ADDR/v1/pki/LamassuRSA2048" --header "Authorization: Bearer ${TOKEN}" --header 'Content-Type: application/json' --data-raw "{\"ca_ttl\": 262800, \"enroller_ttl\": 175200, \"subject\":{ \"common_name\": \"LamassuRSA2048\",\"country\": \"ES\",\"locality\": \"Arrasate\",\"organization\": \"LKS Next, S. Coop\",\"state\": \"Gipuzkoa\"},\"key_metadata\":{\"bits\": 2048,\"type\": \"RSA\"}}")
echo $CREATE_CA_RESP
export CREATE_CA_RESP=$(curl -k -s --location --request POST "https://$CA_ADDR/v1/pki/LamassuECDSA384" --header "Authorization: Bearer ${TOKEN}" --header 'Content-Type: application/json' --data-raw "{\"ca_ttl\": 262800, \"enroller_ttl\": 175200, \"subject\":{ \"common_name\": \"LamassuECDSA384\",\"country\": \"ES\",\"locality\": \"Arrasate\",\"organization\": \"LKS Next, S. Coop\",\"state\": \"Gipuzkoa\"},\"key_metadata\":{\"bits\": 384,\"type\": \"EC\"}}")
echo $CREATE_CA_RESP
export CREATE_CA_RESP=$(curl -k -s --location --request POST "https://$CA_ADDR/v1/pki/LamassuECDSA256" --header "Authorization: Bearer ${TOKEN}" --header 'Content-Type: application/json' --data-raw "{\"ca_ttl\": 262800, \"enroller_ttl\": 175200, \"subject\":{ \"common_name\": \"LamassuECDSA256\",\"country\": \"ES\",\"locality\": \"Arrasate\",\"organization\": \"LKS Next, S. Coop\",\"state\": \"Gipuzkoa\"},\"key_metadata\":{\"bits\": 256,\"type\": \"EC\"}}")
echo $CREATE_CA_RESP

