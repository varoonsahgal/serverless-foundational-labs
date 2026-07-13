# Lab 05: Customer Authentication with Amazon Cognito User Pools

## Estimated Duration

~90 minutes

## Scenario / Business Context

**Acme Retail** is launching a fully authenticated customer account system. Shoppers need to:

1. **Sign up** with their email and a password.
2. **Verify** their email address (or be confirmed by an admin).
3. **Sign in** and receive tokens they can use to call protected API endpoints.
4. Belong to **user groups** (Admins vs. Customers) that grant different permissions.

The engineering team needs to deliver this without writing password hashing, token signing, email verification flows, or refresh logic from scratch. Your job is to build all of this using **Amazon Cognito User Pools**.

Additionally, by the end of this lab you will **connect Cognito to your API Gateway from Lab 04** — so only authenticated users can place orders.

> **Real-World Parallel:** Cognito User Pools are conceptually similar to Auth0, Firebase Authentication, or Okta — a managed identity provider. The key AWS-specific advantage is native integration with API Gateway, AppSync, ALB, and IAM. You get a managed auth system that plugs directly into your AWS architecture.

```
                      ┌─────────────────────────────────┐
                      │     Amazon Cognito User Pool     │
                      │                                  │
  Customer ──Sign up──► Sign-up / verification email     │
            Sign in──► Password check + MFA (optional)  │
                      │      │                           │
                      │      ▼                           │
                      │  Issues 3 JWTs:                  │
                      │  • ID Token (who you are)        │
                      │  • Access Token (what you may do)│
                      │  • Refresh Token (stay logged in)│
                      └──────┬──────────────────────────┘
                             │
                             ▼  (Access Token in Authorization header)
                      ┌─────────────────────────────────┐
                      │   API Gateway JWT Authorizer     │
                      │   Validates token signature,     │
                      │   expiry, audience, issuer       │
                      └──────┬──────────────────────────┘
                             │ (if valid)
                             ▼
                      ┌─────────────────────────────────┐
                      │       Lambda Backend             │
                      │  (POST /order, GET /order/{id})  │
                      └─────────────────────────────────┘
```

## Learning Objectives

By the end of this lab you will be able to:

1. Distinguish a **User Pool** from an **Identity Pool** and explain when to use each.
2. Create a Cognito User Pool with email sign-in, a password policy, and self-service sign-up.
3. Add **custom attributes** (`custom:shippingAddress`, `custom:loyaltyPoints`) to a user pool.
4. Create **User Pool Groups** (`Admins`, `Customers`) and add users to them.
5. Create and confirm a user via the console (admin path) and optionally via the Hosted UI.
6. Explain the three JWT types: ID token, access token, refresh token.
7. Decode a Cognito JWT to inspect its claims.
8. Attach a **Cognito JWT Authorizer** to your API Gateway HTTP API from Lab 04.
9. Explain User Pool Triggers (Pre-Sign-Up, Post-Confirmation, Pre-Token-Generation).
10. Configure App Client OAuth settings and explain the Hosted UI flow.

## AWS Services Used

- **Amazon Cognito** (User Pools)
- **Amazon API Gateway** (HTTP API — from Lab 04)
- **AWS IAM**
- Cognito's built-in email delivery (for verification codes)

## Prerequisites

- An AWS account signed in as an **IAM user** (not root).
- Region set to **US West (Oregon) `us-west-2`** throughout this lab.
- A real email address you can receive mail at.
- **Recommended:** Complete Lab 04 first. The last part of this lab ties Cognito to the `acme-checkout-api` you built there. You can still complete most of this lab independently if you skipped Lab 04.

---

## Part 1: Understand the Building Blocks

### 1.1 User Pool vs. Identity Pool

These two Cognito features are constantly confused. Learn this clearly:

| | User Pool | Identity Pool (Federated Identities) |
|---|---|---|
| **Purpose** | Managed user directory + authentication | Exchange a proven identity for temporary AWS credentials |
| **Answers** | *Who are you?* | *What AWS resources can this identity touch?* |
| **Issues** | JWTs (ID, Access, Refresh tokens) | Temporary AWS access keys (via STS) |
| **Use case** | App login, sign-up, user management | Mobile app that reads from S3 or writes to DynamoDB directly |
| **Used in this lab?** | ✅ Yes | ❌ No |

