# Exercise 06: Sending Customer Notifications with Amazon SNS

## Estimated Duration

~30 minutes

## Scenario / Business Context

You have just joined **Acme Retail**, a growing online store. When a customer's
order ships, Acme wants to send them an email that says "Your order is on its
way!" Right now there is no automated way to do this — someone on the team
manually emails customers, which does not scale.

Your job in this exercise is to build the **notification backbone**: a single
place where Acme's systems can "announce" that an order shipped, and have that
announcement automatically delivered to everyone who cares (the customer, and
later maybe a warehouse dashboard or an analytics system). You will do this with
**Amazon SNS**.

> **Amazon SNS (Simple Notification Service)** is a fully managed
> **publish/subscribe** ("pub/sub") messaging service. One system publishes a
> message once, and SNS pushes copies of that message out to many subscribers.

## Learning Objectives

By the end of this exercise you will be able to:

1. Explain the difference between a **topic**, a **publisher**, and a
   **subscriber**.
2. Create an SNS **Standard** topic and explain when you would use Standard vs
   FIFO (First-In-First-Out).
3. Create an **email subscription** and explain why it must be **confirmed**
   before it works.
4. **Publish** a message and validate that it is delivered to a subscriber.
5. Describe **fan-out** (one message, many subscribers) and the role of the
   **topic access policy**.

## AWS Services Used

- **Amazon SNS (Simple Notification Service)** — the pub/sub messaging service.

## Prerequisites

- An **AWS account** you can log into.
- An **IAM (Identity and Access Management) user** with permissions to use SNS.
  **Do not use the root user** for day-to-day work — the root user has
  unrestricted access and should be reserved for account-level tasks only.
- You are working in the **us-east-1 (N. Virginia)** Region. Check the Region
  selector in the top-right corner of the console before you start.
- An **email inbox you control** (for example your work email). You will need to
  open an email and click a confirmation link during this exercise.

---

## Step-by-Step Instructions

### Step 1 — Open the SNS console in the correct Region

1. Sign in to the **AWS Management Console** as your IAM user (not root).
2. In the **top-right corner**, confirm the Region says **N. Virginia**
   (`us-east-1`). If it does not, click it and select **US East (N. Virginia)
   us-east-1**.
3. In the search bar at the top, type **SNS** and click **Simple Notification
   Service**.

> **Why This Matters:** AWS resources are **Region-scoped**. A topic you create
> in `us-east-1` does not exist in `us-west-2`. If a teammate says "I can't find
> your topic," the first thing to check is whether you are both looking at the
> same Region.

### Step 2 — Create a Standard topic

1. In the left navigation pane, click **Topics**.
2. Click **Create topic**.
3. For **Type**, select **Standard**.
4. For **Name**, enter:

   ```
   acme-order-updates
   ```

5. Leave everything else at its defaults.
6. Click **Create topic**.

**What each choice means:**

- **Type = Standard** — Standard topics offer **maximum throughput** and
  **at-least-once** delivery, but do **not guarantee ordering** and may
  occasionally deliver a message more than once. This is perfect for
  notifications like "order shipped."
- **Type = FIFO (First-In-First-Out)** — FIFO topics guarantee **strict
  ordering** and **exactly-once** processing, but have lower throughput and can
  only deliver to SQS FIFO queues (not email). You would choose FIFO only when
  the *order* of messages is critical (for example, financial transactions where
  "debit then credit" must not be reordered).

> **AWS Mental Model:** Think of an SNS topic as a **megaphone** or a radio
> broadcast station. The topic doesn't know or care who is listening. Anyone who
> **subscribes** to the topic hears every announcement. One shout, many
> listeners.

> **Common Beginner Mistake:** Assuming SNS **stores** your messages so you can
> read them later. It does **not**. SNS is a **push** service — when you publish,
> it immediately tries to deliver to current subscribers and then forgets the
> message. If nobody is subscribed (or confirmed) when you publish, the message
> is simply gone. If you need messages to sit and wait to be processed, that is a
> **queue** (Amazon SQS) — see Exercise 07.

**Validation:** After clicking **Create topic**, you should land on the topic's
detail page. Near the top you will see the topic's **ARN (Amazon Resource
Name)**, which looks like:

```
arn:aws:sns:us-east-1:123456789012:acme-order-updates
```

The **ARN** is the globally unique ID for this topic — every AWS resource has
one. `123456789012` is your account number.

### Step 3 — Create an email subscription

A **topic** is the broadcast channel. A **subscription** connects one specific
**subscriber** (an email address, an SQS queue, a Lambda function, etc.) to that
channel.

1. On the `acme-order-updates` topic page, find the **Subscriptions** section
   and click **Create subscription**.
