# Installing CCE on the RW PROD server (102.215.10.20): step-by-step guide

This guide installs the complete CCE system on the Rwanda **PROD** server, **102.215.10.20**, after the server has been
**wiped clean and Ubuntu freshly installed**. Nothing from the old system is left on it. One script does almost all the work. Your job is to prepare a few things, start the script, and check the result.

- **Time needed:** about 2 hours: about 20 minutes of your work, plus 1 to 1½ hours while the script runs.
- **Skills needed:** logging in to a server with SSH, and copying and pasting commands. Nothing else.
- **How to use this guide:** do the steps in order. Each step tells you **what to type**, **what you should see**, and
  **what to do if you see something else**. If a step does not give the result it describes, stop and contact the technical
  team. Do not try to fix it yourself.

> **Golden rules**
> - Only ever run this on **102.215.10.20**. Never on 102.215.10.21 (that is UAT, which is already installed).
> - Copy commands exactly: the easiest way is to copy the whole grey box and paste it. Lines starting with `#` are notes;
>   pasting them is harmless.
> - Never send the GitLab token or the seed file by e-mail or chat, and never paste them anywhere except where this guide says.
> - If you are unsure, stop. Nothing is lost by pausing; the script can be started again later.

---

## Before you start: get these from the technical team

Tick each one off. Do not start until you have all of them.

| # | What | Why |
|---|---|---|
| 1 | Confirmation that **the old PROD data was backed up and copied off the server before the wipe** | The wipe erased everything on the server; the backup is the only copy |
| 2 | Confirmation that **the wipe is done**: Ubuntu **26.04 LTS** freshly installed, the server still has the address **102.215.10.20**, and a user **`cceadmin`** exists that may use `sudo` | This guide and the scripts are tested on exactly that |
| 3 | Confirmation that a **maintenance window** has been agreed | CCE PROD is unavailable until the install finishes |
| 4 | The **SSH login** for `cceadmin@102.215.10.20` (the password set during the fresh install) | To log in |
| 5 | A **GitLab token** (a long text, starting with `glpat-`) with *read_repository* access to `repository.moh.gov.rw/cce` | The script downloads the CCE code with it |
| 6 | The **seed file content**: a block of `NAME=value` lines (the Appendix shows what it looks like) | E-mail settings, OpenHIM login and passwords that must stay the same |
| 7 | The **address of the install scripts in GitLab**. Expected: `https://repository.moh.gov.rw/cce/deploy-scripts.git`, branch `deploy-scripts-rw` | Step 4 downloads them from there |

---

## Step 1. Log in to the server

On your computer, open a terminal (Windows: *PowerShell*; Mac/Linux: *Terminal*) and type:

```sh
ssh cceadmin@102.215.10.20
```

Type the password when asked (nothing appears on screen while you type; that is normal) and press Enter.

Because the server was freshly installed, it has a new identity, and your computer may react in one of two ways:

- **It asks** `Are you sure you want to continue connecting (yes/no)?` Type `yes` and press Enter.
- **It refuses** with a large warning, `REMOTE HOST IDENTIFICATION HAS CHANGED!`. This is expected after a wipe **only
  if the technical team confirmed the wipe** (item 2). Then, on your computer, type the line below, press Enter, and run
  the `ssh` command again:

  ```sh
  ssh-keygen -R 102.215.10.20
  ```

  If you were **not** told the server was wiped, do not do this: stop and tell the technical team.

**Check you are on the right server:**

```sh
hostname -I
```

**You should see** a line that contains `102.215.10.20`.
**If not:** you are on the wrong server. Type `exit` and log in again with the right address.

> The server's *name* (shown in the prompt after `cceadmin@`) does not matter; before the wipe it was even misleadingly
> called `cce-uat`. Only the address 102.215.10.20 counts.

---

## Step 2. Check the server is ready

Copy and paste this whole box:

```sh
lsb_release -ds
df -h / | tail -1
echo "--- leftovers (should be empty) ---"
command -v k3s psql clickhouse-server
ls -d /opt/kafka /opt/cce-src /var/lib/cce-rw /opt/cce-local-infisical 2>/dev/null
echo "--- end ---"
```

**You should see:**
- `Ubuntu 26.04 LTS`
- a line about the disk where the 4th number (free space) is **at least 100G** (after a wipe it is usually several hundred)
- **nothing** between `--- leftovers ---` and `--- end ---`

