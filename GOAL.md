# Twitter/X Clone

## Goal
Build a pixel-perfect Twitter/X clone. UI must closely match real Twitter (x.com). Production-ready quality.

## Tech Stack
Next.js 15 + TypeScript + Tailwind CSS + Prisma + SQLite

## UI Reference
Real Twitter (x.com).
- Primary color: #1D9BF0
- Dark background: #000 / #15202B
- Layout: 3-column (left nav + center timeline + right sidebar)
- Font: -apple-system, BlinkMacSystemFont, "Segoe UI" system font stack
- Tweet card: circular avatar 48px, username/handle, timestamp, action button row

## Core Features
- [ ] Register / Login / Logout
- [ ] Post tweets (text + image upload)
- [ ] Delete tweets
- [ ] Retweet / Quote tweet
- [ ] Like
- [ ] Bookmark
- [ ] Follow / Unfollow
- [ ] Followers / Following list
- [ ] Profile page (avatar, bio, tweets/replies/likes tabs)
- [ ] Notifications page
- [ ] Search (users + tweets)
- [ ] #hashtag topics
- [ ] @mentions
- [ ] Replies / Comments (nested threads)
- [ ] Responsive (mobile bottom nav / tablet compact sidebar / desktop 3-column)

## Success Criteria
- Score >= 90/100
- UI visually indistinguishable from real Twitter
- Core flow (register → login → post → view timeline) fully working
- One-command `npm install && npm run dev` works

## Rules
- Git commit after each batch of changes, message describes what changed
- Make decisions autonomously, do not stop to ask the user
- Notify user of important decisions via Telegram
- Prioritize fixing the lowest-scoring dimensions
- Append scoring results to .auto-claude/results.jsonl
