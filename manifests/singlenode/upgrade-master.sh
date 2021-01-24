#!/bin/bash

# Run this script on the node in order to update a single master install

set -x

# Get master node name
NODE=$(oc get node -l node-role.kubernetes.io/worker= -o=jsonpath='{.items[*].metadata.name}')

# Fetch expected master config
MC=$(oc get mcp/master -o=jsonpath='{.spec.configuration.name}')
oc get "mc/${MC}" -o yaml > /tmp/mc.yaml

# Annotate the node as if it has succeeded
oc annotate "node/${NODE}" "machineconfiguration.openshift.io/desiredConfig"="${MC}" --overwrite

# Pivot to new machine config and reboot
/run/bin/machine-config-daemon start --root-mount=/ --node-name="${NODE}" --once-from /tmp/mc.yaml
