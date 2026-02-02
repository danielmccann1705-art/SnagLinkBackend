# Snaglist Backend - Development Guide

## Project Overview
Snaglist is a SaaS platform for construction snag/punch list management. The backend is built with Vapor 4 (Swift) and PostgreSQL.

## Architecture
- **Framework**: Vapor 4.89+ (Swift web framework)
- **Database**: PostgreSQL with Fluent ORM
- **Authentication**: JWT tokens
- **Deployment**: Fly.io

## Key Directories
- `Sources/App/Models/` - Fluent database models
- `Sources/App/Controllers/` - Route handlers
- `Sources/App/DTOs/` - Data Transfer Objects (request/response models)
- `Sources/App/Migrations/` - Database schema migrations
- `Sources/App/Services/` - Business logic services
- `Sources/App/Utilities/` - Helper functions

## Running Locally
```bash
# Set environment variables
export DATABASE_URL="postgresql://user:pass@localhost:5432/snaglist"
export JWT_SECRET="your-secret-key"
export BASE_URL="http://localhost:8080"

# Run the server
swift run
```

---

# Future Release Phases

## Phase 1: PWA Foundation (Upcoming)
**Goal:** Enable offline support and installability for the web app.

### Features
- Service worker for offline caching
- Web app manifest for installability
- Offline data sync queue
- Push notification infrastructure
- App shell architecture

### Implementation Notes
- Cache static assets and critical API responses
- Queue completion submissions when offline
- Sync on reconnection with conflict resolution
- Add install prompt UI for mobile users

---

## Phase 3: Engagement & Viral Features (Future)
**Goal:** Drive user engagement and organic growth through completion celebrations and sharing.

### Features
- **Completion Celebrations**
  - Confetti animation on snag completion
  - Progress milestone celebrations (25%, 50%, 75%, 100%)
  - Sound effects (optional, user preference)

- **Call-to-Action (CTA) Components**
  - "Powered by Snaglist" badge on shared views
  - "Try Snaglist Free" CTA after completion
  - Social sharing buttons for completed projects
  - Referral tracking for viral loops

- **Gamification Elements**
  - Streak tracking for daily completions
  - Badges for milestone achievements
  - Leaderboards for teams (optional)

### Implementation Notes
- CTAs should be subtle, non-intrusive
- Track CTA conversion rates for optimization
- A/B test celebration intensities
- Respect user preferences for animations/sounds

---

## Phase 4: Site Manager Verification UI (Future)
**Goal:** Enable site managers to review and approve/reject contractor completion submissions.

### Features
- **Pending Completions Dashboard**
  - List view of all pending completions
  - Filter by project, contractor, date
  - Bulk approve/reject actions
  - Photo comparison view (before/after)

- **Approval Workflow**
  - One-click approve with optional comment
  - Reject with required reason
  - Request additional photos/info
  - Auto-expire stale submissions

- **Notifications**
  - Push/email notifications for new submissions
  - Reminder notifications for pending reviews
  - Status update notifications to contractors

- **Analytics**
  - Average approval time metrics
  - Rejection rate by contractor
  - Completion quality scores

### API Endpoints (Existing)
- `GET /api/v1/completions/pending` - List pending completions
- `GET /api/v1/completions/:id` - Get completion details
- `POST /api/v1/completions/:id/approve` - Approve completion
- `POST /api/v1/completions/:id/reject` - Reject completion

### Implementation Notes
- Build dedicated web UI for site managers
- Support both mobile and desktop views
- Integrate with existing completion models
- Add real-time updates via WebSockets (optional)

---

## Current Release: Phase 2 - QR Codes & Short URLs
**Status:** In Development

### Features Implemented
- Slug field for human-friendly short URLs (e.g., `abc-x7k2m3`)
- QR code generation endpoint
- Frontend QRCodeDisplay component
- Short URL support (`/m/{slug}`)

### API Endpoints
- `GET /api/v1/magic-links/:linkId/qr?size=300` - Generate QR code PNG
