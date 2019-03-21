BASE_DOMAIN=devcluster.openshift.com
MOUNT_FLAGS=
PODMAN=podman
DIR=output
PODMAN_RUN=${PODMAN} run --privileged --rm -v $(shell pwd)/${DIR}:/${DIR}${MOUNT_FLAGS} --user $(shell id -u):$(shell id -u)
INSTALLER_IMAGE=registry.svc.ci.openshift.org/openshift/origin-v4.0:installer
ANSIBLE_IMAGE=registry.svc.ci.openshift.org/openshift/origin-v4.0:ansible
ADDITIONAL_PARAMS=-e INSTANCE_PREFIX="${USERNAME}" -e OPTS="-vvv -e openshift_install_config_path=/tmp/install-config.ansible.yaml"
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
	rm -rvf install-config.yaml install-config.copy.yaml .openshift_install_state.json .openshift_install.log *.ign || true

pull-installer: ## Pull fresh installer image
	${PODMAN} pull ${INSTALLER_IMAGE}

aws: check pull-installer ## Create AWS cluster
	${PODMAN_RUN} --rm -ti ${INSTALLER_IMAGE} version
	env BASE_DOMAIN=${BASE_DOMAIN} ansible all -i "localhost," --connection=local -e "ansible_python_interpreter=${PYTHON}" \
	  -m template -a "src=install-config.yaml.j2 dest=${DIR}/install-config.yaml"
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} create cluster --log-level debug --dir /${DIR}

destroy: ## Destroy AWS cluster
	${PODMAN_RUN} ${INSTALLER_PARAMS} \
	  -e AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials \
	  -v $(shell pwd)/.aws/credentials:/tmp/.aws/credentials${MOUNT_FLAGS} \
	  -ti ${INSTALLER_IMAGE} destroy cluster --log-level debug
	make cleanup
	rm -rf terraform.tfstate terraform.tfvars tls/ metadata.json

shell: ## Open a shell in openshift-ansible container
	ADDITIONAL_PARAMS+=--entrypoint=/bin/sh
	make provision

pull-ansible-image: ## Pull latest openshift-ansible container
	${PODMAN} pull ${ANSIBLE_IMAGE}

scaleup: check ## Scaleup AWS workers
	${PODMAN_RUN} \
	  ${ANSIBLE_MOUNT_OPTS} \
	  -v $(shell pwd)/root/usr/local/bin:/usr/local/bin${MOUNT_FLAGS} \
	  -v $(shell pwd)/injected:/usr/share/ansible/openshift-ansible/inventory/dynamic/injected${MOUNT_FLAGS} \
	  -v ~/.ssh:/usr/share/ansible/openshift-ansible/.ssh \
	  -v $(shell pwd)/auth:/auth${MOUNT_FLAGS} \
	  ${ADDITIONAL_PARAMS} \
	  -ti ${ANSIBLE_IMAGE}

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
