# opendash-usage

The Cloudflare Worker behind OpenDash's anonymous usage counts. It stores
each weekly ping as one row in a D1 database: the ISO week, whether it is
the first ping after an install, the OpenDash version and build, the
scooter's generation, model, MoveOS and stock service versions, the head
unit's Android version, and the country Cloudflare saw the request from. No identifier and no IP address
is stored.

## Fakes

The app is open source, so nothing it holds can prove a ping came from a
real scooter. Faking many pings is made to cost work instead, and fakes
are made easy to see:

- every ping carries a 22-bit SHA-256 proof of work over its own text (a
  few seconds on the head unit, done once a week), and each proof is
  accepted once;
- a ping must name the current week, so pings cannot be made in advance;
- one address may send about 5 a minute (Cloudflare's rate limiter keys on
  the address in memory and stores nothing; it is approximate);
- `/v1/stats` counts, per week, how many pings name a version that was
  actually released on GitHub (`released`, null while the repo is private),
  and marks `suspect` a week far above the four before it.

## Test

```bash
node --test server/usage/test.mjs
```

## Deploy

```bash
cd server/usage
npx wrangler login
npx wrangler d1 create opendash-usage        # put the id in wrangler.toml
npx wrangler d1 execute opendash-usage --remote --file schema.sql
# An existing database made before the Android column:
#   npx wrangler d1 execute opendash-usage --remote --file migrations-0002-android.sql
npx wrangler secret put STATS_TOKEN          # any long random string
npx wrangler deploy
```

Set the deployed address followed by `/v1/ping` as the repository secret
`USAGE_PING_URL` (Settings → Secrets and variables → Actions; a variable of
that name works too). It still ends up in every APK.
The release workflow builds it in with `--dart-define=USAGE_PING_URL`;
a build without it (a fork, a local or `deploy.sh` build) sends no ping.
For a release built by hand: `USAGE_PING_URL=… scripts/release.sh <version>`.

## Read the numbers

```bash
curl -s -H "Authorization: Bearer $STATS_TOKEN" https://<worker>/v1/stats | jq
```

Or ask D1 directly:

```bash
npx wrangler d1 execute opendash-usage --remote --command \
  "SELECT week, COUNT(*) users, SUM(new) new FROM pings GROUP BY week ORDER BY week DESC"
```

To drop a burst of fakes after the fact, delete that week's rows whose
`at` falls in the burst.