> **AWS Mental Model:** A **User Pool** is like Acme's **HR department** — it knows who all the employees (customers) are, checks their credentials, and issues them a badge (JWT). An **Identity Pool** is like a **keycard system** — it takes the badge, looks up what doors this person is allowed to open, and gives them a temporary keycard (AWS credentials) with exactly those permissions.

### 1.2 Authentication vs. Authorization

| Concept | Question answered | Cognito role |
|---|---|---|
| **Authentication** | *Who are you?* (prove identity) | User Pool authenticates — checks password, issues tokens |
| **Authorization** | *What are you allowed to do?* | NOT done by Cognito alone — done by API Gateway authorizer, IAM policies, or your app code |

**Concrete example:** Cognito tells your API "this is customer@acme.com." It does NOT tell your API whether that customer is allowed to call `DELETE /order/{id}`. That decision lives in your Lambda or in API Gateway's route-level authorization.

### 1.3 The Three JWT Tokens

When a user signs in successfully, Cognito issues three tokens:

| Token | Purpose | Typical Lifetime | What it contains |
|---|---|---|---|
| **ID Token** | Proves *who* the user is | ~1 hour | Email, name, `sub` (user ID), custom attributes, group memberships |
| **Access Token** | Proves the user may *access protected resources* | ~1 hour | `sub`, `username`, scopes, group memberships — but NOT email/custom attributes |
| **Refresh Token** | Obtains new ID + Access tokens without re-login | ~30 days (configurable) | Opaque token — you pass it back to Cognito to get fresh tokens |

> **Which token do you pass to API Gateway?** The **Access Token** — it's the authorization credential. The ID Token is for your app to know *who* the user is (display their name, etc.). Never use the Refresh Token anywhere except when calling Cognito's token endpoint to get new tokens.

> **Common Beginner Mistake:** Sending the ID Token to your API as the authorization header. While API Gateway's JWT authorizer can technically validate either, the semantic convention is: ID Token = identity (for the app to read), Access Token = authorization (for backends to validate). Always use the Access Token for API authorization.

---

## Part 2: Create the User Pool

### 2.1 Open Cognito

1. In the AWS Console search bar, type **Cognito** and open **Amazon Cognito**.
2. Confirm **Oregon (us-west-2)** in the top-right.
3. Click **Create user pool** (or **Get started** if shown on the landing page).

> **Console note:** The Cognito "Create user pool" wizard was redesigned in 2024. The current flow is application-first — it asks about your app type before asking about pool settings. Many configuration options (password policy, MFA, custom attributes) are now configured **after** the pool is created, not during the wizard. The steps below reflect the current console.

### 2.2 Run the Create User Pool Wizard

The wizard has four screens. Work through them in order.

**Screen 1 — Define your application:**

1. Under **Application type**, select **Traditional web application**.
2. Under **Name your application**, type `acme-web-client` — this becomes the **app client** name.

> **App client vs. user pool name:** The wizard names the *application* (app client), not the pool itself. The pool name is set separately after the wizard completes. Look for a field labeled **User pool name** or edit it once the pool is created.

**Screen 2 — Configure options:**

3. Under **Options for sign-in identifiers**, select **Email** — customers sign in with their email address.
4. Under **Required attributes for sign-up**, keep **email** selected (it is selected by default when you choose email sign-in). Do **not** add other required attributes here.

> **Sign-in identifier vs. required attribute:** Selecting **Email** as a sign-in identifier means Cognito treats each user's email as their unique username. Cognito automatically sets `email` as a required attribute when you do this. Any other standard attributes you add as "required" will be prompted for in the Hosted UI sign-up form.

**Screen 3 — Add a return URL:**

5. Enter `http://localhost:3000` as the **Return URL** (the callback URL the Hosted UI will redirect to after authentication — a placeholder for this lab).

**Screen 4 — Review and create:**

6. Review the summary. Confirm: application type = Traditional web application, app client name = `acme-web-client`, sign-in identifier = email.
7. Click **Create your application** (the button may say **Create** or **Create user pool** in some console versions).

