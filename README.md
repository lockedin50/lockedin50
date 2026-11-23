# Locked In 50 · built by Carter

Set your list. Lock it in. 50 days.

A 50-day challenge app for a crew of mates:

- Each person builds their own daily checklist (min 5 items, weighted Easy/Med/Hard) and up to 3 measurable goals (numbers or mm:ss times). Lists and goals lock for 50 days.
- Streaks: days in a row at 100%, front and centre.
- Goal logging with history, charts and personal bests (PBs post to your crews).
- Private daily trackers (calories, water, steps…), never shared or ranked.
- Crews: anyone can start one and invite mates with a code or link (`/?join=CODE`). Up to 10 crews per person. Captains can rename, reset the code and remove members.
- Every crew starts from Day 1: joining or starting a crew creates a new 50 days for it. You can copy a list and goals from one you already have (no days or streaks carry over). Up to 5 running at once.
- Crew kick-off date: the captain picks the start day (up to 2 weeks out); everyone who joins before then starts together, late joiners start when they join.
- Crew leaderboard (7 days / overall / streak), feed with thumbs ups and comments.
- The Ranks: weekly crew-vs-crew seasons (Monday to Sunday, Sydney time). Crew score = average of members' daily scores that week; 3+ active members to rank. Last week's winner is crowned Crew of the Week 👑, with past champions listed.

## Stack

- Single-page web app (`index.html`), installable to a phone home screen
- Supabase for shared data. Database setup: `supabase/schema.sql` (run once in the Supabase SQL Editor)
- Netlify for hosting, auto-deployed from this repository

## How access works

- Accounts are a unique username + 6-digit PIN (5 wrong tries = 15-minute lockout).
- Database tables are locked. The app can only call the functions in `supabase/schema.sql`, which check the person's sign-in token; crew data only goes to that crew's members.
- Other people's goals are only ever sent as a percentage. Trackers are only ever sent to their owner.
- Crew names and usernames go through a simple bad-word filter, since crew names appear on the public board.