2. For **Protocol**, select **Email**.
3. For **Endpoint**, enter the **email address you control**, for example:

   ```
   you@example.com
   ```

4. Leave the other fields at their defaults.
5. Click **Create subscription**.

**Validation:** You will be taken to the subscription page, and its **Status**
will read **Pending confirmation**.

> **What Is Happening Behind the Scenes?** The moment you created the email
> subscription, SNS sent an email to that address titled **"AWS Notification -
> Subscription Confirmation."** Until you click the confirmation link inside that
> email, SNS will **not** deliver any real notifications to it. This confirmation
> step exists so that someone cannot subscribe *your* email to a topic without
> your consent (which would be a way to spam you).

### Step 4 — Confirm the subscription

1. Open the **inbox** for the email address you used.
2. Find the email from **AWS Notifications** with subject **"AWS Notification -
   Subscription Confirmation."** (Check your spam/junk folder if you don't see it
   within a minute.)
3. Click the **Confirm subscription** link in the email.
4. Your browser will open a page that says **"Subscription confirmed!"**

**Validation:** Go back to the SNS console, refresh the topic's **Subscriptions**
section, and confirm the **Status** now reads **Confirmed** instead of **Pending
confirmation**.

> **Common Beginner Mistake:** Skipping the email confirmation and then wondering
> why "SNS is broken" because no messages arrive. A subscription that is still
> **Pending confirmation** receives **nothing**. Always verify the status is
> **Confirmed** before you test.

### Step 5 — Publish a message

Now you will act as Acme's shipping system and **publish** ("announce") that an
order has shipped.

