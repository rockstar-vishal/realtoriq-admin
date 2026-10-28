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
