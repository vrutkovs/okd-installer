.EXPORT_ALL_VARIABLES:
.DEFAULT_GOAL := help
BASE_DOMAIN=devcluster.openshift.com
MOUNT_FLAGS=
PODMAN=podman
PODMAN_RUN=${PODMAN} run --privileged --rm \
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

VERSION=4.2
INSTALLER_IMAGE=registry.svc.ci.openshift.org/origin/${VERSION}:installer
ANSIBLE_IMAGE=registry.svc.ci.openshift.org/origin/${VERSION}:ansible
TESTS_IMAGE=registry.svc.ci.openshift.org/origin/${VERSION}:tests
TERRAFORM_IMAGE=hashicorp/terraform:0.11.13
CLI_IMAGE=registry.svc.ci.openshift.org/origin/${VERSION}:cli

TF_DIR=tf
ADDITIONAL_PARAMS=  -e OPTS="-vvv" \
					-e PLAYBOOK_FILE=test/aws/scaleup.yml \
					-e INVENTORY_DIR=/usr/share/ansible/openshift-ansible/inventory/dynamic/aws
PYTHON=/usr/bin/python3
ANSIBLE=ansible all -i "localhost," --connection=local -e "ansible_python_interpreter=${PYTHON}" -o
LATEST_RELEASE=1
ifneq ("$(LATEST_RELEASE)","")
	RELEASE_IMAGE=registry.svc.ci.openshift.org/origin/release:${VERSION}
endif
OFFICIAL_RELEASE=
ifneq ("$(OFFICIAL_RELEASE)","")
	RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.1.1
endif
ifneq ("$(RELEASE_IMAGE)","")
	INSTALLER_PARAMS=-e OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE}
endif
ANSIBLE_REPO=
ifneq ("$(ANSIBLE_REPO)","")
	ANSIBLE_MOUNT_OPTS=-v ${ANSIBLE_REPO}:/usr/share/ansible/openshift-ansible${MOUNT_FLAGS}
endif

all: help
install: check pull-installer aws ## Start install from scratch

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

check: ## Verify all necessary files exist
ifndef CLUSTER
	CLUSTER=${USERNAME}
endif
ifeq (,$(wildcard ./pull_secret.json))
	$(error "pull_secret.json not found!")
endif
ifeq (,$(wildcard ./ssh-publickey))
	$(error "./ssh-publickey secret not found!")
endif
ifeq (,$(wildcard ./.aws/credentials))
	$(error "./aws/credentials secret not found!")
endif

cleanup: ## Remove remaining installer bits
	rm -rf clusters/${CLUSTER} || true

pull-installer: ## Pull fresh installer image
	${PODMAN} pull ${INSTALLER_IMAGE}

aws: check pull-installer ## Create AWS cluster
	mkdir -p clusters/${CLUSTER}
	${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	env CLUSTER=${CLUSTER} ${ANSIBLE} -m template -a "src=install-config.aws.yaml.j2 dest=clusters/${CLUSTER}/install-config.yaml"
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} create cluster ${LOG_LEVEL_ARGS} --dir /output

watch-bootstrap: ## Watch bootstrap logs via journal-gatewayd
	curl -Lvs --insecure \
	  --cert clusters/${CLUSTER}/tls/journal-gatewayd.crt \
	  --key clusters/${CLUSTER}/tls/journal-gatewayd.key \
	  "https://api.${CLUSTER}.${BASE_DOMAIN}:19531/entries?follow&_SYSTEMD_UNIT=bootkube.service"

vsphere: check pull-installer ## Create vsphere cluster
	${PODMAN_INSTALLER} version
	${ANSIBLE} -m template -a "src=install-config.vsphere.yaml.j2 dest=clusters/${CLUSTER}/install-config.yaml"
	${PODMAN_INSTALLER} create ignition-configs --dir /output
	${ANSIBLE} -m template -a "src=terraform.tfvars.j2 dest=${TF_DIR}/terraform.tfvars"
	${PODMAN_TF} init
	${PODMAN_TF} apply -auto-approve
	${PODMAN_INSTALLER} wait-for bootstrap-complete ${LOG_LEVEL_ARGS} --dir /output
	${PODMAN_TF} apply -auto-approve -var 'bootstrap_complete=true'
	${PODMAN_INSTALLER} wait-for install-complete ${LOG_LEVEL_ARGS} --dir /output

patch-vsphere: ## Various configs
	oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs oc --config=/$/output/auth/kubeconfig adm certificate approve
	while true; do oc --config=clusters/${CLUSTER}/auth/kubeconfig get configs.imageregistry.operator.openshift.io/cluster && break; done
	oc patch configs.imageregistry.operator.openshift.io cluster --type=merge --patch '{"spec": {"storage": {"filesystem": {"volumeSource": {"emptyDir": {}}}}}}'

destroy-vsphere: ## Destroy vsphere cluster
	${PODMAN_TF} destroy -auto-approve
	make cleanup
	git clean tf/ -fx

destroy-aws: ## Destroy AWS cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster ${LOG_LEVEL_ARGS} --dir /output
	make cleanup

update-cli: ## Update CLI image
	${PODMAN} pull ${CLI_IMAGE}
	${PODMAN_RUN} \
	  -v ~/.local/bin:/host/bin \
	  --entrypoint=sh \
	  -ti ${CLI_IMAGE} \
	  -c "cp /usr/bin/oc /host/bin/oc"