**If the Ubuntu version is different, or something is listed between the two lines**, the server was not wiped as expected.
**Stop** and send what you see to the technical team.

Now install two small tools the next steps use:

```sh
sudo apt-get update -qq && sudo apt-get install -y -qq git tmux nano
```

Type the `cceadmin` password if asked. **You should see** the command finish without the word `E:` or `error`.

---

## Step 3. Save the GitLab token on the server

The token is stored in a file only the administrator (root) can read.

**3a.** Create the empty, protected file:

```sh
sudo install -m 600 /dev/null /root/.cce-gitlab.token
```

**3b.** Open it in the editor:

```sh
sudo nano /root/.cce-gitlab.token
```

Paste the token (right-click, or `Ctrl+Shift+V`). It must be on **one line**, with nothing else in the file.
Save and close: press `Ctrl+O`, then `Enter`, then `Ctrl+X`.

**3c.** Check it:

```sh
sudo wc -c /root/.cce-gitlab.token
```

**You should see** a number above 20 followed by the file name (for example `27 /root/.cce-gitlab.token`).
**If you see `0`:** the paste did not work; repeat 3b.

---

## Step 4. Download the install scripts

Paste this whole box (it uses the token from step 3; the token is not shown on screen):

```sh
cd ~
sudo env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://repository.moh.gov.rw/.extraHeader \
  GIT_CONFIG_VALUE_0="Authorization: Basic $(sudo sh -c 'printf "oauth2:%s" "$(tr -d "[:space:]" < /root/.cce-gitlab.token)"' | base64 -w0)" \
  git clone -b deploy-scripts-rw https://repository.moh.gov.rw/cce/deploy-scripts.git /home/cceadmin/deploy-scripts
sudo chown -R cceadmin: /home/cceadmin/deploy-scripts
ls ~/deploy-scripts
```

**You should see** a list that includes `k8s`, `one-click-installer` and `rw`.

**If you see** `not found`, `Authentication failed` or `could not read`: the token or the address is wrong. Send the message to the
technical team. (If the technical team gave you a different address in item 7, use that one in the `git clone` line.)

---

## Step 5. Create the seed file

The seed file gives the install the settings that must not be invented: the e-mail server, alert recipients, the OpenHIM
login and some passwords. The technical team sends you its content (item 6).

**5a.** Create the empty, protected file and open it:

```sh
sudo install -m 600 /dev/null /root/cce-prod-seed.env
sudo nano /root/cce-prod-seed.env
```

**5b.** Paste the whole content you received. Save and close: `Ctrl+O`, `Enter`, `Ctrl+X`.

**5c.** Check it:

```sh
echo "required settings: $(sudo grep -c '^CCE_INTELLIGENCE_' /root/cce-prod-seed.env)"
echo "empty values (should be none):"; sudo grep -E '^[A-Z0-9_]+=[[:space:]]*$' /root/cce-prod-seed.env
echo "--- end ---"
```

**You should see** `required settings: 9` or more, and **nothing** between `empty values` and `--- end ---`.

**If the number is lower, or a line appears in between:** the content is incomplete. Open the file again (5a, second line)
and compare with what you received, or ask the technical team for the missing values. Never leave a line as `NAME=` with
nothing after the `=`; delete such a line instead.

---

## Step 6. Test the connection to the code (nothing is installed yet)

```sh
cd ~/deploy-scripts
sudo bash rw/one-click-install.sh --config rw/config/prod.env --check-only
```

**You should see** a list of about 11 repositories, each with a **✓**, and at the end:

```
Pre-flight OK (--check-only: stopping here).
```

**If any line has a ✗:** stop and send the screen to the technical team. The message after the ✗ tells them what is missing
(for example `repository is EMPTY` or `no branch/tag`). Nothing has been installed, so it is safe to stop here.

---

## Step 7. Run the install

The install takes 1 to 1½ hours. Run it inside **tmux**, a "safe window" that keeps the install running even if your
connection drops or you close your laptop.

**7a.** Open a safe window:

```sh
tmux new -s install
```

The screen clears and a green bar appears at the bottom. You are now inside tmux.

**7b.** Start the install (it also saves everything it prints to a log file):

