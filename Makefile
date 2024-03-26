.EXPORT_ALL_VARIABLES:
.DEFAULT_GOAL := help
AWS_BASE_DOMAIN=devcluster.openshift.com
GCE_BASE_DOMAIN=origin-gce.dev.openshift.com
LIBVIRT_BASE_DOMAIN=tt.testing
MOUNT_FLAGS=:z
INSTALLER_PARAMS=
MANIFESTS=
TYPE=origin
PULL_SECRET=pull_secrets/pull_secret.json
SSH_PUBLICKEY=./ssh-publickey
PODMAN=podman
PODMAN_RUN=${PODMAN} run --rm \
  -v $(shell pwd)/clusters/${CLUSTER}:/output${MOUNT_FLAGS} \
  --userns=keep-id
PODMAN_TF=${PODMAN} run --privileged --rm \
  --userns=keep-id \
  --workdir=/${TF_DIR} \
  -v $(shell pwd)/${TF_DIR}:/${TF_DIR}${MOUNT_FLAGS} \
  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
  -e AWS_DEFAULT_REGION=us-east-1 \
  -ti ${TERRAFORM_IMAGE}
PODMAN_INSTALLER=${PODMAN_RUN} ${INSTALLER_PARAMS} -ti ${INSTALLER_IMAGE}

LOG_LEVEL=info
LOG_LEVEL_ARGS=--log-level ${LOG_LEVEL}

VERSION=4.16
TERRAFORM_IMAGE=hashicorp/terraform:0.11.13
INSTALLER_IMAGE=registry.ci.openshift.org/${TYPE}/${VERSION}:installer
CLI_IMAGE=registry.ci.openshift.org/${TYPE}/${VERSION}:cli
YQ=yq
LATEST_RELEASE=1
ifneq ("$(LATEST_RELEASE)","")
	RELEASE_IMAGE=registry.ci.openshift.org/${TYPE}/release:${VERSION}
endif
OFFICIAL_RELEASE=
ifneq ("$(OFFICIAL_RELEASE)","")
	VERSION=4.3
	RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.3.3
endif
ifneq ("$(RELEASE_IMAGE)","")
	INSTALLER_PARAMS=-e OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE}
endif

all: help
install: check pull-installer aws ## Start install from scratch

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

check: ## Verify all necessary files exist
ifndef CLUSTER
CLUSTER := ${USERNAME}
endif
ifeq (,$(wildcard ./${PULL_SECRET}))
	$(error "${PULL_SECRET} not found!")
endif
ifeq (,$(wildcard ./${SSH_PUBLICKEY}))
	$(error "./${SSH_PUBLICKEY} secret not found!")
endif

cleanup: ## Remove remaining installer bits
	rm -rf clusters/${CLUSTER}; rm -rf test-artifacts/${CLUSTER} || true

pull-installer: ## Pull fresh installer image
	${PODMAN} pull --authfile $(shell pwd)/${PULL_SECRET} ${INSTALLER_IMAGE}

create-config: ## Create install-config.yaml
	cp -rf ${TEMPLATE} ${INSTALL_CONFIG}
	yq e ".baseDomain = env(BASE_DOMAIN)" -i ${INSTALL_CONFIG}
	yq e ".metadata.name = env(CLUSTER)" -i ${INSTALL_CONFIG}
	yq e ".pullSecret = strenv(PULL_SECRET_CONTENTS)" -i ${INSTALL_CONFIG}
	yq e ".sshKey = strenv(SSH_PUBLICKEY_CONTENTS)" -i ${INSTALL_CONFIG}
	cp -rf ${INSTALL_CONFIG} ${INSTALL_CONFIG}.copy
create-config: INSTALL_CONFIG?=clusters/${CLUSTER}/install-config.yaml
create-config: PULL_SECRET_CONTENTS=$(shell cat ${PULL_SECRET})
create-config: SSH_PUBLICKEY_CONTENTS=$(shell cat ${SSH_PUBLICKEY})

