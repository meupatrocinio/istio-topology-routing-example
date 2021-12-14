# Istio Topology based routing example

This respoistory contains the examples to do topology based routing as specified in the blog <<link to the blog>>. 
There is "app" folder which contains code to build the app and "k8s" module which contains Kubenetes spec files to deploy to run the examples. Ensure that while following the instructions **<<>>** are replaced with the right value. For example **<<<<replace_with_account_id>>>** should be replaced with the relevant account number.
## Pre-requistes
### 1. Build and publish the example app
First step is build the clone the application code and create and ecr repository and login to the repository
```shell 
git clone https://github.com/mahasiva-amazon/istio-topology-routing-example.git
aws ecr create-repository --repository-name istio-tpr-app --image-scanning-configuration scanOnPush=true
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin <<replace_with_account_id>>.dkr.ecr.us-west-2.amazonaws.com
```
Next step is to build the app
```shell
cd app
docker build -t istio-tpr-app .
docker tag istio-tpr-app:latest <<replace_with_account_id>>.dkr.ecr.us-west-2.amazonaws.com/istio-tpr-app:v1.0.0
docker push <<replace_with_account_id>>.dkr.ecr.us-west-2.amazonaws.com/istio-tpr-app:v1.0.0
```
Now the app is built and published to the ecr repository. 

### 2. Build the eks cluster and install Istio
First step is to create a EKS cluster to perform data analysis
```shell
cd infra
eksctl create cluster -f eksdtoanalysis.yaml
```
Next, we need to enable VPC Flow Logs for the cluster VPC. The flow logs can be used to analyze which type of traffic results in data transfers costs through CloudWatch dashboards
```shell
export CLUSTER_VPC_ID=($(aws ec2 describe-vpcs --region us-west-2  --filters Name="tag:alpha.eksctl.io/cluster-name",Values=dto-analysis-k8scluster | jq -r '.Vpcs[].VpcId'))
export FL_ROLE_ID=($(aws iam create-role --role-name dtoanalysis-fllogs-role --assume-role-policy-document file://flowlogstrustpolicy.json | jq -r '.Role.Arn'))
aws iam put-role-policy --role-name dtoanalysis-fllogs-role --policy-name allow.flowlogs.cloudwatch --policy-document file://allow-cloudwatch-flowlogs.json
aws ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids ${CLUSTER_VPC_ID} \
    --traffic-type ALL \
    --deliver-logs-permission-arn ${FL_ROLE_ID} \
    --log-destination-type cloud-watch-logs \
    --log-destination  'arn:aws:logs:us-west-2:<<replace_with_account_id>>:log-group:dto-dto-analysis-k8scluster-logs' \
    --log-format '${account-id} ${action} ${az-id} ${bytes} ${dstaddr} ${end} ${dstport} ${flow-direction} ${instance-id} ${interface-id} ${log-status} ${packets} ${pkt-dst-aws-service} ${pkt-dstaddr} ${pkt-srcaddr} ${pkt-src-aws-service} ${protocol} ${region} ${srcaddr} ${srcport} ${start} ${sublocation-id} ${sublocation-type} ${subnet-id} ${traffic-path} ${tcp-flags} ${type} ${version} ${vpc-id}'
./create-dashboard.sh us-west-2 "alpha.eksctl.io/cluster-name" "dto-analysis-k8scluster" dto-analysis-k8scluster dto-dto-analysis-k8scluster-logs dto-analysis-k8scluster-dashboard
```
Next we install Istio ingress controller, ingress and egress gateways
```shell
export ISTIO_VERSION="1.10.0"
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
cd istio-${ISTIO_VERSION}
sudo cp -v bin/istioctl /usr/local/bin/
istioctl version --remote=false
yes | istioctl install --set profile=demo
eksctl utils associate-iam-oidc-provider --cluster=dto-analysis-k8scluster --approve
```
Finally we install the app without istio
```shell
APP_POLICY_ARN=`aws iam create-policy --policy-name AppAccessPolicy --policy-document file://msk-cluster-policy.json | jq -r ".Policy.Arn"`
eksctl create iamserviceaccount --cluster=dto-analysis-k8scluster --name=mscrudallow --namespace=octank-travel-ns --attach-policy-arn=$APP_POLICY_ARN --approve
```

