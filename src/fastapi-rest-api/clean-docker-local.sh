#!/bin/bash
set -e
export IMAGE_NAME="fastapi-rest-api"

docker rmi -f $(docker images --filter=reference="${IMAGE_NAME}:*" -q) 
