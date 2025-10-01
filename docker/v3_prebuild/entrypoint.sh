#!/bin/sh
set -e

# /exported が存在し、かつ空でなければコピー
if [ -d "/exported" ]; then
  echo "[INFO] /exported mount detected, copying files..."
  cp -r /bundle/*.py /exported/
fi

# アプリ起動
exec /bundle/usr/bin/ezsdr "$@"
