#!/bin/bash

DOMAIN=$1

source ./utils.sh


if [[ -z "${JENKINS_USER}" ]]; then
  print_debug "JENKINS_USER not set, take it from creds.json"
  JENKINS_USER=$(cat creds.json | jq -r '.jenkinsUser')
  verify_variable "$JENKINS_USER" "JENKINS_USER is not defined in environment variable nor in creds.json file." 
fi

if [[ -z "${JENKINS_PASSWORD}" ]]; then
  print_debug "JENKINS_PASSWORD not set, take it from creds.json"
  JENKINS_PASSWORD=$(cat creds.json | jq -r '.jenkinsPassword')
  verify_variable "$JENKINS_PASSWORD" "JENKINS_PASSWORD is not defined in environment variable nor in creds.json file." 
fi

if [[ -z "${GITHUB_USER_NAME}" ]]; then
  print_debug "GITHUB_USER_NAME not set, take it from creds.json"
  GITHUB_USER_NAME=$(cat creds.json | jq -r '.githubUserName')
  verify_variable "$GITHUB_USER_NAME" "GITHUB_USER_NAME is not defined in environment variable nor in creds.json file." 
fi

if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN}" ]]; then
  print_debug "GITHUB_PERSONAL_ACCESS_TOKEN not set, take it from creds.json"
  GITHUB_PERSONAL_ACCESS_TOKEN=$(cat creds.json | jq -r '.githubPersonalAccessToken')
  verify_variable "$GITHUB_PERSONAL_ACCESS_TOKEN" "GITHUB_PERSONAL_ACCESS_TOKEN is not defined in environment variable nor in creds.json file." 
fi

if [[ -z "${GITHUB_USER_EMAIL}" ]]; then
  print_debug "GITHUB_USER_EMAIL not set, take it from creds.json"
  GITHUB_USER_EMAIL=$(cat creds.json | jq -r '.githubUserEmail')
  verify_variable "$GITHUB_USER_EMAIL" "GITHUB_USER_EMAIL is not defined in environment variable nor in creds.json file." 
fi

if [[ -z "${GITHUB_ORGANIZATION}" ]]; then
  print_debug "GITHUB_ORGANIZATION not set, take it from creds.json"
  GITHUB_ORGANIZATION=$(cat creds.json | jq -r '.githubOrg')
  verify_variable "$GITHUB_ORGANIZATION" "GITHUB_USER_EMAIL is not defined in environment variable nor in creds.json file." 
fi

# Configure knative serving default domain
rm -f ../manifests/gen/config-domain.yaml

cat ../manifests/knative/config-domain.yaml | \
  sed 's~DOMAIN_PLACEHOLDER~'"$DOMAIN"'~' >> ../manifests/gen/config-domain.yaml

kubectl apply -f ../manifests/gen/config-domain.yaml
verify_kubectl $? "Creating configmap config-domain in knative-serving namespace failed."


kubectl delete secret -n istio-system istio-ingressgateway-certs

# Set up SSL, PKS custom
cat <<EOF > minissl.conf
[ req ]
distinguished_name = req_dn
x509_extensions = v3_ext
[ req_dn ]
[ v3_ext ]
basicConstraints = CA:true
subjectAltName          = @alternate_names
[ alternate_names ]
DNS.1       = $DOMAIN
DNS.2       = *.$DOMAIN
EOF
openssl req -nodes -newkey rsa:2048 -keyout key.pem -out certificate.pem  -x509 -days 365 -extensions v3_ext -config minissl.conf -subj "/C=US/ST=IL/O=None"
kubectl create --namespace istio-system secret tls istio-ingressgateway-certs --key key.pem --cert certificate.pem

#verify_kubectl $? "Creating secret for istio-ingressgateway-certs failed."

kubectl get gateway knative-ingress-gateway --namespace knative-serving -o=yaml | yq w - spec.servers[1].tls.mode SIMPLE | yq w - spec.servers[1].tls.privateKey /etc/istio/ingressgateway-certs/tls.key | yq w - spec.servers[1].tls.serverCertificate /etc/istio/ingressgateway-certs/tls.crt | kubectl apply -f -
verify_kubectl $? "Updating knative ingress gateway with private key failed."


rm key.pem
rm certificate.pem

# Add config map in keptn namespace that contains the domain - this will be used by other services as well
rm -f ../manifests/gen/keptn-domain-configmap.yaml

cat ../manifests/keptn/keptn-domain-configmap.yaml | \
  sed 's~DOMAIN_PLACEHOLDER~'"$DOMAIN"'~' >> ../manifests/gen/keptn-domain-configmap.yaml

kubectl apply -f ../manifests/gen/keptn-domain-configmap.yaml
verify_kubectl $? "Creating configmap keptn-domain in keptn namespace failed."

git clone --branch feature/283/xip-replacement https://github.com/keptn/jenkins-service.git --single-branch
cd jenkins-service
chmod +x deploy.sh
./deploy.sh "" $JENKINS_USER $JENKINS_PASSWORD $GITHUB_USER_NAME $GITHUB_USER_EMAIL $GITHUB_ORGANIZATION $GITHUB_PERSONAL_ACCESS_TOKEN


# redeploy github service
rm github-service.yaml
wget -q -O - https://raw.githubusercontent.com/keptn/github-service/feature/283/xip-replacement/config/service.yaml | yq w - spec.runLatest.configuration.revisionTemplate.spec.container keptn/github-service:feature.283.20190522.0928 >> github-service.yaml

kubectl delete -f github-service.yaml
kubectl apply -f github-service.yaml