**Validation:** You land on the user pool overview page. The pool has an auto-generated **User pool ID** like `us-west-2_AbCdEf123`. Note the pool name — it is usually derived from your app name. Click **App clients** in the left nav to confirm `acme-web-client` exists.

> **What is an App Client?** An app client represents one application (your web storefront) that is allowed to interact with the pool. Each client has its own **Client ID** (a public identifier, like a username for your app), allowed OAuth flows, token lifetimes, and optionally a client secret. The `acme-web-client` we named during creation is already configured.

---

### 2.3 Configure Password Policy

Password policy is now configured on the pool settings page, **after** pool creation.

1. Inside your user pool, find the left navigation or the tabs along the top. Look for **Sign-in experience** or **Policies**.
2. Find the **Password policy** section and click **Edit**.
3. Select **Cognito defaults** (minimum 8 characters, requires uppercase, lowercase, number, and special character). These are good defaults for a retail app.
4. Click **Save changes**.

> **Security Consideration:** The default policy enforces reasonably strong passwords. For production, also consider enabling **compromised credentials check** under Advanced Security Features (ASF) — this checks passwords against known data breach lists. ASF costs extra but is highly recommended for customer-facing apps.

---

### 2.4 MFA (Multi-Factor Authentication)

MFA is also configured post-creation.

1. Still in your user pool, find **Multi-factor authentication** (under **Sign-in experience** or its own section).
2. Click **Edit**.
3. Select **No MFA** (for this lab).
4. Click **Save changes**.

> **Security Consideration — MFA Off is Lab-Only:** In production, always enable MFA at minimum as **Optional** (users can opt in). TOTP (Time-based One-Time Password) via Google Authenticator or Authy is the most common option. SMS MFA requires an SNS configuration. Turning off MFA here is a deliberate teaching simplification.

---

### 2.5 Verify Self-Service Sign-Up and Email Delivery

1. In the pool, find **Sign-up experience** (in the left nav or tabs).
2. Confirm **Self-service sign-up** is **Enabled** — this allows customers to register themselves without an admin creating each account. It is enabled by default.
3. Under **Messaging** → **Email**, confirm the email provider is set to **Send email with Cognito** (the built-in sandbox sender).

> **Cost Awareness:** The built-in Cognito email sender is **rate-limited to ~50 emails per day** and is intended for development only. For production, configure **Amazon SES (Simple Email Service)** as the email provider under the Messaging settings — this gives you production-grade delivery, custom from-addresses (e.g., `no-reply@acme.com`), and detailed delivery metrics.

---

### 2.6 Add Custom Attributes

Custom attributes are added **after pool creation** via the Sign-up menu. They cannot be deleted or renamed once created.

1. In the pool, click the **Sign-up** section in the left nav (it may be labeled **Sign-up experience**).
2. Find the **Custom attributes** section and click **Add custom attributes**.
3. Add attribute 1:
   - **Name:** `shippingAddress` (Cognito will prefix it as `custom:shippingAddress`)
   - **Type:** String
   - **Mutable:** Yes (customers can update their address)
   - Leave Min/Max blank.
4. Add attribute 2:
   - **Name:** `loyaltyPoints` (stored as `custom:loyaltyPoints`)
   - **Type:** Number
   - **Mutable:** Yes
5. Click **Save changes**.

> **Important Constraint:** Custom attributes **cannot be deleted or renamed** after they are added to the pool. Mutability (mutable vs. immutable) is also fixed at creation time. Treat custom attribute definitions like database schema migrations — they cannot be rolled back. Always design your attribute schema carefully before adding users to a production pool.

> **Note on console placement:** In some console versions, custom attributes are found under **User pool → Sign-up experience → Custom attributes** or under the pool's **Attributes** section. Match on intent — look for a "Custom attributes" heading with an "Add" or "Create" button.

**Validation:** Refresh the Sign-up section. You should see `custom:shippingAddress` (String, mutable) and `custom:loyaltyPoints` (Number, mutable) listed under Custom attributes.

---

## Part 3: Configure the App Client

### 3.1 Review App Client Settings

1. In your user pool, click **App clients** in the left nav (you may see it directly or under an **App integration** section — look for it by name).
2. Click **acme-web-client**.

