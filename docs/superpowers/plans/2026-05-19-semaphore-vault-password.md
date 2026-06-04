# Semaphore Vault Password Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Ansible Vault password into Semaphore so playbooks can decrypt vault-encrypted variables when triggered from the UI.

**Architecture:** A `login_password` key (named `vault-password`) is provisioned per project via the Semaphore REST API and referenced on every template via `vault_key_id`. The password itself is stored vault-encrypted in `group_vars/all.yml` and decrypted at bootstrap time.

**Tech Stack:** Ansible, Semaphore REST API, Ansible Vault, yamllint, ansible-lint

---

## Files

| Action | Path |
|--------|------|
| Modify | `ansible/roles/semaphore_bootstrap/defaults/main.yml` |
| Modify | `ansible/roles/semaphore_bootstrap/tasks/key.yml` |
| Modify | `ansible/roles/semaphore_bootstrap/tasks/template.yml` |
| Modify (manual) | `ansible/group_vars/all.yml` — user adds `semaphore_vault_password` |

---

## Task 1: Add `semaphore_vault_password` to group_vars

**Files:**
- Modify: `ansible/group_vars/all.yml`

- [ ] **Step 1: Encrypt the vault password**

Run this on your local machine (replace `YOUR-VAULT-PASSWORD` with the actual password):
```bash
cd ansible
ansible-vault encrypt_string 'YOUR-VAULT-PASSWORD' --name 'semaphore_vault_password'
```
Expected output:
```
semaphore_vault_password: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          38623865...
```

- [ ] **Step 2: Add to group_vars**

Open the vars file and paste the output at the end of the semaphore section:
```bash
make vault-edit
```
Add the encrypted block produced in step 1. Save and close.

- [ ] **Step 3: Verify the variable decrypts correctly**

```bash
cd ansible
ansible -i inventory/hosts.yml homeserver \
  -m debug -a "var=semaphore_vault_password" \
  --ask-vault-pass
```
Expected: the plaintext password appears as `semaphore_vault_password: YOUR-VAULT-PASSWORD`

---

## Task 2: Add `vault-password` key to `semaphore_default_keys`

**Files:**
- Modify: `ansible/roles/semaphore_bootstrap/defaults/main.yml:31-36`

- [ ] **Step 1: Add the third key entry**

In `ansible/roles/semaphore_bootstrap/defaults/main.yml`, replace:
```yaml
# Two access keys are created in every project — name them once here.
# `login` is only relevant for the ssh-type entry.
semaphore_default_keys:
  - name: semaphore-ssh-key
    type: ssh
    login: jaydee
  - name: git-none
    type: none
```
with:
```yaml
# Three access keys are created in every project — name them once here.
# `login` is only relevant for the ssh-type entry.
semaphore_default_keys:
  - name: semaphore-ssh-key
    type: ssh
    login: jaydee
  - name: git-none
    type: none
  - name: vault-password
    type: login_password
```

- [ ] **Step 2: Add `vault_key` to both templates**

Still in `ansible/roles/semaphore_bootstrap/defaults/main.yml`, replace:
```yaml
    templates:
      - name: "Deploy Home Server"
        playbook: ansible/site.yml
        inventory: homeservers
        description: "Run the full site.yml against the home-server (recursive)."
```
with:
```yaml
    templates:
      - name: "Deploy Home Server"
        playbook: ansible/site.yml
        inventory: homeservers
        vault_key: vault-password
        description: "Run the full site.yml against the home-server (recursive)."
```

And replace:
```yaml
    templates:
      - name: "Deploy ugreen-paperless"
        playbook: ugreen-paperless.yml
        inventory: ugreen-nas
        description: "Provision Paperless-ngx stack on the UGREEN NAS."
```
with:
```yaml
    templates:
      - name: "Deploy ugreen-paperless"
        playbook: ugreen-paperless.yml
        inventory: ugreen-nas
        vault_key: vault-password
        description: "Provision Paperless-ngx stack on the UGREEN NAS."
```

- [ ] **Step 3: Lint**

```bash
cd ansible
yamllint roles/semaphore_bootstrap/defaults/main.yml
```
Expected: no output (no errors)

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/semaphore_bootstrap/defaults/main.yml
git commit -m "feat(semaphore): add vault-password key and wire to templates"
```

---

## Task 3: Implement `login_password` handler in `key.yml`

**Files:**
- Modify: `ansible/roles/semaphore_bootstrap/tasks/key.yml`

- [ ] **Step 1: Append the login_password tasks**

In `ansible/roles/semaphore_bootstrap/tasks/key.yml`, after the last line (`    - key_spec.type == "none"`), append:

```yaml

