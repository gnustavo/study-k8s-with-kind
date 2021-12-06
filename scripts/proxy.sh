#!/bin/bash

# Copyright (C) 2021 by CPQD

set -eu -o pipefail

kubectl --namespace kubernetes-dashboard describe secret $(kubectl --namespace kubernetes-dashboard get secret | awk '/admin-user/ {print $1}')

echo
echo 'http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/'
echo

exec kubectl proxy