> **Note on pool name:** The new Cognito wizard names the pool automatically based on the app name (e.g., `acme-web-client_pool` or similar). The pool is accessible via its **User Pool ID** (e.g., `us-west-2_AbCdEf123`). When this lab refers to "`acme-user-pool`", substitute the name shown in your console. You can optionally rename the pool from the pool's **User pool properties** section if you want it to match exactly.

Here you can review:
- **Client ID** — a public identifier your frontend uses to authenticate with Cognito.
- **Authentication flows** — which flows are permitted. For a web app, `USER_PASSWORD_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH` are standard.
- **Token validity** — ID and Access tokens default to 1 hour; Refresh token defaults to 30 days. These are configurable.

### 3.2 OAuth Settings and Hosted UI

The Hosted UI is a ready-made sign-in/sign-up web page hosted by AWS. No frontend code needed for testing.

1. Still on the `acme-web-client` detail page, find **Hosted UI** or **Login pages**.
2. Under **Allowed callback URLs**, confirm `http://localhost:3000` is listed.
3. Under **OAuth 2.0 grant types**, verify **Authorization code grant** is enabled (this is the standard OAuth flow).
4. Under **OpenID Connect scopes**, verify `openid` and `email` are enabled.
5. If any of the above are missing, click **Edit** to add them and **Save changes**.

> **AWS Mental Model — OAuth Flows:**
> - **Authorization Code Grant:** The app redirects the user to the Cognito Hosted UI, the user logs in, Cognito redirects back with an authorization code, and the app exchanges the code for tokens via a server-side call. This is the **most secure** flow because tokens never touch the browser URL bar.
> - **Implicit Grant (legacy):** Tokens are returned directly in the redirect URL. Considered less secure; avoid in new apps.
> - **Client Credentials:** Machine-to-machine (no user involved). Used for service-to-service calls.

---

## Part 4: User Pool Groups

Groups allow you to segment users and include group membership as a claim in their tokens. This is how you implement role-based access control with Cognito.

### 4.1 Create the Admins Group

1. In your user pool, click **Groups** in the left nav (it may appear as a tab or a direct menu item depending on console version).
2. Click **Create group**.
3. **Group name:** `Admins`
4. **Description:** `Acme Retail administrator accounts with elevated privileges`
5. **Precedence:** `1` (lower number = higher precedence when multiple groups are assigned to a user)
6. Leave **IAM role** blank for now.
7. Click **Create group**.

### 4.2 Create the Customers Group

1. Click **Create group** again.
2. **Group name:** `Customers`
3. **Description:** `Standard Acme Retail customer accounts`
4. **Precedence:** `2`
5. Click **Create group**.

> **What Is Happening Behind the Scenes? — Group Claims in Tokens:** When a user who belongs to one or more groups signs in, Cognito includes their group memberships in the `cognito:groups` claim inside both the ID token and the access token. Your Lambda or API Gateway can inspect this claim to enforce role-based authorization — e.g., only allow requests where `cognito:groups` contains `"Admins"` to reach `DELETE /product/{id}`.

---

## Part 5: Create and Manage Users

### 5.1 Create an Admin User

1. In your user pool, click **Users** in the left nav.
2. Click **Create user**.
3. Configure:
   - **Invitation:** **Don't send an invitation** (no email needed for admin-created users in this lab).
   - **Email address:** `admin@acme.com`
   - **Mark email as verified:** ✅ Check this.
   - **Password type:** **Set a permanent password**
   - **Password:** `AcmeAdmin123!` (meets the policy)
4. Click **Create user**.

### 5.2 Create a Customer User

1. Click **Create user** again.
2. Configure:
   - **Email address:** `customer1@acme.com`
   - **Mark email as verified:** ✅ Check this.
   - **Password type:** **Set a permanent password**
   - **Password:** `Customer123!`
3. Click **Create user**.

### 5.3 Assign Users to Groups

**Assign admin@acme.com to Admins:**
1. Click on **admin@acme.com** in the Users list.
2. Scroll to the **Groups** section → click **Add user to group**.
3. Select **Admins** → confirm.

