#!/bin/bash
set -e
export IMAGE_NAME="fastapi-rest-api"

result=$(docker images --filter=reference="${IMAGE_NAME}:*" -q | head -n 1)
while [[ -n ${result} ]]
do
    docker rmi -f ${result}
    result=$(docker images --filter=reference="${IMAGE_NAME}:*" -q | head -n 1)
done