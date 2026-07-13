# Exercise 05: Add Customer Sign-Up and Sign-In with Amazon Cognito User Pools

## Estimated Duration

~45 minutes

## Scenario / Business Context

**Acme Retail** is launching customer accounts on its online storefront. Shoppers need to **sign up** with an email and password, **sign in**, and have their identities managed securely — without Acme building and maintaining its own password database, hashing logic, email verification flows, or token issuance.

As a new Acme cloud engineer, you will stand up a **managed user directory** using **Amazon Cognito User Pools**. By the end, Acme will have a working pool of customer accounts, an application client for the storefront, and at least one confirmed user — all without writing authentication code by hand.

## Learning Objectives

By the end of this exercise, you will be able to:

- Explain what Amazon Cognito **User Pools** are and what problem they solve.
- Create a user pool using the current (2026) application-centric console flow.
- Configure email sign-in, a password policy, self-service sign-up, and email delivery.
- Create and confirm a user, and explain **Confirmed** vs. **Unconfirmed** status.
- Distinguish a **user pool** from an **identity pool**.
- Distinguish **authentication** from **authorization**.
- Describe the three token types Cognito issues: **ID token**, **access token**, and **refresh token**.

## AWS Services Used

- **Amazon Cognito** (User Pools)
- **AWS Identity and Access Management (IAM)** (your signed-in identity)
- (Cognito's built-in email delivery — no separate service to configure for the lab)

## Prerequisites

- An AWS account.
- An **IAM user** (or IAM Identity Center user) with permissions to use Amazon Cognito. **Do not use the root user.**
- Region set to **US East (N. Virginia) `us-east-1`** in the top-right region selector.
- A real email address you can receive mail at (used to receive the verification code if you test self-service sign-up).

> **Caveat on console labels:** The Cognito "Create user pool" experience was redesigned to be **application-centric** (you start by describing your app). AWS iterates on these screens frequently, so **exact wording, button labels, and step ordering may differ slightly** from what's written here. The *concepts and values* stay the same — match on intent (e.g., "the screen where you choose the sign-in identifier") rather than exact text.

---

## Step 1: Understand the Building Blocks (Read First)

> **AWS Mental Model:** A **user pool** is a **managed user directory + login system**. It stores your customers' accounts, enforces password rules, handles email/phone verification, and issues secure login tokens. Think of it as Acme's outsourced "membership desk" — it knows *who* each customer is and proves it.

> **user pool vs. identity pool:** These are two different Cognito features that beginners constantly confuse.
> - **User pool** = **authentication + user directory.** It answers *"Who are you?"* and manages accounts, sign-up, sign-in, and tokens. **This lab uses a user pool.**
> - **Identity pool** (also called *federated identities*) = **it exchanges a proven identity for temporary AWS credentials** so an app can directly call AWS services (like reading an S3 bucket) on behalf of the user. It answers *"What AWS resources may this identity touch?"*
> You often use them together (user pool to log in, identity pool to grant AWS access), but they are **separate resources**. We only need the user pool here.

> **Authentication vs. Authorization:** **Authentication** = proving *who you are* (logging in). **Authorization** = deciding *what you're allowed to do* once you're known. **Cognito user pools authenticate** — they verify credentials and issue tokens. They do **not**, by themselves, authorize your API calls. To protect an API, you separately configure something like an **API Gateway authorizer** (which validates the Cognito token) or write authorization logic in your application. Keep this distinction sharp — it's a top source of confusion.

---

## Step 2: Create the User Pool

### 2.1 Open Cognito

1. In the AWS Console search bar, type **Cognito** and open the **Amazon Cognito** service.
2. Confirm the region is **US East (N. Virginia) `us-east-1`**.
3. Click **Create user pool**.

### 2.2 Describe your application

The current flow starts by asking about your application so it can pick sensible defaults.

1. **Application type:** choose the option that best matches a storefront frontend.
   - Choose **Single-page application (SPA)** if Acme's storefront is a JavaScript app (React/Vue/etc.).
   - Choose **Traditional web application** if it's a server-rendered site.
   - For this lab, either is acceptable. If unsure, pick **Traditional web application**.
2. **Name your application:** enter the app client name `acme-web-client`.
   - (Some console versions ask for this later on a dedicated "app client" screen — enter the same value there.)
3. **Configure sign-in options / sign-in identifiers:** select **Email**.
   - This makes each customer's **email address** their username/login identifier.
4. **Required attributes for sign-up:** ensure **email** is required.
5. If asked for a **return URL / callback URL** (used by the hosted login page), you may enter `http://localhost:3000` for the lab. This is only needed if you later use the hosted login UI; it's fine to provide a placeholder.

> **What each setting does:** Choosing **email** as the sign-in identifier means Cognito uses the email as the unique login name and can send verification codes to it. Marking **email** as a required attribute guarantees every account has a reachable address for verification and password resets.

### 2.3 Password policy

1. Locate the **password policy** setting.
2. Keep the **Cognito defaults** (typically: minimum 8 characters, and requirements for numbers, special characters, uppercase, and lowercase letters).

> **Security Consideration:** The default policy enforces reasonably strong passwords. In production you can add features like **password history** and **compromised-credentials detection** (part of advanced security features). For the lab, defaults are fine.

### 2.4 Multi-Factor Authentication (MFA)

**MFA = Multi-Factor Authentication** — requiring a second proof (like a code from an authenticator app) in addition to the password.

1. Set MFA to **No MFA** to keep the lab simple.

> **Security Consideration:** **No MFA is for this lab only.** In production, always enable MFA (at minimum **Optional**, ideally **Required** for sensitive apps). MFA is one of the single most effective defenses against account takeover. Turning it off here is a deliberate teaching simplification, not a recommendation.

### 2.5 Self-service sign-up and email delivery

1. Ensure **self-service sign-up** is **enabled** — this lets customers register themselves rather than an admin creating every account.
2. **Email delivery:** choose **Send email with Cognito** (the built-in option).

> **Cost Awareness / Sandbox note:** The built-in **"Send email with Cognito"** option is free but is **rate-limited and intended for testing** (a low daily cap). For production volumes you configure **Amazon SES (Simple Email Service)** instead. Also, while your Cognito email is in this default mode, deliverability is limited — see the Common Beginner Mistake below.

> **Common Beginner Mistake:** Expecting verification emails to reliably reach *any* address while using the default Cognito email sending. In this sandboxed/default mode, delivery is throttled and may be restricted. If your verification email doesn't arrive, you can instead **confirm the user from the console as an admin** (shown in Step 4) — no email needed.

### 2.6 Name and create the pool

1. **User pool name:** `acme-user-pool`.
2. Confirm the **app client name** is `acme-web-client` (enter it now if the console asks here).
3. Review the summary screen and click **Create user pool**.

**Validation for Step 2:** You are returned to the user pools list and see **`acme-user-pool`** with a **User pool ID** like `us-east-1_AbCdEf123`. Click into it — under **App integration → App clients** you should see **`acme-web-client`**.

> **What is an app client?** An **app client** represents one application (web app, mobile app, etc.) that is allowed to interact with the user pool. Each client has its own ID and its own settings (allowed sign-in flows, token lifetimes, callback URLs). Acme's website uses `acme-web-client`; a future mobile app would get its own separate client.

---

## Step 3: Understand the Tokens Cognito Issues

When a user successfully signs in, the user pool issues **three JWTs**. **JWT = JSON Web Token** — a signed, self-describing token that carries claims (facts) about the user and can be verified without a database lookup.

- **ID token** — proves *who the user is*. Contains identity claims (email, sub/user ID, name). Your app reads this to know which customer just logged in. Short-lived (default ~1 hour).
- **Access token** — proves *the user is allowed to access protected resources* (e.g., call your API). Passed to backends/authorizers to grant access. Short-lived (default ~1 hour).
- **Refresh token** — used to **get new ID and access tokens** without making the user log in again. Long-lived (default ~30 days, configurable).

> **Assessment Connection:** Be able to state the purpose of each token in one sentence: *ID token = who you are; access token = what you may access; refresh token = get fresh tokens without re-logging-in.* This trio is commonly tested.

> **Authentication vs. Authorization (reinforced):** Cognito **hands you these tokens** (authentication). Deciding whether the access token is allowed to hit a given API endpoint is **authorization**, done by an API Gateway **Cognito authorizer** or your app — not by the user pool on its own.

---

## Step 4: Create and Confirm a User

You have two options. **Option A** (admin-created user in the console) is the most reliable and requires no email delivery — **use it if you're unsure**. **Option B** uses the hosted login page for true self-service sign-up.

### Option A: Create a user in the console (recommended, no email needed)

1. In `acme-user-pool`, open the **Users** tab.
2. Click **Create user**.
3. Configure:
   - **Invitation message:** choose **Don't send an invitation** (or "Create without sending an invitation") so no email is required.
   - **Email address:** enter `customer1@example.com` (any format-valid address; it need not be real for Option A).
   - **Mark email address as verified:** check this box if offered.
   - **Password:** choose **Set a password**, and select **Set a permanent password** (not temporary). Enter a password that meets the policy, e.g. `AcmeTest123!`.
     - If your console only offers a **temporary password**, that's fine — the user will land in a **"Force change password"** state (explained below).
4. Click **Create user**.

> **What Is Happening Behind the Scenes? — "Force change password":** If a user is created with a **temporary** password, Cognito marks them as needing to change it on first sign-in. Their status shows **FORCE_CHANGE_PASSWORD**. Until they set a permanent password, they can't fully use the account. Setting a **permanent** password (as we did) skips this state and produces a ready-to-use, confirmed account.

**Validation for Option A:** In the **Users** tab, `customer1@example.com` appears with **Confirmed status = Confirmed** (or **Enabled / Confirmed**). That's your success criterion for this lab.

### Option B: Self-service sign-up via the hosted login page (optional)

Cognito can host a ready-made login/sign-up web page for you.

1. In `acme-user-pool`, open **App integration**.
2. Under **App clients**, click **`acme-web-client`**.
3. Find the **hosted UI / Login pages** section and locate the **View login page** link (sometimes shown as a hosted UI URL). If prompted, ensure a **callback URL** (e.g. `http://localhost:3000`) and an **OAuth scope** like `openid` / `email` are set, then save.
4. Click the **View login page** link to open the hosted sign-in page.
5. On that page, click **Sign up**, enter a **real** email you control and a policy-compliant password, and submit.
6. Cognito emails a **verification code** to that address. Enter the code on the confirmation screen.

**Validation for Option B:** Back in the **Users** tab, your email appears with status **Confirmed**. After confirming, signing in on the hosted page redirects to your callback URL with tokens in the URL — evidence that authentication succeeded. (Inspecting those tokens is optional.)

> **Confirmed vs. Unconfirmed:** A newly self-signed-up user is **Unconfirmed** until they prove ownership of their email by entering the verification code (or an admin confirms them). **Unconfirmed** users generally cannot sign in. **Confirmed** means the account is verified and active. An admin can also confirm a user directly: **Users → select the user → Actions → Confirm user**.

---

## Concept Callouts Summary

> **AWS Mental Model:** User pool = a managed user directory + login. It owns the accounts, the passwords, the verification, and the tokens — so Acme doesn't have to.

> **Common Beginner Mistake:** (1) Confusing a **user pool** with an **identity pool** — remember: pool of *users* = login/directory; *identity* pool = AWS credentials. (2) Assuming verification emails will reach any inbox while on the default Cognito email sender — it's throttled/sandbox-limited; use console admin-confirm if email doesn't arrive.

> **Cost Awareness:** Cognito user pools are billed per **Monthly Active User (MAU)** — a user who signs in, signs up, or has a token operation in a month. There is a monthly free tier of active users; a single test user is effectively free. There's no charge for an idle, empty pool, but **delete the pool** when done to be safe.

> **Why This Matters:** Building authentication yourself (password hashing, secure storage, email verification, token signing, refresh logic) is hard and dangerous to get wrong. Managed services like Cognito remove an entire class of security bugs from Acme's plate.

---

## Key Takeaways

- **Cognito user pools** provide a managed user directory with sign-up, sign-in, verification, and token issuance — no custom auth code required.
- A **user pool authenticates** ("who are you?"); it does **not authorize** API calls by itself — that's a separate authorizer or app logic.
- **User pool ≠ identity pool.** User pool = authentication/directory; identity pool = temporary AWS credentials for federated identities.
- An **app client** represents one application allowed to use the pool.
- Sign-in issues three **JWTs**: **ID token** (who), **access token** (what you may access), **refresh token** (get new tokens).
- Users are **Unconfirmed** until verified (email code) or **admin-confirmed**; **Confirmed** = active.
- **MFA off** and **default Cognito email** are lab simplifications, not production practices.

---

## Cleanup Instructions

Delete everything you created.

### Delete the app client (if separately deletable)

1. Go to **Cognito → `acme-user-pool` → App integration → App clients**.
2. Select **`acme-web-client`** and choose **Delete** (confirm by typing the name if prompted).
   - In some console versions the app client is deleted automatically when you delete the pool — that's fine.

### Delete the user pool

1. Go to **Cognito → User pools**.
2. Select **`acme-user-pool`**.
3. Click **Delete**. You may be asked to first **turn off deletion protection** (open the pool → **User pool properties / settings** → disable **Deletion protection**) and/or type the pool name to confirm.
4. Confirm the deletion. Deleting the pool removes all users, the app client, and any hosted UI configuration.

> **Cost Awareness:** An empty pool doesn't cost anything, but deleting it guarantees no future MAU charges and keeps your account tidy.

---

## Early-Finisher Challenge

Add a **custom attribute** named `custom:loyaltyTier` to the user pool, then set its value (e.g., `Gold`) for your user and confirm it appears on that user's attribute list.

> **Important current behavior:** **Custom attributes must be defined when the user pool is created (or added afterward), but once defined they cannot be renamed or deleted, and their properties are largely fixed.** Some console versions let you **add** new custom attributes to an existing pool; others require you to define them during creation. The solution below covers both paths.

---

## Challenge Solution

### Step A: Define the custom attribute

**Path 1 — Add to the existing pool (if your console allows it):**

1. Open **Cognito → `acme-user-pool` → Sign-up experience** (may also appear under **Attributes** or **Sign-up / Attributes**).
2. Find **Custom attributes** and click **Add custom attribute**.
3. Configure:
   - **Name:** `loyaltyTier` (Cognito automatically stores it with the `custom:` prefix, so it becomes `custom:loyaltyTier`).
   - **Type:** **String**.
   - **Mutable:** **Yes** (so you can change a user's tier later). Set this at creation time — mutability can't be changed afterward.
   - Leave min/max length at defaults or set a small range (e.g., 1–20).
4. Save.

**Path 2 — If your console does NOT let you add custom attributes to an existing pool:**

Custom attributes may need to be defined **at pool creation**. In that case:

1. Create a fresh pool (repeat Step 2) but, during creation, look for the **custom attributes** section and add `loyaltyTier` (String, Mutable = Yes) before finishing.
2. Recreate your user in the new pool (Step 4, Option A).

> **Key Takeaway:** Plan your custom attributes **before** creating a user pool. They can't be removed or renamed once created, so treat the initial attribute schema as a deliberate design decision.

### Step B: Set the value on a user

1. Go to **Cognito → `acme-user-pool` → Users** and click **`customer1@example.com`**.
2. In the user's detail page, find **User attributes** and click **Edit**.
3. Locate **custom:loyaltyTier** and set the value to `Gold`.
4. Click **Save changes**.

### Step C: Validate

1. Still on the user's detail page, refresh and view **User attributes**.
2. **Expected result:** you see **`custom:loyaltyTier` = `Gold`** listed among the user's attributes.

That confirms the custom attribute is defined on the pool and populated on the user. (In a real app, if you add this attribute to the app client's **read** attributes, its value would also appear as a claim in the user's **ID token** after sign-in.)

### Cleanup for the challenge

No extra resources are created — the custom attribute lives inside the user pool. When you delete `acme-user-pool` in the main cleanup, the attribute and its values are removed with it. (If you created a second pool via Path 2, delete that pool too, following the same **Delete user pool** steps above.)
