#!/bin/sh

# Create own terraform.tfvars
cat <<EOF > terraform.tfvars
gcp_project_id = "$(gcloud config list project \
 --format='value(core.project)')"
gcp_region = "REGION"
EOF

# Initialize Terraform:
terraform init

# Deploy the stack:
terraform apply -auto-approve

# Store Redis Enterprise database information in environment variables:
export REDIS_DEST=`terraform output db_private_endpoint | tr -d '"'`
export REDIS_DEST_PASS=`terraform output db_password | tr -d '"'`
export REDIS_ENDPOINT="${REDIS_DEST},user=default,password=${REDIS_DEST_PASS}"

# Target the environment to GKE cluster:
gcloud container clusters get-credentials \
$(terraform output -raw gke_cluster_name) \
--region $(terraform output -raw region)

# Get the External-IP from the web application (in the redis namespace)
kubectl get service frontend-external -n redis


## Migrate the shopping cart data from OSS Redis to Redis Enterprise using RIOT, Redis Input and Output Tool

# Set to redis namespace:
kubectl config set-context --current --namespace=redis

# Show the current pointer for the cartservice (pointing to OSS Redis)
kubectl get deployment cartservice -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

# Create a Kubernetes secret for the Redis Enterprise database connection:
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: redis-creds
type: Opaque
stringData:
  REDIS_SOURCE: redis://redis-cart:6379
  REDIS_DEST: redis://${REDIS_DEST}
  REDIS_DEST_PASS: ${REDIS_DEST_PASS}
EOF

# Run a Kubernetes job to migrate data from OSS Redis to Redis Enterprise database (should take about 15 seconds or so):
kubectl apply -f https://raw.githubusercontent.com/Redislabs-Solution-Architects/gcp-microservices-demo-qwiklabs/main/util/redis-migrator-job.yaml

# Show the current pointer for the cartservice
kubectl get deployment cartservice -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

# Run a Kubernetes patch command below to update the cartservice deployment to point to the new Redis Enterprise database endpoint (30 seconds):
# Apply Kubernetes patch command to the cartservice
kubectl patch deployment cartservice --patch '{"spec":{"template":{"spec":{"containers":[{"name":"server","env":[{"name":"REDIS_ADDR","value":"'$REDIS_ENDPOINT'"}]}]}}}}'

# Show the new pointer for the cartservice (pointing to OSS Redis)
kubectl get deployment cartservice -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

# Verify if the same items remain in the shopping cart are now backed by the Redis Enterprise database by refreshing the browser & accessing the shopping cart content again. The same items should appear in the shopping cart. Then add a few items to the shopping cart in order to verify the online boutique web application is successfully pointing to the Redis Enterprise database.


## Roll back to the OSS Redis to back the shopping cart content

# Configure the shopping cart to use OSS Redis again (30 seconds):
kubectl patch deployment cartservice --patch '{"spec":{"template":{"spec":{"containers":[{"name":"server","env":[{"name":"REDIS_ADDR","value":"redis-cart:6379"}]}]}}}}'

# Verify that the service has been pointed to the OSS Redis instance
kubectl get deployment cartservice -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

# Refresh the browser & access the shopping cart content. Should not see the new items which are added earlier when Redis Enterprise is backing the shopping cart content. It is because the new items added to the shopping cart backed by the Redis Enterprise database is not replicated to the Redis OSS instance.


## Patch the "Cart" deployment to point to the Redis Enterprise Database again for production

# Run a K8s patch command to update the cartservice deployment to point to the Redis Enterprise Endpoint (30 seconds):
kubectl patch deployment cartservice --patch '{"spec":{"template":{"spec":{"containers":[{"name":"server","env":[{"name":"REDIS_ADDR","value":"'$REDIS_ENDPOINT'"}]}]}}}}'

# Verify that the service has been pointed to the Redis Enterprise
kubectl get deployment cartservice -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

# Refresh the browser and access the shopping cart content. Should see the items which are added earlier. Now that everything is working and the items are still in user's cart.

# Delete the OSS Redis deployment as follows:
# kubectl delete deploy redis-cart

