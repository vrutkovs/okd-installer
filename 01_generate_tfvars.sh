# Upload bootstrap ignition
export BOOTSTRAP_URL=$(cat ${DIR}/bootstrap.ign | curl -F 'sprunge=<-' http://sprunge.us)
export MASTER_IGN=$(cat ${DIR}/master.ign)
export WORKER_IGN=$(cat ${DIR}/worker.ign)

cat terraform.tfvars.template | envsubst > ${TF_DIR}/terraform.tfvars
