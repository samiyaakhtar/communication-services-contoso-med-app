#!/usr/bin/env bash

set -eou pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

export $(grep -v '^#' $SCRIPT_DIR/../.env | xargs)

# Install prerequisites
echo "Adding Azure Communication Services extension..."
az extension add --name communication

# Test variables
if [ -z ${LOCATION+x} ]; then echo "Please set LOCATION in the .env file"; fi
if [ -z ${RESOURCE_PREFIX+x} ]; then echo "Please set RESOURCE_PREFIX in the .env file"; fi

# Resource Group
echo "Creating resource group..."
RESOURCE_GROUP_NAME=${RESOURCE_PREFIX}-contoso-med
az group create --name $RESOURCE_GROUP_NAME --location $LOCATION

# Azure Communcation Services - append random int since names are reserved
if [[ `az communication list --resource-group $RESOURCE_GROUP_NAME --query "[] | length(@)"` -eq 0 ]]
then
    RAND_NUM=$((1 + $RANDOM % 1000))
    ACS_NAME=${RESOURCE_PREFIX}-contoso-med-acs${RAND_NUM}
else
    ACS_NAME=`az communication list --resource-group $RESOURCE_GROUP_NAME --query "[0].name" --output tsv`
fi

echo "Creating Communication Service..."
az communication create --name $ACS_NAME --location "Global" --data-location "United States" \
                        --resource-group $RESOURCE_GROUP_NAME
ACS_ENDPOINT=https://${ACS_NAME}.communication.azure.com
ACS_CONNECTION_STRING=`az communication list-key --name $ACS_NAME -g $RESOURCE_GROUP_NAME \
                                                  --query "primaryConnectionString" --output tsv`

# Cosmos DB
echo "Creating Cosmos Instance..."
az cosmosdb create --name ${RESOURCE_PREFIX}-contoso-med-db --resource-group $RESOURCE_GROUP_NAME \
                  --enable-public-network --kind "MongoDB"
echo "Creating Cosmos Database..."
az cosmosdb mongodb database create --account-name ${RESOURCE_PREFIX}-contoso-med-db --resource-group $RESOURCE_GROUP_NAME \
                                    --name contoso-med
DB_CONNECTION_STRING=`az cosmosdb keys list --type connection-strings --name ${RESOURCE_PREFIX}-contoso-med-db \
                      --resource-group $RESOURCE_GROUP_NAME  --output tsv \
                      --query "connectionStrings[?description=='Primary MongoDB Connection String'].connectionString"`

# Azure Logic App
# az logic workflow create --location $LOCATION  --resource_group $RESOURCE_GROUP_NAME

# App Service Plan
echo "Creating App Service Plan..."
APP_PLAN_NAME=${RESOURCE_PREFIX}-contoso-med-plan
az appservice plan create --name $APP_PLAN_NAME --resource-group $RESOURCE_GROUP_NAME --location $LOCATION \
                          --is-linux --sku P1V2

# Function App
echo "Creating Storage Account..."
az storage account create --name ${RESOURCE_PREFIX}contosomedapp --resource-group $RESOURCE_GROUP_NAME \
                          --kind StorageV2 
echo "Creating Function App..."
az functionapp create --resource-group $RESOURCE_GROUP_NAME --plan $APP_PLAN_NAME \
                      --name ${RESOURCE_PREFIX}-contoso-med-functions -s ${RESOURCE_PREFIX}contosomedapp \
                      --runtime node

# QnA Maker
echo "Creating QnA Maker Cognitive Service account..."
az cognitiveservices account create --name  ${RESOURCE_PREFIX}-contoso-med-qa --resource-group $RESOURCE_GROUP_NAME \
                                    --kind "QnAMaker.v2" --sku S0 --location southcentralus \
                                    --custom-domain ${RESOURCE_PREFIX}-contoso-med-qa --yes

# Wait until provisioning is successful
for i in {0..15}
do
    sleep 5 

    QNA_PROVISIONING_STATUS=`az cognitiveservices account show --name  ${RESOURCE_PREFIX}-contoso-med-qa \
                             --resource-group $RESOURCE_GROUP_NAME --query "properties.provisioningState" --output tsv`
    if [[ $QNA_PROVISIONING_STATUS == "Succeeded" ]]; then break; fi
done
if [[ $QNA_PROVISIONING_STATUS != "Succeeded" ]]; then
    echo "QnA Maker failed to provision"
    exit -1
fi

QNA_ENDPOINT=https://${RESOURCE_PREFIX}-contoso-med-qa.cognitiveservices.azure.com/
QNA_KEY=`az cognitiveservices account keys list --name  ${RESOURCE_PREFIX}-contoso-med-qa \
         --resource-group $RESOURCE_GROUP_NAME --query "key1" --output tsv`

# API App Service
echo "Creating App Service for API..."
API_APP_NAME=${RESOURCE_PREFIX}-contoso-med-api
az webapp create --name $API_APP_NAME --resource-group $RESOURCE_GROUP_NAME --plan $APP_PLAN_NAME --runtime "NODE|12-lts"

echo "Configuring API Settings..."
# Don't change the private key if it has already been set
CURRENT_JWT_SETTING=`az webapp config appsettings list -g $RESOURCE_GROUP_NAME -n $API_APP_NAME --query "[?name=='API_JWT_PRIVATE_KEYz']"`
if [[ $CURRENT_JWT_SETTING == '[]' ]]; then
    az webapp config appsettings set -g $RESOURCE_GROUP_NAME -n $API_APP_NAME --settings API_JWT_PRIVATE_KEY=`uuidgen`
fi

az webapp config appsettings set -g $RESOURCE_GROUP_NAME -n $API_APP_NAME --settings \
    COSMOS_MONGO_CONNECTION_STRING=$DB_CONNECTION_STRING \
    COSMOS_MONGO_DATABASE_NAME=contoso-med \
    ACS_CONNECTION_STRING=$ACS_CONNECTION_STRING \
    ACS_ENDPOINT=$ACS_ENDPOINT \
    SMS_LOGIC_APP_ENDPOINT=$SMS_LOGIC_APP_ENDPOINT \
    QNA_MAKER_ENDPOINT=$QNA_ENDPOINT \
    QNA_MAKER_KEY=$QNA_KEY

echo "Setting Function App Settings..."
az functionapp config appsettings set -g $RESOURCE_GROUP_NAME -n ${RESOURCE_PREFIX}-contoso-med-functions --settings \
    QNA_MAKER_ENDPOINT=$QNA_ENDPOINT \
    QNA_MAKER_KEY=$QNA_KEY \
    ACS_ENDPOINT=$ACS_ENDPOINT \
    API_ENDPOINT="https://${RESOURCE_PREFIX}-contoso-med-api.azurewebsites.net"

# Frontend Web App
echo "Configuring storage account for static site hosting..."
az storage blob service-properties update --account-name ${RESOURCE_PREFIX}contosomedapp --static-website \
                                          --index-document index.html

echo "Done!"