# Design Partner Onboarding

Welcome to AdButler. This guide walks you through setup and what to expect in the
first 24 hours.

## Steps

### 1. Connect your Meta account

Go to **Connections** → `/connections/new` and click **Add Connection**. You will
be redirected to Meta's OAuth consent screen. Approve the permissions and you will
be returned to AdButler.

### 2. Wait ~30 minutes for the first insights sync

`InsightsSchedulerWorker` runs every 30 minutes. After your connection is active,
it will begin pulling ad spend and performance data from the Meta Insights API.
You can monitor the sync status on the Connections page — status changes from
`active` once data starts flowing.

### 3. Wait ~7 hours for the first audit run

`AuditSchedulerWorker` runs every 6 hours after the metadata sync completes
(`~5 */6 * * *`). It evaluates all your ad accounts for:

- **Dead spend** — ads spending with zero conversions over 48h
- **CPA explosion** — cost-per-acquisition spiking above 2× your 30-day average
- **Bot traffic** — CTR above 15% (likely invalid traffic)
- **Placement drag** — underperforming placements consuming disproportionate budget
- **Stalled learning** — ads stuck in the learning phase past the expected window

Check `/findings` after ~7 hours from your first connection.

### 4. Receive your daily digest email

`DigestSchedulerWorker` fires at 8am UTC daily. If any high- or medium-severity
findings exist, you will receive an email digest at the address associated with
your account. No email is sent when there are no active findings.

A weekly digest also goes out every Monday at 8am UTC.

### 5. Acknowledge findings to track triage progress

On the `/findings` page, click any finding to open its detail view. Use the
**Acknowledge** button to mark it as triaged. Acknowledged findings remain visible
but are visually distinguished from unreviewed ones.

## Key URLs

| Page | URL |
|---|---|
| Connections | `/connections` |
| Findings inbox | `/findings` |
| Campaigns | `/campaigns` |
| Ad Sets | `/ad-sets` |
| Ads | `/ads` |

## Questions?

Reach out to the AdButler team directly — we are actively collecting feedback
during this design partner phase.
