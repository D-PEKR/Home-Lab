INVENTORY := ansible/inventory/hosts.yml
PLAYBOOK  := ansible/site.yml

.PHONY: install check ping deps lint cluster-info argocd-password vault-encrypt

## Vollständige Installation
install: deps
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --ask-vault-pass

## Dry-Run
check: deps
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --ask-vault-pass --check

## Nur Common + Storage im Check-Mode (zuverlässiger als voller Check)
check-base: deps
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --ask-vault-pass --check --tags common,storage

## Connectivity-Test
ping:
	ansible -i $(INVENTORY) k3s_cluster -m ping

## Galaxy-Collections installieren
deps:
	ansible-galaxy collection install -r ansible/requirements.yml

## Lint
lint:
	ansible-lint ansible/

## Cluster-Status
cluster-info:
	kubectl get nodes -o wide
	kubectl get pods --all-namespaces | grep -v Running | grep -v Completed || true
	kubectl -n argocd get applications

## ArgoCD Passwort
argocd-password:
	kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

## Vault Secret erstellen
vault-encrypt:
	@read -p "Variable name: " NAME; \
	 read -s -p "Value: " VAL; echo; \
	 ansible-vault encrypt_string "$$VAL" --name "$$NAME"

## k3s Token generieren und verschlüsseln
vault-k3s-token:
	ansible-vault encrypt_string "$$(openssl rand -hex 32)" --name 'k3s_token'
