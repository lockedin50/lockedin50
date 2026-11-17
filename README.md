# Locked In 50 · built by Carter

Set your list. Lock it in. 50 days.

A 50-day challenge app for a crew of mates:

- Each person builds their own daily checklist (min 5 items, weighted Easy/Med/Hard) and up to 3 measurable goals.
- Lists and goals lock for 50 days.
- Daily score = % of your own list completed; leaderboard ranks average score (last 7 days or overall) with streaks.
- Crew feed with posts, thumbs ups and comments; goals shared as % progress only.
- Profile photos, daily motivational quotes, 50-day progress grid.

## Stack

- Single-page web app (`index.html`), installable to a phone home screen
- Supabase for shared data. Database setup: `supabase/schema.sql` (run once in the Supabase SQL Editor)
- Netlify for hosting, auto-deployed from this repository

## How access works

- Joining needs the crew code; each person signs in with a name + 4-digit PIN (5 wrong tries = 15-minute lockout).
- Database tables are locked. The app can only call the functions in `supabase/schema.sql`, which check the crew code or the person's sign-in token.
- Other people's goals are only ever sent as a percentage, never the actual numbers.
