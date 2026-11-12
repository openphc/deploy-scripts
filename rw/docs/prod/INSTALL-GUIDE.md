# Installing CCE on the RW PROD server (102.215.10.20): step-by-step guide

This guide replaces the old CCE system (1.x) on the Rwanda **PROD** server, **102.215.10.20**, with a fresh CCE 2.0 install.
The server keeps its Ubuntu, its users and its SSH login; step 2 removes everything of the old CCE system from it. One script
then does almost all the work. Your job is to prepare a few things, start the script, check the result, and put back the old
facilities and logins.

- **Time needed:** about 2½ hours: about 45 minutes of your work, plus 1 to 1½ hours while the script runs.
- **Skills needed:** logging in to a server with SSH, and copying and pasting commands. Nothing else.
- **How to use this guide:** do the steps in order. Each step tells you **what to type**, **what you should see**, and
  **what to do if you see something else**. If a step does not give the result it describes, stop and contact the technical
  team. Do not try to fix it yourself.

> **Golden rules**
> - Only ever run this on **102.215.10.20**. Never on 102.215.10.21 (that is UAT, which is already installed).
> - Copy commands exactly: the easiest way is to copy the whole grey box and paste it. Lines starting with `#` are notes;
>   pasting them is harmless.
> - Never send the GitLab token, the seed file or the backup files by e-mail or chat, and never paste them anywhere except
>   where this guide says.
> - If you are unsure, stop. Before step 2 nothing has changed; after it, the script can be started again later.

---

## Before you start: get these from the technical team

Tick each one off. Do not start until you have all of them.

| # | What | Why |
|---|---|---|
| 1 | The two **backup files from 2026-11-11**: `prod-keycloak-20261111-020004.sql.gz` (the old logins) and `prod-facility-2026-11-11.sql` (the facilities) | Step 2 deletes the old databases; step 9 puts these back. They are the only copy |
| 2 | Confirmation that **the old system may be removed now**, in an agreed **maintenance window** | CCE PROD is down from step 2 until step 9 |
| 3 | The **SSH login** for `cceadmin@102.215.10.20` (the existing one) | To log in |
| 4 | A **GitLab token** (a long text, starting with `glpat-`) with *read_repository* access to `repository.moh.gov.rw/cce` | To download the install scripts and the CCE code |
| 5 | The **seed file content**: a block of `NAME=value` lines (the Appendix shows what it looks like) | E-mail settings, the OpenHIM connection, and the passwords that must stay the same |
| 6 | The **GitLab address of the install scripts**, with the branch `deploy-scripts-rw` in it. Expected: `https://repository.moh.gov.rw/cce/deploy-scripts.git` | Step 4 downloads them from there |

---

## Step 1. Log in to the server

On your computer, open a terminal (Windows: *PowerShell*; Mac/Linux: *Terminal*) and type:

```sh
ssh cceadmin@102.215.10.20
```

Type the password when asked (nothing appears on screen while you type; that is normal) and press Enter. If your computer
asks `Are you sure you want to continue connecting (yes/no)?`, type `yes` and press Enter. **If it refuses** with a large
warning, `REMOTE HOST IDENTIFICATION HAS CHANGED!`, stop and tell the technical team: the server should not have changed.

**Check you are on the right server:**

```sh
hostname -I
```

**You should see** a line that contains `102.215.10.20`.
**If not:** you are on the wrong server. Type `exit` and log in again with the right address.

> The server's *name* (shown in the prompt after `cceadmin@`) does not matter; it is even misleadingly `cce-uat`. Only the
> address 102.215.10.20 counts.

---

## Step 2. Remove the old CCE system

This deletes the old CCE system: its services, its databases and its data. **Only start once you have item 1 (the backup
files) and item 2 (the go-ahead).** The old CCE PROD website stops working here. Each box can be pasted again if it stopped
part-way, and the whole step can be repeated: everything in it skips what is already gone. (It also removes a failed or
earlier install made with this guide, if you ever need to start over.)

Type the `cceadmin` password whenever `sudo` asks for it.

