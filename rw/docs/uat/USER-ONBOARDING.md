# RW CCE: give someone access to the Insights dashboard

This guide shows how to give a person access to the CCE Insights dashboard, using the Keycloak admin console. It is written
for UAT (`cceuat.moh.gov.rw`). PROD works the same way: use `cce.moh.gov.rw` and the PROD admin login (see [On PROD](#on-prod)).

A user needs **all three** of these:

1. an account in the **`cce`** realm,
2. the **`INSIGHTS_READ`** client role of the **`gateway-service`** client,
3. a "set your password" e-mail, which the user follows to choose their password.

The step people most often miss is step 2. Without the role the user can still sign in, but **every dashboard call returns 403**
and the dashboard shows no data (see [Why the role matters](#why-the-role-matters)).

The screenshots were taken from the UAT console (Keycloak 26.5.4) on 2026-11-17, using a test account
(`insights.demo@example.org`) that was deleted afterwards. The red boxes and labels were added for this guide; they are not
part of Keycloak.

## What you need

| What | Value |
|---|---|
| Admin console | `https://cceuat.moh.gov.rw/auth/admin/` |
| Realm you sign in to | `master` |
| Realm the user is created in | **`cce`** |
| Role to give | **`INSIGHTS_READ`**, a client role of **`gateway-service`** |
| Where the user signs in | `https://cceuat.moh.gov.rw/insights/` |
| Admin login | Infisical `/keycloak`: `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` |

To see the admin login on the server:

```bash
cd ~/deploy-scripts
sudo bash one-click-installer/tools/show-credentials.sh uat --reveal
```

The output includes passwords. Don't paste it anywhere.

## Step 0: check that the realm can send e-mail

The user sets their password through an e-mail link. If the realm cannot send e-mail, nobody can use the new account, so check
this first.

1. Switch to the `cce` realm (steps 1 and 2 below).
2. Open **Realm settings** → **Email** tab.
3. Check that **From** and **Host** are filled in.

![Realm settings, Email tab: From is CCERwanda@medtroniclabs.org, Host is smtp.office365.com](images/user-onboarding/18-realm-email-smtp.png)

On UAT, mail goes through Office 365 (`smtp.office365.com`, port 587, StartTLS) as `CCERwanda@medtroniclabs.org`, shown as
"CCE Rwanda". If **Host** is empty, stop and fix the realm's e-mail settings first; step 6 will fail otherwise.

## Step 1: sign in to the admin console

Open `https://cceuat.moh.gov.rw/auth/admin/` and sign in with the Keycloak admin login.

![Keycloak admin sign-in page](images/user-onboarding/01-admin-login.png)

You land in the **`master`** realm; the label at the top of the left menu shows it. Dashboard users are **not** created here.

![Admin console after sign-in; the current realm is still master](images/user-onboarding/02-console-landing.png)

## Step 2: switch to the `cce` realm

There is no realm drop-down. Click **Manage realms** in the left menu, then click **cce**.

![Manage realms list, with the cce realm highlighted](images/user-onboarding/03-manage-realms.png)

Check that the label at the top of the left menu now reads **cce**. Do everything from here on in this realm.

![Left menu showing cce as the current realm](images/user-onboarding/04-realm-switched.png)

> **Why this matters:** a user created in `master` is a Keycloak *administrator*, not a dashboard user. It cannot sign in to
> the dashboard, and it has powers it should never have. Always check the label.

## Step 3: check whether the user already exists

Click **Users** and search for the person's e-mail address.

![Users list searched by e-mail address, with no results](images/user-onboarding/05-users-search.png)

- **No search results:** go to step 4.
- **The user is listed:** don't create a second account. Open it, check the role (step 5), then send the e-mail (step 6).

## Step 4: create the user

Click **Add user**. The empty form:

![Empty Create user form](images/user-onboarding/06-create-user-empty.png)

Fill it in:

| Field | Enter |
|---|---|
| **Required user actions** | select **Update Password** |
| **Email verified** | leave **Off** |
| **Username** | the person's **e-mail address** |
| **Email** | the same e-mail address |
| **First name** / **Last name** | the person's name |

- **Update Password** makes the user choose their own password at first sign-in. Nobody else, including you, ever knows it.
- Leave **Email verified** off. Following the link in step 6 proves that the address works.

![Create user form filled in, with Update Password as the required action](images/user-onboarding/07-create-user-filled.png)

Click **Create**. You land on the new user's **Details** tab.

![The new user's Details tab, with "The user has been created" message](images/user-onboarding/08-user-created.png)

The account exists, but it **cannot read any dashboard data yet**.

## Step 5: give the `INSIGHTS_READ` role

Open the **Role mapping** tab. A new user has only `default-roles-cce`:

![Role mapping tab of the new user, with only default-roles-cce](images/user-onboarding/09-role-mapping-empty.png)

Click **Assign role** and choose **Client roles**. `INSIGHTS_READ` belongs to the `gateway-service` client, so it does not
appear under **Realm roles**.

![Assign role drop-down open, with Client roles highlighted](images/user-onboarding/10-assign-role-dropdown.png)

The **Assign Client roles** dialog opens:

![Assign Client roles dialog listing all client roles](images/user-onboarding/11-assign-role-dialog.png)

Search for `INSIGHTS_READ` and press Enter. Check that the **Client ID** column reads **`gateway-service`**:

![Dialog filtered to INSIGHTS_READ of gateway-service](images/user-onboarding/12-assign-role-filtered.png)

Tick the row and click **Assign**:

![INSIGHTS_READ ticked, Assign button highlighted](images/user-onboarding/13-assign-role-checked.png)

The role now shows in the user's role mapping, tagged `gateway-service`:

![Role mapping tab now showing gateway-service INSIGHTS_READ](images/user-onboarding/14-role-mapping-assigned.png)

Give only `INSIGHTS_READ`. Dashboard users need nothing else ([SECURITY.md](SECURITY.md) §5).

### Why the role matters

The dashboard calls the Insights API through `gateway-service`. The gateway checks every request against its
`api_permissions` table. The row for the dashboard is:

| Permission | Method | Path |
|---|---|---|
| `INSIGHTS_READ` | GET | `/v1/insights/**` |

The gateway compares the permission name with the roles in the user's token (`resource_access.gateway-service.roles`). Without
the role, the token is valid and the user can sign in, but every dashboard request returns **403**. The user typically reports
"I can log in but the dashboard is empty", which looks like an application fault but is a missing role.

## Step 6: send the "set your password" e-mail

Open the **Credentials** tab and click **Credential Reset**. Do **not** use **Set password**.

![Credentials tab, with Credential Reset highlighted](images/user-onboarding/15-credentials-tab.png)

**Set password** means you choose the password and then have to pass it on to the person. **Credential Reset** e-mails them a
link so they choose it themselves, and you never see it.

The **Credentials Reset** dialog opens:

![Credentials Reset dialog](images/user-onboarding/16-credential-reset-dialog.png)

1. Set **Reset action** to **Update Password**.
2. Check **Expires In**. The default is **12 hours**. If the person may not open it in time (another time zone, on leave),
   raise it, for example to 72 hours. A link that expires means doing this step again.
3. Check the e-mail address in the page heading one last time.
4. Click **Send Email**. The e-mail goes immediately; there is no preview and no undo.

![Credentials Reset dialog with Update Password selected and Send Email highlighted](images/user-onboarding/17-credential-reset-filled.png)

You should see a green **"Email sent to user."** message. If you get an error instead, the realm's e-mail settings are wrong
or Office 365 refused the message: go back to step 0.

## Step 7: what the user does

1. They receive an e-mail from **CCE Rwanda** (`CCERwanda@medtroniclabs.org`) with a link.
2. The link opens Keycloak, which asks them to choose a password.
3. They then sign in to the dashboard at `https://cceuat.moh.gov.rw/insights/` with their **e-mail address as the username**
   and the password they just chose.

![Insights dashboard sign-in page](images/user-onboarding/19-insights-login.png)

Tell them up front that the username is their e-mail address. The link works once and expires. If it expires, repeat step 6;
nothing else needs redoing.

## Check before you tell the user they are ready

On the user's page in the console, check:

- [ ] the current realm label reads **cce**
- [ ] **Enabled** is on
- [ ] **Required user actions** contains **Update Password** (until the user has set their password)
- [ ] **Role mapping** shows **`INSIGHTS_READ`** tagged **`gateway-service`**
- [ ] sending the e-mail showed **"Email sent to user."**

## Removing access

Open the user and switch **Enabled** off. Don't delete the account: a disabled account keeps its name in the audit trail and
can be switched back on.

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| The user signs in, but the dashboard is empty or shows errors; the gateway logs 403 | `INSIGHTS_READ` is missing | Step 5 |
| No e-mail arrives | the realm cannot send e-mail, or Office 365 refused it | Step 0, then step 6 again. Also ask the user to check their spam folder |
| The e-mail arrives, but the link doesn't work | the link expired or was already used | Step 6 again, with a longer **Expires In** |
| The user cannot sign in to the dashboard at all | the account was created in `master` | Delete it there, then start again from step 2 |
| `INSIGHTS_READ` is not in the list | **Realm roles** was chosen instead of **Client roles** | Open **Assign role** again and choose **Client roles** |
| The user is asked for a password they never set | **Update Password** is missing | Add it under **Required user actions** on **Details**, then step 6 again |
| 403 for every user, including ones that worked before | the gateway loaded an empty or changed `api_permissions` table at start-up | [OPERATIONS-RUNBOOK.md](OPERATIONS-RUNBOOK.md) §11 and §13 |

## On PROD

The steps, realm, client and role are the same. Use:

- admin console `https://cce.moh.gov.rw/auth/admin/`, and dashboard `https://cce.moh.gov.rw/insights/`,
- the PROD admin login: `sudo bash one-click-installer/tools/show-credentials.sh prod --reveal` on the PROD machine.

Users from the old PROD system come back with the Keycloak restore in the PROD install guide (step 9). Check that their
e-mail settings came back too (step 0) before sending anyone a link.

## Notes

- Keycloak's admin console changes between major versions. In particular the missing realm drop-down (step 2) and
  **Assign role** → **Client roles** (step 5) belong to this generation. Re-check the screenshots after a Keycloak upgrade.
- To re-take the screenshots, use a test account and delete it afterwards. Don't use a real person's account: this repository
  is shared.
