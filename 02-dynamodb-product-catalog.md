# Exercise 02: Build a Product Catalog with Amazon DynamoDB

## Estimated Duration

~35 minutes

## Scenario / Business Context

You are a new cloud engineer at **Acme Retail**, a growing online store. The
product team needs a fast, flexible place to store the product catalog —
things like a product ID, a name, a price, and whether the item is in stock.

The catalog will grow and change often, and the team does not want to manage
database servers or plan capacity in advance. Your job is to store the Acme
Retail product catalog in **Amazon DynamoDB**, a fully managed NoSQL database,
and then read the data back to confirm everything works.

## Learning Objectives

By the end of this exercise you will be able to:

- Explain what a NoSQL key-value database is and how it differs from a
  relational (SQL) database.
- Create a DynamoDB table and choose a partition key.
- Explain the difference between a **partition key** and a **sort key**.
- Choose between **On-demand** and **Provisioned** capacity modes and explain
  why On-demand is a good fit for training.
- Add and view items using the AWS Management Console, including the JSON view.
- Read data using a **Query** and a **Scan**, and explain the cost difference.
- Clean up all resources to avoid ongoing charges.

## AWS Services Used

- **Amazon DynamoDB** — a fully managed NoSQL (non-relational) database service.

## Prerequisites

- An AWS account you can sign in to.
- You are signed in as an **IAM user** (Identity and Access Management user),
  **not** the root user. IAM is the AWS service that controls who can do what.
  Using an everyday IAM user instead of the all-powerful root user is an AWS
  security best practice.
- Your console is set to the **US East (N. Virginia)** Region, whose code is
  **us-east-1**. You can confirm and change the Region using the Region menu in
  the top-right corner of the AWS Management Console.

> **Security Consideration**
> The root user is the email-address login that owns the whole account. It can
> do anything, including closing the account, so AWS recommends you lock it
> away and use IAM users or roles for daily work. If you are unsure which you
> are, look at the top-right of the console: an IAM user shows as
> `username @ account-id`, while the root user shows your account name with the
> word "Root" nearby.

---

## Step-by-Step Instructions

### Step 1 — Open the DynamoDB console

1. Sign in to the AWS Management Console as your IAM user.
2. Confirm the Region menu (top-right) says **N. Virginia** / **us-east-1**. If
   not, click it and select **US East (N. Virginia) us-east-1**.
3. In the search bar at the top, type `DynamoDB` and click the **DynamoDB**
   result. This opens the DynamoDB dashboard.

> **AWS Mental Model**
> DynamoDB is a **key-value** store, not a spreadsheet or a SQL database. You
> look items up by their key, the way you look up a word in a dictionary. There
> are no tables joined together, no `JOIN` statements, and no fixed columns —
> each item is just a bag of attributes identified by its key.

### Step 2 — Create the AcmeProducts table

1. In the left navigation pane, click **Tables**.
2. Click the **Create table** button.
3. For **Table name**, type exactly:

   ```
   AcmeProducts
   ```

4. For **Partition key**, type exactly:

   ```
   productId
   ```

   and set its type to **String** using the dropdown next to it.
5. Leave the **Sort key** empty for this table (we will use one in the
   challenge at the end).

> **What is a partition key?** The partition key is the main identifier for an
> item. DynamoDB runs a hash function on it to decide which physical partition
> (storage location) stores the item. Each `productId` value must be unique in
> this table because it is the entire primary key.

> **What is a sort key?** A sort key is an optional second part of the key. When
> you have one, the primary key becomes the **combination** of partition key +
> sort key. That lets many items share the same partition key while staying
> unique, and DynamoDB keeps them sorted by the sort key. We will see this in
> the early-finisher challenge.

6. Under **Table settings**, keep **Default settings** selected. Default
   settings use **On-demand** capacity mode.

> **AWS Mental Model — On-demand vs Provisioned capacity**
> - **On-demand**: DynamoDB automatically handles however many reads and writes
>   you send, and you pay per request. No capacity planning needed.
> - **Provisioned**: You reserve a fixed number of reads/writes per second in
>   advance and pay for that reservation whether you use it or not.
>
> For training, demos, and unpredictable low traffic, **On-demand** is the best
> choice: there is nothing to size, and with no traffic you pay effectively
> nothing beyond tiny storage costs.