**2a.** Remove Kubernetes (k3s) and Docker, with everything that runs in them: the old CCE services, the old UAT's database,
Kafka and ClickHouse, the old secret store (Infisical), Portainer and the exporters:

```sh
cd /tmp
[ -x /usr/local/bin/k3s-uninstall.sh ] && sudo /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1
sudo rm -rf /etc/rancher /var/lib/rancher; echo "k3s removed"     # the uninstaller keeps the node password
command -v docker >/dev/null && sudo docker ps -aq | xargs -r sudo docker rm -f >/dev/null; echo "containers removed"
sudo systemctl disable --now cce-docker-fw docker.socket docker containerd 2>/dev/null
P=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' docker.io docker-buildx docker-compose-v2 containerd runc 2>/dev/null | awk '$2=="installed"{print $1}')
[ -z "$P" ] || sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $P >/dev/null; echo "docker removed"
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /opt/containerd /etc/systemd/system/docker.service.d \
  /usr/local/bin/docker-compose /usr/local/sbin/cce-docker-fw.sh /etc/systemd/system/cce-docker-fw.service
sudo systemctl daemon-reload
```

**You should see** `k3s removed`, `containers removed` and `docker removed`.

**2b.** Remove PostgreSQL, Kafka, Kafka Connect, ClickHouse and the other services installed directly on the server, and their
data:

```sh
cd /tmp
sudo systemctl disable --now kafka-connect kafka clickhouse-server postgresql redis-server infisical-runsvdir \
  cce-postgres-exporter cce-kafka-exporter cce-portainer 2>/dev/null
sudo rm -f /etc/systemd/system/{kafka,kafka-connect,cce-postgres-exporter,cce-kafka-exporter,cce-portainer}.service
P=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' clickhouse-server clickhouse-client clickhouse-common-static \
  postgresql-16 postgresql-client-16 postgresql-common postgresql-client-common infisical infisical-core redis-server redis-tools \
  2>/dev/null | awk '$2=="installed"{print $1}')
[ -z "$P" ] || sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq --allow-change-held-packages $P >/dev/null
echo "packages removed"
sudo rm -rf /opt/kafka /var/lib/kafka /var/log/kafka /tmp/kafka-logs /tmp/connect.offsets \
  /var/lib/clickhouse /etc/clickhouse-server /etc/clickhouse-client /var/log/clickhouse-server /var/log/clickhouse-keeper \
  /var/lib/postgresql /etc/postgresql /var/log/postgresql /var/lib/redis /etc/redis /var/log/redis /etc/clickhouse-keeper \
  /opt/cce-local-infisical /opt/infisical-core /etc/infisical /var/log/infisical /var/log/infisical-core /etc/cce-exporters /usr/local/bin/postgres_exporter /usr/local/bin/kafka_exporter \
  /opt/portainer /opt/portainer-* /var/lib/portainer /opt/cce-src /var/lib/cce-rw /etc/logrotate.d/cce-* \
  /etc/systemd/system/redis.service
sudo systemctl daemon-reload
```

**You should see** `packages removed`.

**2c.** Remove the old backup job, and move the old files out of the way. Nothing here is deleted: the old backups and the old
scripts are kept until the technical team decides to delete them.

```sh
cd /tmp
sudo sh -c 'crontab -l 2>/dev/null | grep -v "cce-prod daily backup" | crontab -'
B=/var/backups/cce-prod-old-1.x; [ -e $B ] && B=/var/backups/cce-prod-old-$(date +%Y%m%d-%H%M)
[ -d /var/backups/cce-prod ] && sudo mv /var/backups/cce-prod $B
D=~/old-cce-1.x; [ -e $D ] && D=~/old-cce-$(date +%Y%m%d-%H%M)
for f in deploy-scripts deploy-scripts.stale.20260616-061144 .cce-infisical .infisical .kube infisical \
         .env-removed-20260622-062250 api_permissions_clean.sql cce-realm-clean.json prod.fp prod.fp.err; do
  [ -e ~/"$f" ] && { mkdir -p -m 700 $D; mv ~/"$f" $D/; }
done
sudo rm -rf /root/.infisical /root/.kube /root/.docker /root/.gradle /root/infisical-keyring
find ~ -maxdepth 1 -type f -empty -name '*@*' -delete   # a stray empty file
ls -A ~
```