pull-ansible-image: ## Pull latest openshift-ansible container
	${PODMAN} pull ${ANSIBLE_IMAGE}

scaleup: check ## Scaleup AWS workers
ifndef ANSIBLE_REPO
	$(error Location of the ansible repo is not set)
endif
	rm -rf /tmp/ansible; mkdir /tmp/ansible
	${PODMAN_RUN} \
	  ${ANSIBLE_MOUNT_OPTS} \
	  -v $(shell pwd)/clusters/${CLUSTER}:/cluster \
	  -v $(shell pwd)/pull_secret.json:/opt/app-root/src/pull-secret.txt \
	  -v /tmp/ansible:/opt/app-root/src/.ansible \
	  ${ADDITIONAL_PARAMS} \
	  -ti ${ANSIBLE_IMAGE}

scaleup-shell: check ## Run shell in scaleup image
	rm -rf /tmp/ansible; mkdir /tmp/ansible
	${PODMAN_RUN} \
	  ${ANSIBLE_MOUNT_OPTS} \
	  -v $(shell pwd)/clusters/${CLUSTER}:/cluster \
	  -v $(shell pwd)/pull_secret.json:/cluster/pull_secret.json \
	  -v /tmp/ansible:/opt/app-root/src/ \
	  ${ADDITIONAL_PARAMS} \
	  --entrypoint=sh \
	  -ti ${ANSIBLE_IMAGE}

pull-tests: ## Pull test image
	${PODMAN} pull ${TESTS_IMAGE}

tests: ## Run openshift tests
	rm -rf test-artifacts/
	mkdir test-artifacts
	${PODMAN_RUN} \
	  ${ANSIBLE_MOUNT_OPTS} \
	  -v $(shell pwd)/ssh-privatekey:/root/ssh-privatekey \
	  -v $(shell pwd)/test-artifacts:/tmp/artifacts \
	  -v $(shell pwd)/.aws/credentials:/tmp/artifacts/installer/.aws/credentials \
	  -v $(shell pwd)/clusters/${CLUSTER}/auth:/tmp/artifacts/installer/auth${MOUNT_FLAGS} \
		-e KUBECONFIG=/tmp/artifacts/installer/auth/kubeconfig \
		-e KUBE_SSH_KEY_PATH=/root/ssh-privatekey \
		-e AWS_SHARED_CREDENTIALS_FILE=/tmp/artifacts/installer/.aws/credentials \
		-e CLUSTER_NAME=${CLUSTER} \
		-e BASE_DOMAIN=${BASE_DOMAIN} \
	  --entrypoint=/bin/bash \
	  -ti ${TESTS_IMAGE}

tests-restore-snapshot:
	rm -rf test-artifacts/
	mkdir test-artifacts
	${PODMAN_RUN} \
		${ANSIBLE_MOUNT_OPTS} \
		-v $(shell pwd)/ssh-privatekey:/root/ssh-privatekey \
		-v $(shell pwd)/test-artifacts:/tmp/artifacts \
		-v $(shell pwd)/.aws/credentials:/tmp/artifacts/installer/.aws/credentials \
		-v $(shell pwd)/clusters/${CLUSTER}/auth:/tmp/artifacts/installer/auth${MOUNT_FLAGS} \
		-v $(shell pwd)/tests/restore-snapshot.sh:/usr/local/bin/restore-snapshot.sh \
		-v /home/vrutkovs/go/src/github.com/openshift/origin/_output/local/bin/linux/amd64/openshift-tests:/usr/bin/openshift-tests \
		-e KUBECONFIG=/tmp/artifacts/installer/auth/kubeconfig \
		-e KUBE_SSH_KEY_PATH=/root/ssh-privatekey \
		-e AWS_SHARED_CREDENTIALS_FILE=/tmp/artifacts/installer/.aws/credentials \
		-e CLUSTER_NAME=${CLUSTER} \
		-e BASE_DOMAIN=${BASE_DOMAIN} \
		-ti ${TESTS_IMAGE} \
		/usr/local/bin/restore-snapshot.sh

tests-quorum-restore:
	rm -rf test-artifacts/
	mkdir test-artifacts
	${PODMAN_RUN} \
		${ANSIBLE_MOUNT_OPTS} \
		-v $(shell pwd)/ssh-privatekey:/root/ssh-privatekey \
		-v $(shell pwd)/test-artifacts:/tmp/artifacts \
		-v $(shell pwd)/.aws/credentials:/tmp/artifacts/installer/.aws/credentials \
		-v $(shell pwd)/clusters/${CLUSTER}/auth:/tmp/artifacts/installer/auth${MOUNT_FLAGS} \
		-v $(shell pwd)/tests/quorum-restore.sh:/usr/local/bin/quorum-restore.sh \
		-v /home/vrutkovs/go/src/github.com/openshift/origin/_output/local/bin/linux/amd64/openshift-tests:/usr/bin/openshift-tests \
		-e KUBECONFIG=/tmp/artifacts/installer/auth/kubeconfig \
		-e KUBE_SSH_KEY_PATH=/root/ssh-privatekey \
		-e AWS_SHARED_CREDENTIALS_FILE=/tmp/artifacts/installer/.aws/credentials \
		-e CLUSTER_NAME=${CLUSTER} \
		-e BASE_DOMAIN=${BASE_DOMAIN} \
		-ti ${TESTS_IMAGE} \
		/usr/local/bin/quorum-restore.sh

.PHONY: all $(MAKECMDGOALS)