```sh
cd ~/deploy-scripts
sudo bash rw/one-click-install.sh --config rw/config/prod.env --yes 2>&1 | tee ~/prod-install-$(date +%Y%m%d-%H%M).log
```

**7c.** Let it run. You will see long sections, each starting with a line like:

```
████ RW 1/5 Pre-flight: source repositories
████ RW 2/5 Prerequisites …
████ RW 3/5 Build the CCE images from source        ← the longest part (about 30–45 minutes)
████ RW 4/5 Install …
████ RW 4b Keycloak …
████ RW 5/5 Daily DB backups …
```

A lot of technical text scrolls past; that is normal. Words like `WARNING` are usually fine. **Do not press any keys
while it runs.**

> **If your connection drops** (normal near the end of 4/5, when the firewall is switched on), log in again (step 1)
> and type `tmux attach -t install` to see the install again. It kept running while you were away.
>
> **To leave it running and log out:** press `Ctrl+B`, release, then press `D`. Come back later with `tmux attach -t install`.

**7d. How to know it finished successfully.** The last lines look like this:

```
  docker containers: none (as intended)

Source versions deployed (/var/lib/cce-rw/prod/build-manifest.tsv, latest per repo):
   cce-collector-service        release-2.0.0   …
   …
New commits on a branch later:  sudo bash rw/redeploy-from-source.sh --config rw/config/prod.env [repo...]
```

and the command prompt (`cceadmin@…$`) is back.

**If it stopped with a line starting with `ERROR`:** run **exactly the same command again** (7b). The install continues from
where it stopped; work already done is not repeated. If it stops with an `ERROR` **a second time at the same place**, stop and
send the log file to the technical team (see step 9 for where it is).

---

## Step 8. Check that everything works

Wait **5 minutes** after the install finished, then do these four checks.

**8a. All services running:**

```sh
sudo k3s kubectl -n cce-prod get pods
```

**You should see** about 15 to 20 lines, each with `Running` in the STATUS column, and the READY column showing the same number on
both sides (for example `1/1`).
**If some show `ContainerCreating` or `0/1`:** wait 5 more minutes and run it again. Still not ready after 15 minutes, or
showing `CrashLoopBackOff` / `Error`: send the screen to the technical team.

**8b. The website:** on your own computer, open **https://cce.moh.gov.rw/insights/** in a browser.
**You should see** the CCE login page with a padlock in the address bar (no security warning).
**If the browser warns that the connection is not secure**, run this on the server, wait 3 minutes and try again:

```sh
cd ~/deploy-scripts && sudo bash rw/lib/tls-check.sh cce.moh.gov.rw
```

**8c. The OpenHIM entry point answers:**

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://cce.moh.gov.rw/v1/openhim-emitter-adaptor/inbound
```

**You should see** `401`. That is correct: it means "the service is up and refuses visitors without a login".
**If you see** `000`, `404`, `500`, `502` or `503`: wait 5 minutes and try again; if it stays, tell the technical team.

**8d. Backups are set up:**

```sh
sudo ls /var/backups/cce-prod/
```

**You should see** a folder named with today's date (for example `20261215`). From now on a new backup is made every night at 02:00.

---

## Step 9. Hand over to the technical team

Close the safe window (type `exit` inside tmux), then tell the technical team the install is finished and send them:

1. **The log file.** It is on the server in `/home/cceadmin/`, named `prod-install-<date>-<time>.log`. To see its exact name:
   `ls ~/prod-install-*.log`
2. **The results of step 8** (a screenshot of 8a is enough).

The technical team then finishes these items, which are **not** part of your job:

- copy the secret-store key files off the server (`/opt/cce-local-infisical/.env` and `admin.env`, and
  `/home/cceadmin/.cce-infisical/prod.*`); without them the passwords cannot be recovered
- load the clinical protocol: `rw/protocols/emr-service-protocol.json`, the same definition UAT .21 runs (how:
  `rw/docs/uat/OPERATIONS-RUNBOOK.md` §12, with namespace `cce-prod`)
- create the Insights users in Keycloak, or restore the old Keycloak data if that was decided (the dump taken from the
  old PROD on 2026-11-11 is kept by the technical team)
- confirm that OpenHIM traffic is arriving
- from now on, run PROD the way UAT is run (`rw/docs/uat/OPERATIONS-RUNBOOK.md`, with `rw/config/prod.env` and namespace
  `cce-prod`), until PROD's own runbook is written

Finally, log out of the server: `exit`.

---

## If something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `Permission denied` when logging in | wrong password or user | check the login from item 4 (the password changed with the wipe) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED!` | expected after the wipe | step 1 |
| `ERROR: run as root` | `sudo` is missing at the start of the command | copy the command again, completely |
| `GIT_TOKEN_FILE … not readable` | the token file is missing | repeat step 3 |
| `SEED_ENV_FILE not readable` or `Fix the config above` | the seed file is missing or wrong | repeat step 5; send the message to the technical team |
| `✗ … repository is EMPTY` or `no branch/tag` | the code is not in GitLab yet | stop; tell the technical team |
| Your connection dropped during step 7 | normal; the install kept running | log in again, `tmux attach -t install` |
| `no sessions` after `tmux attach -t install` | the install window was closed | check whether it finished: `tail -20 ~/prod-install-*.log`. If it did not finish, run step 7a and 7b again |
| An `ERROR` line during step 7 | one part failed | run step 7b again once; if the same error comes back, send the log |
| Browser shows a certificate warning | the certificate is still being issued | step 8b |