**You should see** a short list: `old-cce-1.x` (and `old-cce-<date>` if you repeated the step),
`incident-2026-10-24-connect-exploit` (leave it: the technical team keeps it) and a few files starting with a dot (`.bashrc`,
`.profile`, `.ssh`, …).

The firewall (UFW) is left on: SSH, the website ports and the internal networks stay allowed, and the install sets it up
again in its step 4/5.

**2d.** Check that nothing of the old system is left. Paste this whole box:

```sh
lsb_release -ds
df -h / | tail -1
echo "--- leftovers (should be empty) ---"
command -v k3s docker psql clickhouse-server redis-server infisical
ls -d /opt/kafka /var/lib/kafka /var/lib/clickhouse /var/lib/postgresql /var/lib/docker /var/lib/rancher /etc/rancher \
  ~/deploy-scripts ~/.cce-infisical /var/backups/cce-prod /opt/cce-src /var/lib/cce-rw /opt/cce-local-infisical \
  /opt/portainer /opt/infisical-core /etc/cce-exporters /etc/systemd/system/docker.service.d /usr/local/bin/docker-compose 2>/dev/null
systemctl list-units --all --no-legend 'kafka*' 'clickhouse*' 'postgresql*' 'docker*' 'k3s*' 'containerd*' 'redis*' \
  'infisical*' 'cce-*' | grep -v not-found
sudo crontab -l 2>/dev/null | grep cce
sudo ss -ltnp | grep -vE ':22 |:53 ' | awk 'NR>1'
echo "--- end ---"
```

**You should see:**
- `Ubuntu 26.04 LTS`
- a line about the disk where the 4th number (free space) is **at least 100G**
- **nothing** between `--- leftovers ---` and `--- end ---`

**If something is listed between the two lines**, paste the box of 2a, 2b or 2c that removes it again, then repeat 2d. If it
is still listed, stop and send what you see to the technical team.

Now install three small tools the next steps use:

```sh
sudo apt-get update -qq && sudo apt-get install -y -qq git tmux nano
```

**You should see** the command finish without the word `E:` or `error`.

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
cd ~/deploy-scripts && git branch --show-current && ls
```

**You should see** `deploy-scripts-rw`, then a list that includes `k8s`, `keycloak-themes`, `one-click-installer` and `rw`.

**If you see** `not found`, `Authentication failed` or `could not read`: the token or the address is wrong. Send the message to the
technical team. (If the technical team gave you a different address in item 6, use that one in the `git clone` line.)
**If you see** `already exists and is not an empty directory`: step 2c did not move the old scripts; repeat 2c.

---

## Step 5. Create the seed file

The seed file gives the install the settings that must not be invented: the e-mail server, alert recipients, the OpenHIM
login and some passwords. The technical team sends you its content (item 5).

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
send the log file to the technical team (see step 10 for where it is).

---

## Step 8. Check that everything works

Wait **5 minutes** after the install finished, then do these four checks.

**8a. All services running:**

```sh
sudo k3s kubectl -n cce-prod get pods
```

**You should see** about 15 to 20 lines, each with `Running` in the STATUS column, and the READY column showing the same number on
both sides (for example `1/1`). A RESTARTS count of 1 or 2 is normal: some services start before the ones they need.
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

## Step 9. Put back the old facilities and logins

This restores two things from the 2026-11-11 backups (item 1):
- the **facilities** (86, with their names, districts and expected patients per day), into the new database
- the **Keycloak logins**: OpenHIM's login (`openhim-emitter-inbound`, with its password) and the Insights users, so nobody,
  OpenHIM included, has to change a password

**Do it right after step 8:** until it is done, OpenHIM's calls get `401` and no new events arrive. The Keycloak restore replaces
the new, empty Keycloak data; the install's first backup (step 8d) keeps a copy of that.

**9a.** On **your computer**, copy both files to the server (they hold password hashes: never by e-mail or chat):

```sh
scp prod-keycloak-20261111-020004.sql.gz prod-facility-2026-11-11.sql cceadmin@102.215.10.20:
```

**9b.** On the server, put the facilities back. Paste this whole box:

```sh
cd /tmp
sudo install -m 600 ~/prod-facility-2026-11-11.sql ~/prod-keycloak-20261111-020004.sql.gz /root/ \
  && rm ~/prod-facility-2026-11-11.sql ~/prod-keycloak-20261111-020004.sql.gz
