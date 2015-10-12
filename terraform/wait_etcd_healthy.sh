#!/usr/bin/env bash

try=0
until [ $try -ge 30 ]; do
    etcdctl cluster-health && break
    try=$[$try+1]
    sleep 1
done
