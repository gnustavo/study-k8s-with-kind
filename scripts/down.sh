#!/bin/bash

# Copyright (C) 2021 by CPQD

set -eux -o pipefail

kind delete cluster