sudo sed -E '/^INSERT INTO public.facility /s/\);$/) ON CONFLICT (facility_id) DO UPDATE SET facility_name = EXCLUDED.facility_name, district_name = EXCLUDED.district_name, expected_patients_per_day = EXCLUDED.expected_patients_per_day;/' \
  /root/prod-facility-2026-11-11.sql | sudo -u postgres psql -q -o /dev/null -v ON_ERROR_STOP=1 -d ccedb && echo "FACILITIES OK"
sudo -u postgres psql -qtA -d ccedb -c "select count(*) || ' facilities' from facility"
```

**You should see** `FACILITIES OK`, then `86 facilities` (a few more is fine: a facility that sent an event since step 7).
Pasting the box again is harmless: a facility already there is updated, not added twice.

**9c.** Put the Keycloak logins back. Paste this whole box:

```sh
cd /tmp
sudo k3s kubectl -n cce-prod scale deploy/keycloak --replicas=0
while sudo k3s kubectl -n cce-prod get pods --no-headers | grep -q '^keycloak-'; do sleep 5; done
sudo sh -c 'gunzip -c /root/prod-keycloak-20261111-020004.sql.gz' \
  | sudo -u postgres psql -q -o /dev/null -v ON_ERROR_STOP=1 -d keycloak -c 'SET ROLE admin' -f - && echo "RESTORE OK"
sudo k3s kubectl -n cce-prod scale deploy/keycloak --replicas=1
sudo k3s kubectl -n cce-prod rollout status deploy/keycloak --timeout=600s
```

**You should see** `RESTORE OK`, then `deployment "keycloak" successfully rolled out`.
(`SET ROLE admin` makes the restored tables belong to `admin`, the user Keycloak connects as. Without it they belong to
`postgres` and Keycloak cannot read them.)

**9d.** Check the OpenHIM client and user against the server's secret store:

```sh
cd ~/deploy-scripts && sudo bash one-click-installer/lib/infisical-run.sh prod bash rw/lib/keycloak-openhim-basic.sh prod 2>&1 \
  | grep -vE 'new release of infisical|To update, run|Your logged-in session|Injecting [0-9]+ Infisical|^host-ip:|^$'
