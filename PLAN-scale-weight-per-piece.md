# Plan: connect the weighing scale so every piece gets its own weight

Started 2026-09-27. Status: waiting on step 1 (port photo) and step 2 (capture the scale output).

## Goal
Put a box on the platform scale. Every time a piece is thrown in, the scale reading goes up. The system takes the new steady reading, subtracts the last steady reading, and saves the difference as that piece's weight. Weights then feed cost per piece, average weight per category and grade, a miscount check, and odd-piece flags.

## What we know
- The user's scale is a platform scale with a 6-digit indicator on a pole (Unit / Tare / Zero keys, WEIGHT/PCS label), like the Wazan.pk one they showed.
- It has a data port. **Type not confirmed yet** (RS-232 9-pin, USB or terminals).
- **Capacity and smallest step not confirmed.** A shirt is ~150-250 g and a jacket ~600-1000 g, so we need steps of about 20 g or less. A 100 kg scale is usually fine, a 300-500 kg one is not.

## Steps
1. [ ] **Identify the port.** User sends a photo of the port and the sticker (capacity, step size).
2. [ ] **Weigh a T-shirt twice** and note the display's smallest step and whether it is stable.
3. [ ] **Capture the scale's output.**
   - Buy a USB to RS-232 adapter with an FTDI chip (~Rs 1,000-2,000, estimate, unchecked).
   - On the scale: Menu > output mode = continuous/stream, baud rate (usually 9600).
   - Plug into the Mac. Either Claude reads it, or the user runs `ls /dev/tty.usb*` then `screen /dev/tty.usbserial-XXXX 9600` and pastes ~20 lines while placing shirts.
4. [ ] **Claude writes the parser** for that exact format and works out how "stable reading" is detected.
5. [ ] **Buy the ESP32 parts:** ESP32, MAX3232 converter (~Rs 300-600, estimate), 5 V charger, IR beam pair. Never connect RS-232 straight to the ESP32; it needs the MAX3232.
6. [ ] **Database change (Claude):** add a weight column to the sorted pieces table and a function the ESP32 can call to attach a weight to a piece. Keep the database at 15 tables.
7. [ ] **ESP32 code (Claude):** count on the IR beam, wait for the scale to settle, compute the difference, send count + weight, reset to zero when the box is emptied, flag "beam fired but weight did not change" (false trigger) and "weight rose but beam did not fire" (missed piece).
8. [ ] **Dashboard (Claude):** show weight per piece, average weight per category, cost per piece from weight, and miscount warnings.
9. [ ] **Test with 100 pieces** against a hand count and a hand weigh. Tune the settle time and the 3 second lockout.
10. [ ] **If the big scale's steps are too coarse:** buy a small load cell scale per box (~20-30 kg, ~1-5 g steps, roughly Rs 3-6k, estimate) and keep the big scale for whole bales.

## Watch out for
- Reading bounces for about a second after a piece lands, so only trust a steady reading.
- Someone leaning on the box changes the reading.
- Emptying the box drops the weight sharply; treat that as a reset, not a piece.
- One scale per box (A, B, C). The current scale is the first test box.