7. Scroll down and click **Create table**.
8. Wait until the table's **Status** shows **Active** (usually well under a
   minute). Click the refresh icon if needed.

> **Validation:** You should see `AcmeProducts` listed in the **Tables** page
> with a status of **Active**.

### Step 3 — Add three product items

1. On the **Tables** page, click the table name **AcmeProducts**.
2. In the top-right of the table page, click **Explore table items**. (You can
   also reach it from the left nav under **Explore items**.)
3. Click **Create item**.
4. The form opens showing `productId` already listed as the required key. Enter
   the values below. To add each extra attribute, click **Add new attribute**
   and pick the correct type.

   **Item 1** (click **Add new attribute** → **String** for `name`, **Number**
   for `price`, **Boolean** for `inStock`):

   | Attribute | Type    | Value        |
   |-----------|---------|--------------|
   | productId | String  | `P001`       |
   | name      | String  | `Coffee Mug` |
   | price     | Number  | `12.99`      |
   | inStock   | Boolean | `true`       |

5. Before saving, click **JSON view** (toggle in the top-right of the item
   editor) to see how DynamoDB actually stores the item:

   ```json
   {
     "productId": { "S": "P001" },
     "name": { "S": "Coffee Mug" },
     "price": { "N": "12.99" },
     "inStock": { "BOOL": true }
   }
   ```

   The short codes are DynamoDB's data types: `S` = String, `N` = Number,
   `BOOL` = Boolean. Toggle **JSON view** off again if you prefer the form.
6. Click **Create item** to save.
7. Repeat **Create item** two more times for these items:

   **Item 2**

   | Attribute | Type    | Value           |
   |-----------|---------|-----------------|
   | productId | String  | `P002`          |
   | name      | String  | `Water Bottle`  |
   | price     | Number  | `8.50`          |
   | inStock   | Boolean | `true`          |

   **Item 3**

   | Attribute | Type    | Value            |
   |-----------|---------|------------------|
   | productId | String  | `P003`           |
   | name      | String  | `Desk Lamp`      |
   | price     | Number  | `24.00`          |
   | inStock   | Boolean | `false`          |

> **Common Beginner Mistake**
> Do **not** think of `productId` as a database "auto-increment" or sequential
> row number. DynamoDB never generates keys for you — **you** supply the key
> value, and it must be unique. Coming from SQL, people also expect columns to
> be predefined; in DynamoDB, only the key attributes are fixed, and every item
> can carry different attributes. There are no `JOIN`s either — you model your
> data around how you will look it up.

> **What Is Happening Behind the Scenes?**
> When you save an item, DynamoDB hashes the `productId` value to pick a
> partition, writes the item there, and replicates it across multiple
> Availability Zones (isolated data centers) for durability — all automatically.

### Step 4 — Read data with a Scan

1. Still in **Explore table items**, look at the **Scan / Query** controls near
   the top. Make sure **Scan** is selected.
2. Click **Run**.
3. You should see all **3 items** listed in the results table.

> **AWS Mental Model — Scan**
> A **Scan** reads **every item in the table** and then filters. It is simple
> but expensive and slow on large tables because you pay to read everything,
> even rows you throw away. Use Scan sparingly.

### Step 5 — Read one product with a Query

1. In the **Scan / Query** controls, switch to **Query**.
2. In the **partition key** field for `productId`, type:

   ```
   P002
   ```

3. Click **Run**.
4. Exactly **1 item** should be returned — the `Water Bottle` (`P002`).

> **AWS Mental Model — Query**
> A **Query** goes straight to the item(s) with a specific partition key. It
> reads only what matches, so it is fast and cheap. Prefer **Query** over
> **Scan** whenever you know the key you are looking for.

> **Cost Awareness — Query vs Scan**
> DynamoDB On-demand billing charges per read/write request measured in
> "read/write request units." A **Scan** consumes read units for every item it
> touches; a **Query** consumes units only for the matching items. On a large
> table a Scan can cost dramatically more than a Query returning the same data.

