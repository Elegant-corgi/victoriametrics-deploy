#!/bin/bash
mkdir -p /tmp/vmimport
mkdir -p /tmp/vm_done

for i in $(ls -1d /data/local/prometheus/01* | sort -r); do

  block=$(basename "$i")

  if [ -f "/tmp/vm_done/$block.done" ]; then
    echo "skip $block"
    continue
  fi

  echo "importing $block"

  rm -rf /tmp/vmimport/*
  cp -r "$i" /tmp/vmimport/

  yes | ./vmctl-prod prometheus \
    --prom-snapshot=/tmp/vmimport \
    --vm-addr=http://10.102.10.7:8480 \
    --vm-account-id=0 \
    --prom-concurrency=4 \

  if [ $? -eq 0 ]; then
    touch "/tmp/vm_done/$block.done"
    echo "done $block"
  else
    echo "failed $block"
    break
  fi

done
