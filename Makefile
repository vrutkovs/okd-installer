BASE_DOMAIN=devcluster.openshift.com
MOUNT_FLAGS=
PODMAN=podman
DIR=output
PODMAN_RUN=${PODMAN} run --privileged --rm -v $(shell pwd)/${DIR}:/${DIR}${MOUNT_FLAGS} --user $(shell id -u):$(shell id -u)
PODMAN_TF=${PODMAN} run --privileged --rm -v $(shell pwd)/${TF_DIR}:/${TF_DIR}${MOUNT_FLAGS} --user $(shell id -u):$(shell id -u) --workdir=/${TF_DIR}
INSTALLER_IMAGE=registry.svc.ci.openshift.org/openshift/origin-v4.0:installer
ANSIBLE_IMAGE=registry.svc.ci.openshift.org/openshift/origin-v4.0:ansible
TERRAFORM_IMAGE=hashicorp/terraform:0.11.13
TF_DIR=tf
CLI_IMAGE=registry.svc.ci.openshift.org/openshift/origin-v4.0:cli
ADDITIONAL_PARAMS=  -e OPTS="-vvv" \
					-e PLAYBOOK_FILE=test/aws/scaleup.yml \
					-e INVENTORY_DIR=/usr/share/ansible/openshift-ansible/inventory/dynamic/aws
PYTHON=/usr/bin/python3
OFFICIAL_RELEASE=
ifneq ("$(OFFICIAL_RELEASE)","")
	RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.0.0-0.7
endif
LATEST_RELEASE=
ifneq ("$(LATEST_RELEASE)","")
	RELEASE_IMAGE=registry.svc.ci.openshift.org/openshift/origin-release:v4.0
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
ifndef USERNAME
	$(error USERNAME env var is not set)
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
	sudo rm -rf ${DIR}/* || true

pull-installer: ## Pull fresh installer image
	#${PODMAN} pull ${INSTALLER_IMAGE}

aws: check pull-installer ## Create AWS cluster
	${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	env BASE_DOMAIN=${BASE_DOMAIN} ansible all -i "localhost," --connection=local -e "ansible_python_interpreter=${PYTHON}" \
	  -m template -a "src=install-config.aws.yaml.j2 dest=${DIR}/install-config.yaml"
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} create cluster --log-level debug --dir /${DIR}

vmware: check pull-installer ## Create AWS cluster
	# ${PODMAN_RUN} -ti ${INSTALLER_IMAGE} version
	# env BASE_DOMAIN=${BASE_DOMAIN} ansible all -i "localhost," --connection=local -e "ansible_python_interpreter=${PYTHON}" \
	#   -m template -a "src=install-config.vsphere.yaml.j2 dest=${DIR}/install-config.yaml"
	# ${PODMAN_RUN} ${INSTALLER_PARAMS} \
	#   -ti ${INSTALLER_IMAGE} create ignition-configs --log-level debug --dir /${DIR}
	#env DIR=${DIR} TF_DIR=${TF_DIR} sh 01_generate_tfvars.sh
	${PODMAN_TF} -ti ${TERRAFORM_IMAGE} init
	${PODMAN_TF} \
		-v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
		-e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
		-e AWS_DEFAULT_REGION=us-east-1 \
		-ti ${TERRAFORM_IMAGE} apply -auto-approve

destroy: ## Destroy AWS cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster --log-level debug --dir /${DIR}
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
	sudo rm -rf /tmp/ansible; mkdir /tmp/ansible
	${PODMAN_RUN} \
	  ${ANSIBLE_MOUNT_OPTS} \
	  -v $(shell pwd)/${DIR}:/cluster \
	  -v $(shell pwd)/pull_secret.json:/opt/app-root/src/pull-secret.txt \
	  -v /tmp/ansible:/opt/app-root/src/.ansible \
	  ${ADDITIONAL_PARAMS} \
	  -ti ${ANSIBLE_IMAGE} 

scaleup-shell: check ## Run shell in scaleup image
	sudo rm -rf /tmp/ansible; mkdir /tmp/ansible
	${PODMAN_RUN} \
	  ${ANSIBLE_MOUNT_OPTS} \
	  -v $(shell pwd)/${DIR}:/cluster \
	  -v $(shell pwd)/pull_secret.json:/cluster/pull_secret.json \
	  -v /tmp/ansible:/opt/app-root/src/ \
	  ${ADDITIONAL_PARAMS} \
	  --entrypoint=sh \
	  -ti ${ANSIBLE_IMAGE} 

cleanup-centos-machines-in-scaleup: ## DEBUG - remove stray centos machinesets
	oc --config ${DIR}/auth/kubeconfig -n openshift-machine-api get machinesets -o name | grep centos \
	| xargs -n1 oc --config ${DIR}/auth/kubeconfig -n openshift-machine-api delete

pull-tests: ## Pull test image
	${PODMAN} pull registry.svc.ci.openshift.org/openshift/origin-v4.0:tests

test: ## Run openshift tests
	rm -rf test-artifacts/
	mkdir test-artifacts
	${PODMAN_RUN} \
	  ${ANSIBLE_MOUNT_OPTS} \
	  -v $(shell pwd)/auth:/auth${MOUNT_FLAGS} \
	  -v $(shell pwd)/test.sh:/usr/bin/test.sh \
	  -v $(shell pwd)/test-artifacts:/tmp/artifacts \
	  -v ~/.ssh:/usr/share/ansible/openshift-ansible/.ssh \
	  ${ADDITIONAL_PARAMS} \
	  --entrypoint=/bin/sh \
	  -ti registry.svc.ci.openshift.org/openshift/origin-v4.0:tests \
	  /usr/bin/test.sh