> **Validation:** You have now confirmed: (a) all 3 items appear in a Scan, and
> (b) a Query for `P002` returns exactly one item. Your catalog reads work.

> **Assessment Connection**
> Certification exams frequently test whether you know that Query is
> key-targeted and efficient while Scan reads the whole table. Remember the
> rule: **"Query when you know the key; Scan only as a last resort."**

---

## Key Takeaways

- **DynamoDB is NoSQL / key-value.** You retrieve items by their key, not with
  SQL joins.
- **The partition key is the primary identifier** and must be unique (unless
  you add a sort key to form a composite key). You always provide it yourself.
- **On-demand capacity mode** removes capacity planning and is ideal for
  training and low or unpredictable traffic.
- **Query is efficient and key-targeted; Scan reads the entire table.** Prefer
  Query.
- The console **JSON view** shows the real stored shape, with type codes like
  `S`, `N`, and `BOOL`.

---

## Cleanup Instructions

To avoid any ongoing storage charges, delete the table you created.

1. Go to the DynamoDB console → **Tables**.
2. Select the checkbox next to **AcmeProducts**.
3. Click **Delete**.
4. In the confirmation dialog, leave the options as they are, type `confirm`
   (or `delete` as prompted) in the text box, and click **Delete table**.
5. Confirm `AcmeProducts` no longer appears in the Tables list.

> **Cost Awareness**
> With On-demand mode and no traffic, an idle table costs only a few cents for
> stored data — but the tidy habit is to **delete resources when done**.
> Deleting the table stops all storage cost immediately.

---

## Early-Finisher Challenge

Design a table that uses a **composite primary key** (partition key + sort key)
to group many related items under one partition.

**Goal:** Create a second table named `AcmeOrders` with:

- Partition key `customerId` (String)
- Sort key `orderId` (String)

Add **2 orders for the same customer** (same `customerId`, different `orderId`),
then **Query by `customerId`** and confirm both orders come back, sorted by
`orderId`.

Try it yourself before reading the solution below.

---

## Challenge Solution

### Steps

1. DynamoDB console → **Tables** → **Create table**.
2. **Table name**:

   ```
   AcmeOrders
   ```

3. **Partition key**:

   ```
   customerId
   ```

   Type: **String**.
4. **Sort key**:

   ```
   orderId
   ```

   Type: **String**.
5. Keep **Default settings** (On-demand). Click **Create table** and wait for
   **Active**.
6. Click **AcmeOrders** → **Explore table items** → **Create item**. Add these
   two items (use **Add new attribute** → **Number** for `total`):

   **Order 1**

   | Attribute  | Type   | Value    |
   |------------|--------|----------|
   | customerId | String | `C100`   |
   | orderId    | String | `O-0001` |
   | total      | Number | `31.49`  |

   **Order 2**

   | Attribute  | Type   | Value    |
   |------------|--------|----------|
   | customerId | String | `C100`   |
   | orderId    | String | `O-0002` |
   | total      | Number | `18.00`  |

7. In **Explore table items**, switch to **Query**. In the **customerId** field
   type:

   ```
   C100
   ```

   Leave the `orderId` sort-key field blank so the Query returns all orders for
   that customer. Click **Run**.

### Why It Works

Because the primary key is the **combination** of `customerId` + `orderId`, the
two items are unique even though they share the same `customerId`. DynamoDB
stores all items with the same partition key **together in one partition**,
physically sorted by the sort key (`orderId`). Querying by just the partition
key returns the whole group — this is the standard NoSQL pattern for "give me
all the orders for this customer." Notice you did **not** need a join; the data
that belongs together is stored together.

### Validation

- The Query for `customerId = C100` returns **exactly 2 items**.
- They appear in ascending `orderId` order: `O-0001` then `O-0002`.

### Cleanup

1. DynamoDB console → **Tables**.
2. Select **AcmeOrders** → **Delete** → confirm the deletion.
3. Verify `AcmeOrders` is gone from the Tables list. (Also confirm
   `AcmeProducts` was deleted earlier.)
