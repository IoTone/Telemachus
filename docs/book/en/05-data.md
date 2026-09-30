# Data and migrations


Migrations live in `domain/db/migrations.rkt` as a list applied at startup. Every statement must be dialect-neutral: SQLite now, PostgreSQL as the second target, and the unit suite and both smoke suites honour a pre-set `DATABASE_URL` so that everything runs against either. Verify on PostgreSQL before calling anything done; this book’s authors did, and it caught an int4 overflow, a missing placeholder rewrite and a timestamp format that broke every S3 listing.

Some rules that came from those runs:

- Quote reserved words (`"window"`).

- Time windows are epoch integer columns, not timestamp arithmetic. `CURRENT_TIMESTAMP` has second resolution and its text form differs by dialect; anything that must order “newest first” within a second carries an epoch column of its own. The audit log learned this late: it ordered by its text timestamp and then by a random UUID, so two entries written in the same second came back in an order unrelated to what happened — a review decision could read before the assessment that caused it. Note what was *not* enough: milliseconds. A burst of writes lands inside one tick whatever the unit, so the column is microseconds AND the writer bumps it to stay strictly increasing within the process. A clock reading is not an ordering key.

- Use `ON CONFLICT ... DO NOTHING` or `DO UPDATE` for upserts; both dialects support the syntax with a named conflict target.

- A `hasheq`’s iteration order is not stable across Racket processes. Never depend on it for anything that must be reproducible — JSON written to disk, the order of columns in a generated table.

Unit fixtures come from `test/db-fixture.rkt`: `(fresh-db)` gives a migrated, isolated database — in memory on SQLite, a private schema per fixture on PostgreSQL, because test files run concurrently.

## Files to open

`domain/db/migrations.rkt`, `test/db-fixture.rkt`.