**Assign customer1@acme.com to Customers:**
1. Click on **customer1@acme.com**.
2. **Add user to group** → select **Customers** → confirm.

### 5.4 Set Custom Attribute Values

1. Click **admin@acme.com**.
2. Find **User attributes** → click **Edit**.
3. Set:
   - `custom:shippingAddress` = `1 Acme HQ Drive, Portland, OR 97201`
   - `custom:loyaltyPoints` = `5000`
4. Click **Save changes**.

Repeat for **customer1@acme.com**:
- `custom:shippingAddress` = `42 Retail Lane, Seattle, WA 98101`
- `custom:loyaltyPoints` = `150`

**Validation:** On each user's detail page, confirm the custom attributes are visible under **User attributes**.

---

## Part 6: User Pool Triggers (Conceptual Overview)

Cognito User Pool **Triggers** are Lambda functions that Cognito invokes at specific points in the authentication lifecycle. They let you customize behavior without forking the authentication flow.

| Trigger | When it fires | Common uses |
|---|---|---|
| **Pre-Sign-Up** | Before a new account is created | Block sign-ups from certain email domains; auto-confirm users |
| **Post-Confirmation** | After a user confirms their email | Send a welcome email; write the user to DynamoDB; kick off onboarding |
| **Pre-Token-Generation** | Before Cognito issues tokens | Add custom claims to the token (e.g., include a user's `loyaltyTier` from DynamoDB) |
| **Post-Authentication** | After a successful sign-in | Log sign-in events; update a "last seen" timestamp |
| **Custom Message** | Before sending any Cognito email/SMS | Customize the verification email template |
| **User Migration** | When a user isn't found in the pool | Look them up in a legacy system and migrate them automatically |

> **Why This Matters — Pre-Token-Generation:** The most powerful trigger for API-building is **Pre-Token-Generation**. It lets you add claims to the token that aren't in Cognito natively — for example, reading a user's subscription tier from DynamoDB and injecting `"subscriptionTier": "premium"` into the token. Your Lambda can then read this claim from the JWT without a database query.

> **Cost Awareness:** Each trigger invocation is a Lambda invocation. For a high-volume sign-in flow (thousands of logins/second), trigger costs add up. Keep Pre-Token-Generation triggers lightweight — they run on every sign-in.

We won't configure a trigger in this lab, but understanding their existence is important for designing real Cognito-backed systems.

---

## Part 7: Use the Hosted UI to Sign In

### 7.1 Open the Hosted Login Page

1. In your user pool, go to **App clients** (left nav) → click **acme-web-client**.
2. Find the **Hosted UI** section and click **View login page** (or copy the Hosted UI URL).
3. A browser tab opens showing the Cognito-managed sign-in page.

### 7.2 Sign In as customer1

1. Enter:
   - **Email:** `customer1@acme.com`
   - **Password:** `Customer123!`
2. Click **Sign in**.
3. Cognito will redirect to `http://localhost:3000/?code=XXXXXXXX` — this is the authorization code.

> **What Is Happening Behind the Scenes?** In the Authorization Code Grant flow, Cognito sends a **short-lived authorization code** (not the tokens directly) to the callback URL. Your server-side app would then exchange this code for the actual ID, Access, and Refresh tokens via a POST request to Cognito's `/oauth2/token` endpoint. The code is single-use and expires in minutes.

> **Why not tokens directly in the URL?** The Authorization Code Grant protects tokens from browser history, referer headers, and log files. The code is worthless by itself — only your backend (with the client secret) can exchange it for tokens.

For this lab, you don't need to complete the token exchange — seeing the `code=` in the redirect confirms authentication worked.

---

## Part 8: Decode a Cognito JWT (Optional Deep Dive)

You can sign in using the AWS CLI to retrieve actual tokens and inspect them.

### 8.1 Sign In via CLI

Run this command (replace the `--client-id` with your actual app client ID from the console):

```bash
aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=customer1@acme.com,PASSWORD=Customer123! \
  --client-id YOUR_APP_CLIENT_ID \
  --region us-west-2
```

The response contains:
```json
{
  "AuthenticationResult": {
    "AccessToken": "eyJraWQiOiJ...",
    "ExpiresIn": 3600,
    "TokenType": "Bearer",
    "RefreshToken": "eyJjdHkiOiJ...",
    "IdToken": "eyJraWQiOiJ..."
  }
}
```

### 8.2 Decode the ID Token

Copy the `IdToken` value and decode it at [https://jwt.io](https://jwt.io) (paste into the "Encoded" field — never paste real production tokens into third-party sites).

You will see claims like:
```json
{
  "sub": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "email": "customer1@acme.com",
  "cognito:username": "customer1@acme.com",
  "cognito:groups": ["Customers"],
  "custom:shippingAddress": "42 Retail Lane, Seattle, WA 98101",
  "custom:loyaltyPoints": "150",
  "iss": "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_AbCdEf123",
  "aud": "YOUR_APP_CLIENT_ID",
  "exp": 1752331200,
  "iat": 1752327600
}
```

Key claims to understand:
- `sub` — the immutable unique user identifier in Cognito.
- `cognito:groups` — group memberships.
- `custom:*` — your custom attributes.
- `iss` (Issuer) — the Cognito User Pool URL. API Gateway uses this to verify the token was issued by your pool.
- `aud` (Audience) — the App Client ID. API Gateway verifies the token was issued for your specific app.
- `exp` (Expiration) — Unix timestamp. API Gateway rejects expired tokens.

> **Security Consideration:** JWTs are **signed** (using RS256 — RSA + SHA256) but **not encrypted**. Anyone who gets the token can decode its claims (they're just Base64-encoded). Never put secrets in JWT claims. The signature is what makes them trustworthy — only Cognito's private key can produce a valid signature, and anyone can verify it using Cognito's public keys (available at the JWKS endpoint).

---

## Part 9: Connect Cognito to API Gateway (JWT Authorizer)

This section ties Labs 04 and 05 together. You will protect the `POST /order` route so only authenticated Acme customers can place orders.

### 9.1 Create the JWT Authorizer

1. Open **API Gateway**.
2. Select **acme-checkout-api**.
3. In the left nav, click **Authorization**.
4. Click **Add authorizer**.
5. Configure:
   - **Authorizer type:** `JWT`
   - **Name:** `acme-cognito-authorizer`
   - **Identity source:** `$request.header.Authorization` (API Gateway will look for a `Bearer` token in the `Authorization` header)
   - **Issuer URL:** `https://cognito-idp.us-west-2.amazonaws.com/us-west-2_AbCdEf123` — replace with your actual **User Pool ID** (visible on the pool overview page).
     - Format: `https://cognito-idp.REGION.amazonaws.com/POOL_ID`
   - **Audience:** your **App Client ID** (from App clients in the pool — a long random string like `1abc2defgh3ijk4lmno5pqr`).
6. Click **Create**.

> **What Is Happening Behind the Scenes?** API Gateway fetches Cognito's **public keys** (JWKS — JSON Web Key Set) from the issuer URL and uses them to verify the JWT signature on every incoming request. It also checks that the `aud` claim in the token matches your configured Audience, that the token hasn't expired (`exp`), and that the issuer matches. All of this happens **without** API Gateway ever calling Cognito — JWTs are self-verifying.

### 9.2 Attach the Authorizer to POST /order

1. Still in **Authorization**, click the **Attach authorizers to routes** tab (or navigate to **Routes → POST /order**).
2. Find the `POST /order` route.
3. Click **Attach authorizer** and select **acme-cognito-authorizer**.
4. Click **Attach**.

> The `GET /products` route intentionally remains **unauthenticated** — Acme wants anyone (including unauthenticated visitors browsing the catalog) to view products. Only order placement requires a signed-in account.

### 9.3 Test the Protected Route

**Without a token (should fail):**
```bash
curl -s -X POST \
  https://YOUR-API-ID.execute-api.us-west-2.amazonaws.com/order \
  -H "Content-Type: application/json" \
  -d '{"customerId":"CUST-001","items":[]}' | python3 -m json.tool
```
Expected: `{"message": "Unauthorized"}` with HTTP 401.

**With a valid token:**
First, get an Access Token:
```bash
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=customer1@acme.com,PASSWORD=Customer123! \
  --client-id YOUR_APP_CLIENT_ID \
  --region us-west-2 \
  --query 'AuthenticationResult.AccessToken' \
  --output text)

echo "Token: ${TOKEN:0:50}..."
```

Then call the API with the token:
```bash
curl -s -X POST \
  https://YOUR-API-ID.execute-api.us-west-2.amazonaws.com/order \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{
    "customerId": "CUST-001",
    "items": [{"productId": "P001", "name": "Wireless Headphones", "price": 79.99, "quantity": 1}]
  }' | python3 -m json.tool
```
Expected: HTTP 201 with a valid order confirmation.

**Validate Step 9:** Confirm that:
1. A request without a token returns `401 Unauthorized`.
2. A request with a valid Cognito Access Token returns `201 Created`.
3. `GET /products` (no auth) still returns products without a token.

---

## Key Takeaways

- **User Pool = managed user directory + authentication.** Identity Pool = temporary AWS credentials. They solve different problems.
- **Authentication ≠ Authorization.** Cognito proves who you are; your app or API Gateway authorizer decides what you may do.
- **Three JWTs:** ID (who you are, for the app to read), Access (authorization credential, pass to APIs), Refresh (get new tokens without re-login).
- **JWTs are signed, not encrypted** — claims are readable by anyone; the signature proves authenticity.
- **Custom attributes** are defined at pool creation and cannot be removed — design deliberately.
- **User Pool Groups** inject `cognito:groups` into tokens, enabling role-based access in your backend.
- **Triggers** (Pre-Sign-Up, Post-Confirmation, Pre-Token-Generation) let you customize the auth lifecycle with Lambda.
- **JWT Authorizer on API Gateway** validates tokens without calling Cognito — API Gateway fetches Cognito's public keys and verifies signatures locally.
- The **Hosted UI** gives you a working sign-in page without any frontend code.

---

## Challenge Exercises

Solutions are in `05-solutions.md`.

### Challenge 1: Add an Admin User to the Admins Group and Observe Token Claims

Your goal: sign in as `admin@acme.com`, retrieve an Access Token, decode it, and confirm:
1. The `cognito:groups` claim contains `["Admins"]`.
2. The `sub` claim is different from customer1's `sub`.

Then: sign in as `customer1@acme.com`, decode their Access Token, and confirm:
1. `cognito:groups` contains `["Customers"]`.
2. Custom attribute values are **not** in the Access Token (check the ID Token instead — custom attributes appear there).

**Document your findings:** For each user, note the `sub`, `cognito:groups`, and which token type (ID vs. Access) contains the custom attributes.

---

### Challenge 2: Integrate the JWT Authorizer on GET /order/{orderId}

Currently, `GET /order/{orderId}` is unauthenticated. An unauthenticated caller can look up any order ID.

**Your goal:**
1. Attach the `acme-cognito-authorizer` to the `GET /order/{orderId}` route.
2. Verify that an unauthenticated request to `GET /order/ORD-DEMO0001` returns `401`.
3. Verify that an authenticated request (using `customer1@acme.com`'s Access Token) returns the order details.
4. **Bonus:** Modify the `acme-order-status` Lambda to extract the `sub` claim from the `requestContext.authorizer.jwt.claims` in the event and log it — confirming which authenticated user retrieved the order.

---

## Cleanup Instructions

### Delete the JWT Authorizer

1. Go to **API Gateway → acme-checkout-api → Authorization**.
2. Select `acme-cognito-authorizer` → **Delete** → confirm.
3. This detaches the authorizer from all routes.

### Delete the User Pool

1. Go to **Cognito → User pools**.
2. Click your user pool (shown as `acme-user-pool` or the auto-generated name from creation).
3. If deletion protection is enabled: **User pool properties → Deletion protection → Disable** → save.
4. Click **Delete** and type the user pool name to confirm.
5. Deleting the pool removes all users, groups, app clients, and custom attributes.

> **Cost Awareness:** Cognito User Pools are billed per **Monthly Active User (MAU)** — a user who signs in, signs up, signs out, refreshes a token, or has certain token operations performed in a given calendar month. The first 10,000 MAUs per month are free. An idle pool with no activity incurs no charges, but delete it to avoid accidental MAU charges from future testing.
