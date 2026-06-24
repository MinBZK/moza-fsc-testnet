#!/usr/bin/env sh
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Verwijder world read/write van key-bestanden.
BASE_DIR="$( cd "$( dirname "$0" )" >/dev/null 2>&1 && pwd )"
find "${BASE_DIR}" -name "*-key.pem" -type f -exec chmod o-rw {} \;
find "${BASE_DIR}" -name "key.pem"   -type f -exec chmod o-rw {} \;
