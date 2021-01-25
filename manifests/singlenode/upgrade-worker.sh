#!/bin/bash

# Run this script on the node in order to update a single master install

set -x

# Fetch expected master config
MC=$(oc get mcp/worker -o=jsonpath='{.spec.configuration.name}')
oc get "mc/${MC}" -o yaml > /tmp/mc.yaml

# Annotate the node as if it has succeeded
oc annotate "node/$(hostname -f)" "machineconfiguration.openshift.io/desiredConfig"="${MC}" --overwrite

# Pivot to new machine config and reboot
/run/bin/machine-config-daemon start --root-mount=/ --node-name="$(hostname -f)" --once-from /tmp/mc.yaml
