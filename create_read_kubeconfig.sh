# 1. Get the Token
TOKEN=$(kubectl get secret ai-debugger-token -n debug-access-ns -o jsonpath='{.data.token}' | base64 --decode)
# 2. Get the Cluster CA Certificate
CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
# 3. Get the API Server URL
SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
# 4. Write the kubeconfig file
cat <<EOF > ~/.kube/readonly-config.yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA
    server: $SERVER
  name: secure-cluster
contexts:
- context:
    cluster: secure-cluster
    user: ai-debugger
  name: secure-context
current-context: secure-context
users:
- name: ai-debugger
  user:
    token: $TOKEN
EOF
echo "File '~/.kube/readonly-config.yaml' created successfully."
