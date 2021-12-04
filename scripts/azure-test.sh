#!/bin/bash
#
# executable
#
# apply Terraform template to deploy cosmos and app service

set -e
# Read variables in configuration file
parent_path=$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../"
    pwd -P
)
source `dirname $0`/common.sh

# container version (current date)
export APP_VERSION=$(date +"%y%M%d.%H%M%S")
# container internal HTTP port
export APP_PORT=5000
# webapp prefix 
export AZURE_APP_PREFIX="testmcwa"

env_path=$1
if [[ -z $env_path ]]; then
    env_path="$(dirname "${BASH_SOURCE[0]}")/../configuration/.default.env"
fi

printMessage "Starting test with local Docker service using the configuration in this file ${env_path}"

if [[ $env_path ]]; then
    if [ ! -f "$env_path" ]; then
        printError "$env_path does not exist."
        exit 1
    fi
    set -o allexport
    source "$env_path"
    set +o allexport
else
    printWarning "No env. file specified. Using environment variables."
fi


function deployAzureInfrastructure(){
    subscription=$1
    region=$2
    prefix=$3
    sku=$4
    datadep=$(date +"%y%M%d-%H%M%S")
    resourcegroup="${prefix}rg"
    webapp="${prefix}webapp"

    cmd="az group create  --subscription $subscription --location $region --name $resourcegroup --output none "
    printProgress "$cmd"
    eval "$cmd"

    checkError
    cmd="az deployment group create \
        --name $datadep \
        --resource-group $resourcegroup \
        --subscription $subscription \
        --template-file `dirname $0`/arm-template.json \
        --output non \
        --parameters \
        webAppName=$webapp sku=$sku"
    printProgress "$cmd"
    eval "$cmd"
    checkError
    # get ACR login server dns name
    ARC_LOGIN_SERVER=$(az deployment group show --resource-group $resourcegroup -n $datadep | jq -r '.properties.outputs.acrLoginServer.value')
    # get WebApp Url
    WEB_APP_SERVER=$(az deployment group show --resource-group $resourcegroup -n $datadep | jq -r '.properties.outputs.webAppServer.value')
}

function buildWebAppContainer() {
    apiModule="$1"
    imageName="$2"
    imageTag="$3"
    imageLatestTag="$4"
    portHttp="$5"

    targetDirectory="$(dirname "${BASH_SOURCE[0]}")/../$apiModule"

    if [ ! -d "$targetDirectory" ]; then
            echo "Directory '$targetDirectory' does not exist."
            exit 1
    fi

    echo "Building and uploading the docker image for '$apiModule'"

    # Navigate to API module folder
    pushd "$targetDirectory" > /dev/null

    # Build the image
    echo "Building the docker image for '$imageName:$imageTag'"
    docker build -t ${imageName}:${imageTag} -f Dockerfile --build-arg APP_VERSION=${imageTag} --build-arg ARG_PORT_HTTP=${portHttp} .
    # Push with alternative tag
    docker tag ${imageName}:${imageTag} ${imageName}:${imageLatestTag}
    
    popd > /dev/null

}

function clearImage(){
    imageName="$1"
    # stop the container
    docker container stop "$1" 2>/dev/null || true
    # remove the container
    docker container rm "$1" 2>/dev/null || true
    # remove the images
    result=$(docker images --filter=reference="${imageName}:*" -q | head -n 1)
    while [ -n "${result}" ]
    do
        docker rmi -f ${result}
        result=$(docker images --filter=reference="${imageName}:*" -q | head -n 1)
    done
}


# Check Azure connection
printMessage "Check Azure connection for subscription: '$AZURE_SUBSCRIPTION_ID'"
azLogin
checkError

# Deploy infrastructure image
printMessage "Deploy infrastructure subscription: '$AZURE_SUBSCRIPTION_ID' region: '$AZURE_REGION' prefix: '$AZURE_APP_PREFIX' sku: 'B2'"
deployAzureInfrastructure $AZURE_SUBSCRIPTION_ID $AZURE_REGION $AZURE_APP_PREFIX "B2"
printMessage "Azure Container Registry DNS name: ${ARC_LOGIN_SERVER}"
printMessage "Azure Web App Url: ${WEB_APP_SERVER}"

exit 1

# Build nginx-api docker image
printMessage "Building nginx-api container"
clearImage "nginx-api"
buildWebAppContainer "./src/nginx" "nginx-api" "${APP_VERSION}" "latest" 
checkError

# Build fastapi-api docker image
printMessage "Building fastapi-rest-api container version:${APP_VERSION} port: ${APP_PORT}"
clearImage "fastapi-rest-api"
buildWebAppContainer "./src/fastapi-rest-api" "fastapi-rest-api" "${APP_VERSION}" "latest" ${APP_PORT}
checkError

# Build flask-api docker image
printMessage "Building flask-rest-api container version:${APP_VERSION} port: ${APP_PORT}"
clearImage "flask-rest-api"
buildWebAppContainer "./src/flask-rest-api" "flask-rest-api" "${APP_VERSION}" "latest" ${APP_PORT}
checkError

# Deploy nginx, fastapi-rest-api, flask-rest-api
printMessage "Deploying all the containers"
targetDirectory="$(dirname "${BASH_SOURCE[0]}")/../src/nginx"
pushd "$targetDirectory" > /dev/null
docker-compose up  -d
checkError
popd > /dev/null

# Test services
# Test flask-rest-api
# get nginx local ip address
# connect to container network if in dev container
ip=$(get_local_host "nginx-api")
flask_rest_api_url="http://$ip/flask-rest-api/version"
printMessage "Testing flask-rest-api url: $flask_rest_api_url expected version: ${APP_VERSION}"
result=$(checkUrl "${flask_rest_api_url}" "${APP_VERSION}" "60")
if [[ $result != "true" ]]; then
    printError "Error while testing flask-rest-api"
else
    printMessage "Testing flask-rest-api successful"
fi

# Test flask-rest-api
fastapi_rest_api_url="http://$ip/fastapi-rest-api/version"
printMessage "Testing fastapi-rest-api url: $fastapi_rest_api_url expected version: ${APP_VERSION}"
result=$(checkUrl "${fastapi_rest_api_url}" "${APP_VERSION}" "60")
if [[ $result != "true" ]]; then
    printError "Error while testing fastapi-rest-api"
else
    printMessage "Testing fastapi-rest-api successful"
fi

# Undeploy nginx, fastapi-rest-api, flask-rest-api
printMessage "Undeploying all the containers"
targetDirectory="$(dirname "${BASH_SOURCE[0]}")/../src/nginx"
pushd "$targetDirectory" > /dev/null
docker-compose down 
checkError
popd

echo "done."