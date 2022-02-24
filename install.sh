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

echo "3) Launching Auth server"
docker-compose up -d auth

echo "4) Provisioning Auth server"
docker-compose exec auth /opt/jboss/keycloak/bin/add-user-keycloak.sh -r lamassu -u enroller -p enroller --roles admin > /dev/null 2>&1
docker-compose exec auth /opt/jboss/keycloak/bin/add-user-keycloak.sh -r lamassu -u operator -p operator --roles operator > /dev/null 2>&1

successful_auth_reload="false"
expected_auth_reload=$(echo '{"outcome" : "success", "result" : null}' | jq -r)

while [ $successful_auth_reload == "false" ]; do

    reload_status=$(docker-compose exec auth /opt/jboss/keycloak/bin/jboss-cli.sh --connect command=:reload --output-json)
    if jq -e . >/dev/null 2>&1 <<<"$reload_status"; then #Check if reload_status is json string
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

echo "5) Launching main services"
docker-compose up -d vault consul-server api-gateway

successful_vault_health="false"
while [ $successful_vault_health == "false" ]; do
    vault_status=$(curl --silent -k https://vault.$DOMAIN/v1/sys/health)
    if jq -e . >/dev/null 2>&1 <<<"$vault_status"; then #Check if reload_status is json string
        echo $vault_status
        successful_vault_health="true"
    else 
        sleep 5s
    fi
done      

echo "6) Initializing and provisioning vault"

docker-compose exec vault vault operator init -key-shares=5 -key-threshold=3 -tls-skip-verify -format=json > vault-credentials.json

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

export CA_VAULT_ROLEID=$(curl -k --header "X-Vault-Token: ${VAULT_TOKEN}" ${VAULT_ADDR}/v1/auth/approle/role/lamassu-ca-role/role-id | jq -r .data.role_id )
export CA_VAULT_SECRETID=$(curl -k --header "X-Vault-Token: ${VAULT_TOKEN}" --request POST ${VAULT_ADDR}/v1/auth/approle/role/lamassu-ca-role/secret-id | jq -r .data.secret_id)

sed -i 's/<LAMASSU_CA_VAULT_ROLE_ID>/'$CA_VAULT_ROLEID'/g' .env
sed -i 's/<LAMASSU_CA_VAULT_SECRET_ID>/'$CA_VAULT_SECRETID'/g' .env

echo "7) Launching remainig services"

docker-compose up -d