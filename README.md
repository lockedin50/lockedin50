# Locked In 50 · built by Carter

Set your list. Lock it in. 50 days.

A 50-day challenge app for a crew of mates:

- Each person builds their own daily checklist (min 5 items, weighted Easy/Med/Hard) and up to 3 measurable goals (numbers or mm:ss times). Lists and goals lock for 50 days.
- Streaks: days in a row at 100%, front and centre.
- Goal logging with history, charts and personal bests (PBs post to your crews).
- Private daily trackers (calories, water, steps…), never shared or ranked.
- Crews: anyone can start one and invite mates with a code or link (`/?join=CODE`). One person, one list, up to 10 crews. Captains can rename, reset the code and remove members.
- Crew leaderboard (7 days / overall / streak), feed with thumbs ups and comments.
- The Ranks: public crew-vs-crew board (crews with 3+ active members), crew name and score only.

## Stack

- Single-page web app (`index.html`), installable to a phone home screen
- Supabase for shared data. Database setup: `supabase/schema.sql` (run once in the Supabase SQL Editor)
- Netlify for hosting, auto-deployed from this repository

## How access works

- Accounts are a unique username + 6-digit PIN (5 wrong tries = 15-minute lockout).
- Database tables are locked. The app can only call the functions in `supabase/schema.sql`, which check the person's sign-in token; crew data only goes to that crew's members.
- Other people's goals are only ever sent as a percentage. Trackers are only ever sent to their owner.
- Crew names and usernames go through a simple bad-word filter, since crew names appear on the public board.
