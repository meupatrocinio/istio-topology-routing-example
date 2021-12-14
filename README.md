# Istio Topology based routing example

This respoistory contains the examples to do topology based routing as specified in the blog <<link to the blog>>. 
There is "app" folder which contains code to build the app and "k8s" module which contains Kubenetes spec files to deploy to run the examples. Ensure that while following the instructions **<<>>** are replaced with the right value. For example **<<replace_with_account_id>>** should be replaced with the relevant account number.
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

### 2. Build the eks cluster,install Istio and the sample application

#### a. Create a EKS cluster to perform data analysis
```shell
cd infra
eksctl create cluster -f eksdtoanalysis.yaml

```

#### b. Enable VPC Flow Logs for the cluster VPC and install CloudWatch dashboards
The flow logs can be used to analyze which type of traffic results in data transfers costs through CloudWatch dashboards
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

#### c. Install Istio controller, ingress and egress gateways
```shell
export ISTIO_VERSION="1.10.0"
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
cd istio-${ISTIO_VERSION}
sudo cp -v bin/istioctl /usr/local/bin/
istioctl version --remote=false
yes | istioctl install --set profile=demo

```

#### d. Create service account with necessary permissions
```shell
eksctl utils associate-iam-oidc-provider --cluster=dto-analysis-k8scluster --approve
APP_POLICY_ARN=`aws iam create-policy --policy-name AppAccessPolicy --policy-document file://msk-cluster-policy.json | jq -r ".Policy.Arn"`
eksctl create iamserviceaccount --cluster=dto-analysis-k8scluster --name=mscrudallow --namespace=octank-travel-ns --attach-policy-arn=$APP_POLICY_ARN --approve

```

#### e. Install the test container
```shell
kubectl run curl-debug --image=radial/busyboxplus:curl -l "type=testcontainer" -n octank-travel-ns -it --tty  sh
#Run curl command in the test container to see which AZ the test container is running in
curl -s 169.254.169.254/latest/meta-data/placement/availability-zone
#exit the test container
exit
#expose a service for the test container
kubectl expose deploy curl-debug -n octank-travel-ns --port=80 --target-port=8000
```

#### f. Install the app. 
Make sure to replace the **<<replace_with_account_id>>** in the deployment.yaml with relevant account number
```shell
kubectl apply -f namespace.yaml
kubectl apply -f deployment.yaml
kubectl apply -f services.yaml

```

#### g. Write a startup script in the test container
```shell
kubectl exec -it --tty -n octank-travel-ns $(kubectl get pod -l "type=testcontainer" -n octank-travel-ns -o jsonpath='{.items[0].metadata.name}') sh
#create a startup script
cat <<EOF>> test.sh
n=1
while [ \$n -le 5 ]
do
     curl -s zip-lookup-service-local.octank-travel-ns
     sleep 1
     echo "---"
     n=\$(( n+1 ))
done
EOF
chmod +x test.sh
clear
./test.sh
#exit the test container
exit

```
You should see the lines similar to the ones below displayed in the console.
```shell
CA - 94582 az - us-west-2b---
CA - 94582 az - us-west-2a---
CA - 94582 az - us-west-2b---
CA - 94582 az - us-west-2a---
CA - 94582 az - us-west-2b---
```
As you could see from the output of running the test script that calls from the test container are returning to the "zip-lookup-service" pods running in multiple AZs. This will result in inter-AZ data transfer costs

### 3. Using Istio to avoid inter-AZ data transfers costs for inter-cluster traffic

In order to control inter-AZ data transfer costs for inter cluster traffic, we need to enable topology aware routing within Istio. Topology aware routing is  supported out of the box in Istio for Pod egress traffic, all that is needed is to create a destination rule object and associate it with the relevant service. Let us walk through an example of using Istio to control inter-AZ traffic

#### a. Enable injection of side car containers for the namespace

Update the namespace.yaml to add the label "istio-injection: enabled"

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: octank-travel-ns
  labels:
    istio-injection: enabled
```

Next apply the changes to the namespace. This will not impact existing Pods that are already running, hence scale down the deployment to zero and then scale up.

```shell
kubectl apply -f namespace.yaml
kubectl get po -n octank-travel-ns

```

The console should be should be similar to below

```shell
zip-lookup-service-deployment-645d5c8df5-4nbfp   1/1     Running   0          136m
zip-lookup-service-deployment-645d5c8df5-mnpgs   1/1     Running   0          136m
zip-lookup-service-deployment-645d5c8df5-vvnh4   1/1     Running   0          136m
```

The number of containers per pod is "1", hence let us scale down the deployment and then scale it up.

```shell
kubectl get deploy -n octank-travel-ns
kubectl scale deploy zip-lookup-service-deployment -n octank-travel-ns --replicas=0
kubectl scale deploy zip-lookup-service-deployment -n octank-travel-ns --replicas=3
kubectl get po -n octank-travel-ns

```

The console should be should be similar to below

```shell
zip-lookup-service-deployment-645d5c8df5-rm6pb   2/2     Running   0          3m37s
zip-lookup-service-deployment-645d5c8df5-t5dr7   2/2     Running   0          3m37s
zip-lookup-service-deployment-645d5c8df5-tt92m   2/2     Running   0          3m37s
```
The number of containers per pod is "2" as the side cars have been injected.

#### b. Enable topology aware routing 

To enable topology aware routing, we need to create a destination rule and link it to the zip-lookup-service-local

```shell
kubectl apply -f destinationrule.yaml
```

Let us log back into the test container to validate 

```shell
kubectl exec -it --tty -n octank-travel-ns $(kubectl get pod -l "type=testcontainer" -n octank-travel-ns -o jsonpath='{.items[0].metadata.name}') sh
```

Run the following commands in the test container

```shell
curl -s 169.254.169.254/latest/meta-data/placement/availability-zone
./test.sh
```

The console output should be as follows

```shell
```

As you could see, the calls are going to the Pods in the same AZ whereas earlier the calls were distributed across multiple AZs where the pods were running. This means that topology aware routing is sucessful for Pod to Pod communication and will result in **significant** cost saves in terms data transfer costs.

### 3. Using Istio to avoid inter-AZ data transfers costs for calls to AWS services