1. On the `acme-order-updates` topic page, click **Publish message** (top right).
2. For **Subject**, enter:

   ```
   Your Acme order has shipped!
   ```

   (The subject becomes the email's subject line.)
3. Leave **Message structure** as **Identical payload for all delivery
   protocols**.
4. In the **Message body** box, enter:

   ```
   Good news! Order #A-10427 shipped today and should arrive in 3-5 business days.
   Track it anytime in your Acme account. Thanks for shopping with Acme Retail!
   ```

5. Leave the other fields at their defaults.
6. Click **Publish message**.

**Validation:** Within a few seconds to a minute, check your email inbox. You
should receive an email:

- **From:** `no-reply@sns.amazonaws.com` (or a similar AWS SNS sender)
- **Subject:** `Your Acme order has shipped!`
- **Body:** the message text above, followed by a footer with an **unsubscribe**
  link.

If it arrives, you have successfully built a working publish/subscribe
notification pipeline. 🎉

> **AWS Mental Model — Fan-out:** Right now you have one subscriber (your email).
> But the power of SNS is **fan-out**: if you added a second email subscriber, an
> SQS queue, and a Lambda function to this same topic, a **single** `Publish`
> call would deliver to **all of them** at once. The publisher writes the message
> once and never has to know who the recipients are. This decouples the system
> that *produces* an event from the systems that *react* to it.

> **Security Consideration:** Every SNS topic has a **topic access policy** (a
> JSON resource policy attached to the topic). It controls **who is allowed to
> publish to** and **subscribe to** the topic. By default only your own account
> can publish. If you ever need another AWS account or an AWS service (like S3
> event notifications) to publish to your topic, you grant that by editing the
> **Access policy** on the topic — you do **not** hand out your credentials.

> **Cost Awareness:** SNS pricing at this exercise's volume is effectively free.
> The first **1,000 email notifications per month are free**, and API requests
> are billed per million. Sending a handful of test messages costs a fraction of
> a cent. Still, **delete the topic when you are done** (see Cleanup) so you
> don't leave unused resources in your account.

> **Assessment Connection:** In the assessment you may be asked to *choose the
> right service* for a scenario. The signal for **SNS** is: "notify / broadcast /
> push to multiple recipients / fan-out / one-to-many." If instead the scenario
> says "buffer work so a slow worker can process it later / one consumer per
> item," that is **SQS** (Exercise 07). Being able to distinguish
> **push/fan-out (SNS)** from **pull/work-queue (SQS)** is a core objective.

---

## Concept Recap: Key Terms

- **Publisher vs Subscriber** — the **publisher** sends a message to the topic
  (here, Acme's shipping system, played by you clicking *Publish message*). A
  **subscriber** is any endpoint that has subscribed to receive those messages
  (here, your email). The publisher and subscriber never talk to each other
  directly — the topic sits in the middle.
- **Topic vs Subscription** — the **topic** is the channel; a **subscription**
  is one endpoint's registration to receive from that channel. One topic can
  have many subscriptions.
- **Topic vs Queue (forward reference to SQS)** — SNS is **push**: it actively
  delivers to subscribers and does not retain messages. SQS (Exercise 07) is
  **pull**: messages sit in a queue until a consumer explicitly retrieves and
  deletes them. A very common real-world pattern is **SNS → SQS fan-out**, where
  a topic delivers to several queues that each get worked independently.

## Key Takeaways

1. **SNS is publish/subscribe.** A publisher sends once; SNS pushes copies to
   every subscriber.
2. **Standard vs FIFO:** Standard = high throughput, at-least-once, no ordering
   guarantee (great for notifications). FIFO = strict ordering + exactly-once,
   lower throughput, no email endpoints.
3. **Email subscriptions must be confirmed.** They stay **Pending confirmation**
   until the recipient clicks the link; unconfirmed subscriptions receive
   nothing.
4. **SNS does not store messages.** If no confirmed subscriber exists at publish
   time, the message is gone. Use SQS when messages must wait.
5. **Fan-out** lets one published message reach many different subscriber types
   (email, SQS, Lambda) at once, decoupling producers from consumers.
6. The **topic access policy** controls who may publish and subscribe.

## Cleanup Instructions

Leaving these resources in place costs essentially nothing, but good AWS hygiene
means removing what you no longer need. Delete in this order:

1. In the SNS console, go to **Subscriptions** in the left nav.
2. Select the `acme-order-updates` email subscription and click **Delete**,
   then confirm.
3. Go to **Topics** in the left nav.
4. Select `acme-order-updates` and click **Delete**.
5. Type `delete me` in the confirmation box when prompted, and confirm.

**Validation:** The **Topics** and **Subscriptions** lists no longer show any
`acme-order-updates` entries.

---

## Early-Finisher Challenge

Acme wants to reuse **one** topic for several kinds of order events —
`ordered`, `shipped`, `delivered` — but a particular subscriber should **only**
receive `shipped` events. Do this **without** creating extra topics.

**Your task:**

1. Add a **message attribute** named `eventType` when you publish.
2. Add a **subscription filter policy** so your email subscription only receives
   messages where `eventType = "shipped"`.
3. Publish two messages — one with `eventType = shipped` and one with
   `eventType = ordered` — and prove that **only the `shipped` one** arrives in
   your inbox.

---

## Challenge Solution

### 1. Re-create (or reuse) a confirmed email subscription

If you already cleaned up, re-create the topic `acme-order-updates`, add your
email subscription, and confirm it (Steps 2–4 above) so its status is
**Confirmed**.

### 2. Add a filter policy to the subscription

1. In the SNS console, go to **Subscriptions**.
2. Click your email subscription's **Subscription ID** to open it.
3. Click **Edit**.
4. Expand **Subscription filter policy**.
5. Set **Filter policy scope** to **Message attributes**.
6. In the JSON (JavaScript Object Notation) editor, enter:

   ```json
   {
     "eventType": ["shipped"]
   }
   ```

   This tells SNS: "only deliver a message to this subscription if the message
   has an attribute named `eventType` whose value is exactly `shipped`."
7. Click **Save changes**.

### 3. Publish a MATCHING message (should be delivered)

1. Open the `acme-order-updates` topic and click **Publish message**.
2. **Subject:** `Order shipped`
3. **Message body:** `Order #A-10427 has shipped.`
4. Scroll to **Message attributes** and add one:
   - **Type:** `String`
   - **Name:** `eventType`
   - **Value:** `shipped`
5. Click **Publish message**.

**Expected result:** This email **arrives** in your inbox, because the attribute
value matches the filter policy.

### 4. Publish a NON-MATCHING message (should be filtered out)

1. Click **Publish message** again on the same topic.
2. **Subject:** `Order placed`
3. **Message body:** `Order #A-10428 has been placed.`
4. Under **Message attributes**, add:
   - **Type:** `String`
   - **Name:** `eventType`
   - **Value:** `ordered`
5. Click **Publish message**.

**Expected result:** This email does **not** arrive, because `ordered` does not
match the filter policy value `shipped`. SNS evaluated the filter and dropped the
message for this subscription.

> **What Is Happening Behind the Scenes?** SNS evaluates the **filter policy
> against each message's attributes at delivery time**. If the attributes don't
> match, the message is silently skipped for that subscription — no error, no
> retry. This is how one topic can serve many subscribers who each care about
> different subsets of events, avoiding a proliferation of single-purpose topics.

### 5. Validation summary

| Message | `eventType` attribute | Delivered? |
| --- | --- | --- |
| Order shipped | `shipped` | ✅ Yes |
| Order placed | `ordered` | ❌ No (filtered out) |

### 6. Cleanup

Follow the same **Cleanup Instructions** above: delete the subscription, then
delete the topic. The filter policy is deleted along with the subscription.
