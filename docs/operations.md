# Operations

## Failed background jobs

Solid Queue keeps a job that has used up its retries in
`solid_queue_failed_executions`. `Ops::FailedJobsAlertJob` emails
`OPS_ALERT_EMAIL` (production defaults to realtoriq@kgen.tech) at most once an
hour. Staging sends only when `OPS_ALERT_EMAIL` is set.

Look at them:

```bash
bin/rails runner 'SolidQueue::FailedExecution.includes(:job).order(:created_at).find_each { |row| puts [row[:id], row.job.class_name, row.exception_class].join(" ") }'
```

Retry or discard one. Replace `ID` with an id from the list. `retry` runs the
job again. `discard` deletes it.

```bash
bin/rails runner 'row = SolidQueue::FailedExecution.find(ID); row.retry # or: row.discard'
```

## Rails 8.1 upgrade

Rails 8.1.4. Ruby stays 3.4.1. `config.load_defaults` stays `8.0`.
Deploy before 7 Nov 2026, when Rails 8.0 stops receiving security fixes.

From the release directory, with the environment the process already uses:

```bash
bundle install
bin/rails assets:precompile
```

There is no migration. Active Storage, Solid Queue, and Solid Cache are
already on the schema this code expects. Do not run a migration before
restarting, and do not add the three old Active Storage migrations
`app:update` offered. The create-tables migration already has them, and
reversing those copies would drop columns production uses.

Restart Puma and the Solid Queue workers so both are on 8.1.4.

On the staging box, stop the `bin/rails server` process and the `bin/jobs`
process, then start them the same way as today:

```bash
bin/rails server -e staging
bin/jobs
```

A Kamal deploy does the same inside the image. The Dockerfile runs
`bundle install` and `assets:precompile`. `bin/docker-entrypoint` runs
`db:prepare`, which finds nothing to migrate. `SOLID_QUEUE_IN_PUMA` means
restarting the web container restarts the workers. If a separate `bin/jobs`
process is running, restart that too.

Straight after:

- `GET /up` returns 200.
- A sign-in completes.
- `bin/jobs` is running, or Puma was started with `SOLID_QUEUE_IN_PUMA`.
- The failed-jobs count:

```bash
bin/rails runner 'puts SolidQueue::FailedExecution.count'
```

`Gemfile.lock` is updated locally and stays untracked. An image build copies
that lock and sets `BUNDLE_DEPLOYMENT=1`, so build the image from a tree
that has this lock. A checkout without the lock still resolves
`gem "rails", "~> 8.1.4"`.

### Rollback

Deploy the previous release (Rails 8.0.5.1), run `bundle install`, and
restart Puma and `bin/jobs` the same way. There is no migration to reverse.