```

**You should see** `client openhim-basic: present, secret matches Infisical` (or `… aligned to Infisical`) and
`user openhim-emitter-inbound: has EMITTER_INBOUND_WRITE`. **If you see an error about the admin login or a token:** the seed
file did not have the old `KEYCLOAK_ADMIN_USER`/`KEYCLOAK_ADMIN_PASSWORD` (Appendix). Tell the technical team.

**9e.** Delete the backup files from the server:

```sh
sudo rm /root/prod-facility-2026-11-11.sql /root/prod-keycloak-20261111-020004.sql.gz
```

---

## Step 10. Hand over to the technical team

Close the safe window (type `exit` inside tmux), then tell the technical team the install is finished and send them:

1. **The log file.** It is on the server in `/home/cceadmin/`, named `prod-install-<date>-<time>.log`. To see its exact name:
   `ls ~/prod-install-*.log`
2. **The results of steps 8 and 9** (a screenshot of 8a, 9b and 9d is enough).

The technical team then finishes these items, which are **not** part of your job:

- copy the secret-store key files off the server (`/opt/cce-local-infisical/.env` and `admin.env`, and
  `/home/cceadmin/.cce-infisical/prod.*`); without them the passwords cannot be recovered
- load the clinical protocol: `rw/protocols/emr-service-protocol.json`, the same definition UAT .21 runs (how:
  `rw/docs/uat/OPERATIONS-RUNBOOK.md` §12, with namespace `cce-prod`)
- put OpenHIM's real password into Infisical as `EMITTER_INBOUND_PASSWORD` once known; until then Infisical holds a generated
  value that is not the password (`show-credentials.sh` shows that one)
- confirm that OpenHIM traffic is arriving, and that Insights lists the facilities
- decide when to delete the old system's leftovers: `/var/backups/cce-prod-old-*` (it holds the old, unredacted clinical
  database dumps) and `~/old-cce-*`
- from now on, run PROD the way UAT is run (`rw/docs/uat/OPERATIONS-RUNBOOK.md`, with `rw/config/prod.env` and namespace
  `cce-prod`), until PROD's own runbook is written

Finally, log out of the server: `exit`.

---

## If something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `Permission denied` when logging in | wrong password or user | check the login from item 3 |
| `REMOTE HOST IDENTIFICATION HAS CHANGED!` | the server is not the one expected | stop; tell the technical team |
| Something still listed in step 2d | part of the old system is left | step 2d says what to do |
| `ERROR: run as root` | `sudo` is missing at the start of the command | copy the command again, completely |
| `GIT_TOKEN_FILE … not readable` | the token file is missing | repeat step 3 |
| `SEED_ENV_FILE not readable` or `Fix the config above` | the seed file is missing or wrong | repeat step 5; send the message to the technical team |
| `✗ … repository is EMPTY` or `no branch/tag` | the code is not in GitLab yet | stop; tell the technical team |
| Your connection dropped during step 7 | normal; the install kept running | log in again, `tmux attach -t install` |
| `no sessions` after `tmux attach -t install` | the install window was closed | check whether it finished: `tail -20 ~/prod-install-*.log`. If it did not finish, run step 7a and 7b again |
| An `ERROR` line during step 7 | one part failed | run step 7b again once; if the same error comes back, send the log |
| Browser shows a certificate warning | the certificate is still being issued | step 8b |
| No `FACILITIES OK` in step 9b | the facility load stopped | paste the `sudo sed` and the last line of 9b again (the files are already in `/root`); if it fails again, send the screen |
| No `RESTORE OK` in step 9c | the Keycloak restore stopped | run step 9c again from its first line; Keycloak stays at 0 until it succeeds. If it fails again, send the screen |
| OpenHIM's calls get `401` after step 9 | OpenHIM uses another password, or the client secret differs | tell the technical team, with the output of 9d |

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

# REQUIRED: Keycloak. Must be the old PROD's values: the restored Keycloak (step 9) brings the old Keycloak admin and the
# old openhim-basic client with it, and the install has to log in to it with these.
KEYCLOAK_ADMIN_USER=
KEYCLOAK_ADMIN_PASSWORD=
BASIC_AUTH_CLIENT_SECRET=

# CCE → OpenHIM core API (mediator registration), as on the old PROD
OPENHIM_CORE_HOST=
OPENHIM_CORE_API_PORT=
OPENHIM_CORE_SCHEME=
OPENHIM_CORE_AUTH_TYPE=
OPENHIM_USERNAME=
OPENHIM_PASSWORD=

# Optional
GRAFANA_ADMIN_PASSWORD=
GATEWAY_ALLOWED_ORIGINS=https://cce.moh.gov.rw
```

Take every value from the old PROD's Infisical export, made on 2026-11-11 and kept by the technical team (step 2 removes the
old Infisical); all of these keys are in it. Delete any optional line you do not fill in.

**Not in the seed file: OpenHIM's login** (`EMITTER_INBOUND_USER`/`EMITTER_INBOUND_PASSWORD`). Its password is not in the
export; it exists only in the old Keycloak database (as a hash) and in OpenHIM's channel, and the step 9 restore brings it back
unchanged. The install stores a generated `EMITTER_INBOUND_PASSWORD` in Infisical, which is not that password (step 10).

What the script uses, for reference: config `rw/config/prod.env` (namespace `cce-prod`, overlay `k8s/overlays/rw-prod`, public
name `cce.moh.gov.rw`, PROD's replica counts, the same code branches as UAT .21). Details: `../ONE-CLICK-INSTALL.md`.
