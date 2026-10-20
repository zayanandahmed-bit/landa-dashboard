# ReLoop

Business dashboard for a landa clothing wholesale business. It covers the whole flow: **bale in → sort → stock → order → dispatch → paid**.

- **Bales in**: log every bale with its supplier, weight and cost.
- **Sorting**: count pieces live with the A / B / C sensor boxes (or on-screen buttons). A brand popup appears for every piece. You can also type pile totals by hand.
- **Inventory**: live stock by category and grade, with low-stock and "days left" warnings.
- **Orders**: New → Packed → Dispatched → Delivered. Stock is reserved as soon as an order is created. Also has payments, WhatsApp messages and printable slips.
- **Best sellers**: best-selling items, top earners, categories, grades, wholesalers and brands, with trend signals.
- **Alerts**: overdue payments, credit limits, low stock, late dispatch, slow sorting, and stock that isn't moving.

## How it's built

- `index.html` is the whole app: a static page with no build step. GitHub Pages hosts it.
- **Supabase** stores all the data, and nothing is kept in the browser. Every screen syncs live through Realtime.
- Every database object is prefixed `landa_clothing_wholesale_business_` so it never mixes with other apps sharing the same Supabase project.
- **Password lock**: the password's bcrypt hash lives in the database. Unlocking gives the device a login pass for that browser tab only. Without it, row level security returns nothing.

## Setup

1. Open the Supabase SQL editor and run `supabase/setup.sql`.
2. Set the password (run this once, with your own password):
   ```sql
   insert into public.landa_clothing_wholesale_business_access_passwords (id, password_hash)
   values (1, extensions.crypt('YOUR-PASSWORD', extensions.gen_salt('bf')))
   on conflict (id) do update set password_hash = excluded.password_hash, updated_at = now();
   ```
3. Open the site and unlock it.

## Email alerts

Emails are sent **from your own Gmail** by a small Google Apps Script (`email-robot/Code.gs`), so no email password is stored anywhere.

1. Run `supabase/002_email_alerts.sql` in the Supabase SQL editor. Fresh installs already have it in `setup.sql`.
2. Sign in to Google as **zayantechtricks@gmail.com** and open https://script.google.com. Click **New project** and name it "ReLoop email robot".
3. Delete what's in `Code.gs` and paste in `email-robot/Code.gs` from this repo. Save.
4. Pick `setup` in the function dropdown and press **Run**. Allow the permissions it asks for (sending email, and connecting to external services and triggers).
5. Click **Deploy → New deployment**, choose the type **Web app**, and set:
   - **Execute as:** Me
   - **Who has access:** Anyone

   Click **Deploy** and copy the web app URL, which ends in `/exec`.
6. In the dashboard, go to **Settings → Email alerts**, paste the URL and the addresses to send to, then:
   - **Send test email**: checks that sending works.
   - **Connect email robot**: turns on the 9 AM daily digest and the hourly urgent-alert emails.

If you change `Code.gs` later, go to **Deploy → Manage deployments → Edit → Version: New version**. That keeps the same URL.

## AI assistant (Ask AI page)

Ask questions like "who owes me the most?" or "which supplier is worth buying from?" and get answers from your real data.

- It runs through the same Google robot as email. **After updating `email-robot/Code.gs`, paste it into Apps Script and use Deploy → Manage deployments → Edit → New version** (the URL stays the same).
- In the dashboard go to **Settings → AI assistant**, paste your Claude API key (starts with `sk-ant-`) and pick a model, then Save. The key is stored inside your Google robot (Script Properties). It is never kept in the website, the browser or this repository.
- Every question sends a summary of your business data (stock, sales, suppliers, wholesalers, recent orders) to Claude. That data is cached between questions in the same chat to keep the cost down.
- Default model is `claude-opus-5`. `claude-sonnet-5` is cheaper. With Opus, refusals are routed to a fallback model automatically.
- Chats are kept in memory only, so closing the tab clears them.

## Barcodes (journey tracking)

The **Barcodes** tab makes printable labels (codes like `LND-000012`) for a bale, bundle, order or single item. Stick one on, then scan it at every step to record where it is.

- Run `supabase/007_barcode_tracking.sql` then `supabase/008_barcode_lots.sql` once (one table, `landa_clothing_wholesale_business_tracked_barcode_tags`).
- **New barcode** asks for Brand, Product type, Date, Supplier and the counts (A / Washing / Mending / Damaged). It builds a readable item code from them. For example, Abdul Kareem · Patagonia · Fleece Jackets · 2 Oct 2026 · 64 pieces gives `AKPFJ02102026-64`. You can change the code before saving. Saving prints the barcode.
- **Batches and pieces** (`supabase/009_batch_pieces.sql`): New batch can also make one barcode per piece (`AKPFJ02102026-64-01` to `-64-64`). Each piece is linked to its batch and starts with a condition from the counts (A / Washing / Mending / Damaged). Scanning a piece shows its batch and lets you change that piece; the batch's live counts and history update with it. Moving a batch can move all its pieces too.
- When you scan, choose an action: **Update where it is** (step and place), or **Treatment** (Washing / Mending: originally flagged vs recovered).
- **Printing:** works with a 50 × 30 mm sticker printer, or any printer with A4 sticker sheets (3 × 8 labels, 63.5 × 33.9 mm). Print at 100% / "Actual size".
- **Scanning:** a USB or Bluetooth handheld scanner works on any page of the app. You can also use **Scan with camera** on a phone, or type the number into the scan box.
- Each scan opens a pop-up showing the current step and place, when it was last scanned, and the full history. From there you can record the next step, edit the details, remove a wrong history entry, reprint the label or delete it.
- Edit the steps and places in **Settings → Barcode journey**.

## Sensor boxes (ESP32)

Create a box under **Settings → Sensor boxes** to get a device ID and secret key. The box then calls these two functions:

- `POST /rest/v1/rpc/landa_clothing_wholesale_business_sensor_piece_counted` with the body `{"p_device_id","p_device_key","p_grade"}`
- `POST /rest/v1/rpc/landa_clothing_wholesale_business_sensor_undo_piece` with the body `{"p_device_id","p_device_key"}`

Pieces go into whichever bale and category is currently set as **live** on the Sorting screen.