copy-manifests: ## Copy manifests from manifests/ dir
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -ti ${INSTALLER_IMAGE} create manifests ${LOG_LEVEL_ARGS} --dir /output
ifneq ("$(MANIFESTS)","")
	cp -rvf manifests/${MANIFESTS}/* clusters/${CLUSTER}/openshift
endif

aws: check pull-installer ## Create AWS cluster
	$(eval INSTALLER_PARAMS := ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -e BASE_DOMAIN=${AWS_BASE_DOMAIN} \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS})
	mkdir -p clusters/${CLUSTER}
	${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	make create-config TEMPLATE=${TEMPLATE} PULL_SECRET=${PULL_SECRET} BASE_DOMAIN=${AWS_BASE_DOMAIN}
	make copy-manifests "INSTALLER_PARAMS=${INSTALLER_PARAMS}"
	${PODMAN_RUN} ${INSTALLER_PARAMS} -ti ${INSTALLER_IMAGE} \
	  create cluster ${LOG_LEVEL_ARGS} --dir /output
aws: TEMPLATE?=templates/aws.yaml.j2

gcp: check pull-installer ## Create GCP cluster
	$(eval INSTALLER_PARAMS := ${INSTALLER_PARAMS} \
	  -e GOOGLE_CREDENTIALS=/tmp/.gcp/credentials \
	  -e BASE_DOMAIN=${GCE_BASE_DOMAIN} \
	  -v $(shell pwd)/.gcp/credentials:/tmp/.gcp/credentials${MOUNT_FLAGS})
	mkdir -p clusters/${CLUSTER}
	${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	make create-config TEMPLATE=${TEMPLATE} PULL_SECRET=${PULL_SECRET} BASE_DOMAIN=${GCE_BASE_DOMAIN}
	make copy-manifests "INSTALLER_PARAMS=${INSTALLER_PARAMS}"
	${PODMAN_RUN} ${INSTALLER_PARAMS} -ti ${INSTALLER_IMAGE} \
	  create cluster ${LOG_LEVEL_ARGS} --dir /output
gcp: TEMPLATE?=templates/gcp.yaml.j2

vsphere: check pull-installer ## Create vSphere cluster
	$(eval INSTALLER_PARAMS := ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -e BASE_DOMAIN=${AWS_BASE_DOMAIN} \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -v $(shell pwd)/.vsphere:/etc/pki/ca-trust${MOUNT_FLAGS})
	mkdir -p clusters/${CLUSTER}
	${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	make create-config TEMPLATE=${TEMPLATE} PULL_SECRET=${PULL_SECRET} BASE_DOMAIN=${AWS_BASE_DOMAIN}
	make copy-manifests "INSTALLER_PARAMS=${INSTALLER_PARAMS}"
	${PODMAN_RUN} ${INSTALLER_PARAMS} --entrypoint=sh --user=0 -ti ${INSTALLER_IMAGE} -c "update-ca-trust extract"
	${PODMAN_RUN} ${INSTALLER_PARAMS} -ti ${INSTALLER_IMAGE} \
	  create cluster ${LOG_LEVEL_ARGS} --dir /output
vsphere: TEMPLATE?=templates/vsphere.yaml.j2

# vsphere-upi: check pull-installer ## Create vsphere UPI cluster
# 	${PODMAN_INSTALLER} version
# 	make create-config TEMPLATE=${TEMPLATE} PULL_SECRET=${PULL_SECRET} BASE_DOMAIN=${AWS_BASE_DOMAIN}
# 	make copy-manifests
# 	${PODMAN_INSTALLER} create ignition-configs --dir /output
# 	${ANSIBLE} -m template -a "src=terraform.tfvars.j2 dest=${TF_DIR}/terraform.tfvars"
# 	${PODMAN_TF} init
# 	${PODMAN_TF} apply -auto-approve
# 	${PODMAN_INSTALLER} wait-for bootstrap-complete ${LOG_LEVEL_ARGS} --dir /output
# 	${PODMAN_TF} apply -auto-approve -var 'bootstrap_complete=true'
# 	${PODMAN_INSTALLER} wait-for install-complete ${LOG_LEVEL_ARGS} --dir /output
# vsphere-upi: TEMPLATE?=templates/vsphere.yaml.j2

patch-vsphere: ## Various configs
	oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs oc --config=/$/output/auth/kubeconfig adm certificate approve
	while true; do oc --config=clusters/${CLUSTER}/auth/kubeconfig get configs.imageregistry.operator.openshift.io/cluster && break; done
	oc patch configs.imageregistry.operator.openshift.io cluster --type=merge --patch '{"spec": {"storage": {"filesystem": {"volumeSource": {"emptyDir": {}}}}}}'

ovirt: check pull-installer ## Create OKD cluster on oVirt
	$(eval INSTALLER_PARAMS := ${INSTALLER_PARAMS} \
	  -e OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE="fcos-31" \
	  -v $(shell pwd)/.cache:/output/.cache${MOUNT_FLAGS} \
	  -v $(shell pwd)/.ovirt:/output/.ovirt/${MOUNT_FLAGS})
	mkdir -p clusters/${CLUSTER}
	${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	make create-config PULL_SECRET=${PULL_SECRET} TEMPLATE=${TEMPLATE}
	make copy-manifests "INSTALLER_PARAMS=${INSTALLER_PARAMS}"
	${PODMAN_RUN} ${INSTALLER_PARAMS} -ti ${INSTALLER_IMAGE} \
	  create cluster ${LOG_LEVEL_ARGS} --dir /output
ovirt: TEMPLATE?=templates/ovirt.yaml.j2

libvirt: check pull-installer ## Create libvirt cluster
	$(eval INSTALLER_PARAMS := ${INSTALLER_PARAMS} \
		-e BASE_DOMAIN=${LIBVIRT_BASE_DOMAIN} \
		-v $(shell pwd)/.cache:/output/.cache${MOUNT_FLAGS})
	mkdir -p clusters/${CLUSTER}
	${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	make create-config TEMPLATE=${TEMPLATE} PULL_SECRET=${PULL_SECRET} BASE_DOMAIN=${LIBVIRT_BASE_DOMAIN}
	make copy-manifests "INSTALLER_PARAMS=${INSTALLER_PARAMS}"
	sed -i 's;domainMemory: .*;domainMemory: 8192;g' clusters/${CLUSTER}/openshift/99_openshift-cluster-api_master-machines-0.yaml
	${PODMAN_RUN} ${INSTALLER_PARAMS} -ti ${INSTALLER_IMAGE} \
	  create cluster ${LOG_LEVEL_ARGS} --dir /output
libvirt: TEMPLATE?=templates/libvirt.yaml.j2

openstack: check pull-installer ## Create OKD cluster on Openstack
	$(eval INSTALLER_PARAMS := ${INSTALLER_PARAMS} \
	  -e OS_CLIENT_CONFIG_FILE=/tmp/.config/openstack/clouds.yaml \
	  -e OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE="fedora-coreos-31.20200113.3.1" \
	  -v $(shell pwd)/.openstack:/tmp/.config/openstack${MOUNT_FLAGS})
	mkdir -p clusters/${CLUSTER}
	${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	make create-config PULL_SECRET=${PULL_SECRET} TEMPLATE=${TEMPLATE} BASE_DOMAIN=${OPENSTACK_BASE_DOMAIN}
	make copy-manifests "INSTALLER_PARAMS=${INSTALLER_PARAMS}"
	${PODMAN_RUN} ${INSTALLER_PARAMS} -ti ${INSTALLER_IMAGE} \
	  create cluster ${LOG_LEVEL_ARGS} --dir /output
openstack: TEMPLATE?=templates/openstack.yaml.j2

destroy-openstack: ## Destroy openstack cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e OS_CLIENT_CONFIG_FILE=/tmp/.config/openstack/clouds.yaml \
	  -v $(shell pwd)/.openstack:/tmp/.config/openstack${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster ${LOG_LEVEL_ARGS} --dir /output
	make cleanup

destroy-ovirt: ## Destroy ovirt cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -v $(shell pwd)/.cache:/output/.cache${MOUNT_FLAGS} \
	  -v $(shell pwd)/.ovirt:/output/.ovirt/${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster ${LOG_LEVEL_ARGS} --dir /output
	make cleanup

destroy-vsphere-upi: ## Destroy vsphere cluster
	${PODMAN_TF} destroy -auto-approve
	make cleanup
	git clean tf/ -fx

destroy-aws: ## Destroy AWS cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster ${LOG_LEVEL_ARGS} --dir /output
	make cleanup

destroy-gcp: ## Destroy GCP cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e GOOGLE_CREDENTIALS=/tmp/.gcp/credentials \
	  -v $(shell pwd)/.gcp/credentials:/tmp/.gcp/credentials${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster ${LOG_LEVEL_ARGS} --dir /output
	make cleanup

destroy-libvirt: ## Destroy libvirt cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster ${LOG_LEVEL_ARGS} --dir /output
	make cleanup

destroy-vsphere: ## Destroy vSphere IPI cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -e BASE_DOMAIN=${AWS_BASE_DOMAIN} \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -v $(shell pwd)/.vsphere:/etc/pki/ca-trust${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster ${LOG_LEVEL_ARGS} --dir /output
	make cleanup

update-cli: ## Update CLI image
	${PODMAN} pull ${CLI_IMAGE}
	${PODMAN} run --rm --userns=keep-id \
	  -v ~/.local/bin:/host/bin \
	  --entrypoint=sh \
	  -ti ${CLI_IMAGE} \
	  -c "cp /usr/bin/oc /host/bin/oc"


watch-bootstrap: ## Watch bootstrap logs via journal-gatewayd
	curl -Lvs --insecure \
	  --cert clusters/${CLUSTER}/tls/journal-gatewayd.crt \
	  --key clusters/${CLUSTER}/tls/journal-gatewayd.key \
	  "https://api.${CLUSTER}.${BASE_DOMAIN}:19531/entries?follow&_SYSTEMD_UNIT=bootkube.service"

.PHONY: all $(MAKECMDGOALS)