**Do not**, under any circumstances: edit files in `/opt/cce-src` or `~/deploy-scripts`, use `rw/config/uat.env` on this
server, or run anything on 102.215.10.21.

---

## Appendix (for the technical team): seed file content

`/root/cce-prod-seed.env`, one `NAME=value` per line, no quotes needed, no empty values. The script stores these in the
server's own secret store (Infisical); everything not listed here is generated.

```sh
# REQUIRED: intelligence-service does not start without them
CCE_INTELLIGENCE_SMTP_HOST=
CCE_INTELLIGENCE_SMTP_PORT=
CCE_INTELLIGENCE_SMTP_USERNAME=
CCE_INTELLIGENCE_SMTP_PASSWORD=
CCE_INTELLIGENCE_ALERT_EMAIL_TIER1=
CCE_INTELLIGENCE_ALERT_NAME_TIER1=
CCE_INTELLIGENCE_ALERT_EMAIL_TIER2=
CCE_INTELLIGENCE_ALERT_NAME_TIER2=
CCE_INTELLIGENCE_ALERT_EMAIL_TIER3=
CCE_INTELLIGENCE_ALERT_NAME_TIER3=

# OpenHIM → CCE: so OpenHIM's existing Basic-auth credentials keep working without changing OpenHIM
EMITTER_INBOUND_USER=openhim-emitter-inbound
EMITTER_INBOUND_PASSWORD=
BASIC_AUTH_CLIENT_SECRET=

# CCE → OpenHIM core API (mediator registration), as on the old PROD
OPENHIM_CORE_HOST=
OPENHIM_CORE_API_PORT=
OPENHIM_CORE_SCHEME=
OPENHIM_CORE_AUTH_TYPE=
OPENHIM_USERNAME=
OPENHIM_PASSWORD=

# Optional: fixed admin passwords instead of generated ones (min 12 characters)
KEYCLOAK_ADMIN_USER=
KEYCLOAK_ADMIN_PASSWORD=
GRAFANA_ADMIN_PASSWORD=
GATEWAY_ALLOWED_ORIGINS=https://cce.moh.gov.rw
```

Delete any optional line you do not fill in. Take the values from the old PROD's Infisical export, made on 2026-11-11 before
the wipe and kept by the technical team (after the wipe the old Infisical is gone). The old PROD had no
`EMITTER_INBOUND_USER`/`EMITTER_INBOUND_PASSWORD`: choose them, and give the same pair to the OpenHIM admins for the channel.
If `EMITTER_INBOUND_PASSWORD` is left out, the installer generates one: read it after the install with
`sudo bash one-click-installer/tools/show-credentials.sh prod --reveal` and give that to the OpenHIM admins instead.
(The older names `OPENHIM_INBOUND_USER`/`OPENHIM_INBOUND_PASSWORD` are still accepted.)

What the script uses, for reference: config `rw/config/prod.env` (namespace `cce-prod`, overlay `k8s/overlays/rw-prod`, public
name `cce.moh.gov.rw`, PROD's replica counts, the same code branches as UAT .21). Details: `../ONE-CLICK-INSTALL.md`.
