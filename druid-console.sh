#!/usr/bin/env bash

kubectl port-forward -n druid svc/druid-tiny-cluster-routers 8088:8088 &
PF_PID=$!

until curl -s http://localhost:8088 > /dev/null 2>&1; do
  sleep 0.5
done

open http://localhost:8088
wait $PF_PID
