# cisco_ocp

DEPLOY ARGOCD \
BOOTSTRAP_REPO_URL="https://github.com/madun0/cisco_ocp.git" \
BOOTSTRAP_REPO_BRANCH="main" \
BOOTSTRAP_REPO_PATH="bootstrap" \
./deploy-argocd.sh

DESTROY ARGOCD \
DELETE_OPERATOR_NAMESPACE=true DELETE_ARGOCD_NAMESPACE=true ./destroy-argocd.sh