- name: Create login_password key in project {{ project_spec.name }}
  ansible.builtin.uri:
    url: "{{ semaphore_api_base }}/api/project/{{ project_id }}/keys"
    method: POST
    body_format: json
    body:
      name: "{{ key_spec.name }}"
      type: login_password
      project_id: "{{ project_id | int }}"
      login_password:
        login: ""
        password: "{{ semaphore_vault_password }}"
    headers:
      Cookie: "{{ semaphore_cookie }}"
    status_code: [200, 201, 204]
  no_log: true
  register: sem_vaultkey_create
  failed_when: false
  when:
    - not key_exists
    - key_spec.type == "login_password"

- name: Fail with HTTP details if vault key creation failed
  ansible.builtin.fail:
    msg: >-
      Vault key creation returned HTTP {{ sem_vaultkey_create.status }}:
      {{ sem_vaultkey_create.msg | default('no message') }}
  when:
    - not key_exists
    - key_spec.type == "login_password"
    - sem_vaultkey_create is not skipped
    - sem_vaultkey_create.status not in [200, 201, 204]
```

- [ ] **Step 2: Lint**

```bash
cd ansible
yamllint roles/semaphore_bootstrap/tasks/key.yml
ansible-lint roles/semaphore_bootstrap/tasks/key.yml
```
Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/semaphore_bootstrap/tasks/key.yml
git commit -m "feat(semaphore): handle login_password key type for vault password"
```

---

## Task 4: Add `vault_key_id` to template creation

**Files:**
- Modify: `ansible/roles/semaphore_bootstrap/tasks/template.yml:28-41`

- [ ] **Step 1: Add `vault_key_id` to the template body**

In `ansible/roles/semaphore_bootstrap/tasks/template.yml`, replace:
```yaml
    body:
      project_id: "{{ project_id | int }}"
      inventory_id: "{{ project_inventory_map[template_spec.inventory] | int }}"
      repository_id: "{{ repository_id | int }}"
      environment_id: null
      name: "{{ template_spec.name }}"
      playbook: "{{ template_spec.playbook }}"
      arguments: "[]"
      description: "{{ template_spec.description | default('') }}"
      allow_override_args_in_task: false
      app: ansible
      git_branch: "{{ project_spec.repository.branch | default('main') }}"
      type: ""
      suppress_success_alerts: false
```
with:
```yaml
    body:
      project_id: "{{ project_id | int }}"
      inventory_id: "{{ project_inventory_map[template_spec.inventory] | int }}"
      repository_id: "{{ repository_id | int }}"
      environment_id: null
      vault_key_id: >-
        {{ (project_key_map[template_spec.vault_key] | int)
           if (template_spec.vault_key is defined
               and template_spec.vault_key in project_key_map)
           else None }}
      name: "{{ template_spec.name }}"
      playbook: "{{ template_spec.playbook }}"
      arguments: "[]"
      description: "{{ template_spec.description | default('') }}"
      allow_override_args_in_task: false
      app: ansible
      git_branch: "{{ project_spec.repository.branch | default('main') }}"
      type: ""
      suppress_success_alerts: false
```

- [ ] **Step 2: Lint**

```bash
cd ansible
yamllint roles/semaphore_bootstrap/tasks/template.yml
ansible-lint roles/semaphore_bootstrap/tasks/template.yml
```
Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/semaphore_bootstrap/tasks/template.yml
git commit -m "feat(semaphore): set vault_key_id on templates from project_key_map"
```

---

## Task 5: Apply and verify

- [ ] **Step 1: Run the bootstrap**

```bash
make semaphore
```
Expected: all tasks `ok` or `changed`, no `failed`. The `vault-password` key should show
`changed` for both projects (first run), templates may also show `changed` if they need
to be recreated.

> **Note:** If templates already exist from a previous run they will NOT be updated
> (the idempotency check skips existing templates). Delete them in the Semaphore UI
> first if you need `vault_key_id` applied to existing templates.

- [ ] **Step 2: Verify key in Semaphore UI**

Open `http://semaphore.homeserver` → log in as `admin`.

For **each project** (`home-server`, `ugreen-paperless`):
1. Go to **Key Store** — verify `vault-password` entry exists with type `Login with password`
2. Go to **Task Templates** — open the template, verify **Vault Password** field shows `vault-password`

- [ ] **Step 3: Run a test job (optional but recommended)**

In the Semaphore UI, trigger the `Deploy Home Server` template with a dry-run playbook tag:
- Click **Run** → set **Extra variables**: `{"ansible_check_mode": true}`
- Watch the output — if vault decryption succeeds you will NOT see `Decryption failed` errors

---

## Idempotency Note

Re-running `make semaphore` after the initial apply is safe:
- Keys: skipped if name already exists in the project
- Templates: skipped if name already exists in the project

If `vault_key_id` needs to be updated on an already-existing template, delete the template
in the Semaphore UI and re-run `make semaphore`.
