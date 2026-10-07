# Meta review demo account

Meta's App Review team signs in to production to test Connect Facebook.
RealtorIQ has no password and no self-signup, and the reviewers have no
registered Indian mobile, so production has one demo firm for them.

The account is public: the mobile and the code are written into Meta's form.
Treat it that way. Facebook stays fully usable. Everything else that could
reach a real person, or another firm's data, is refused.

## Sign-in

Mobile `9876754543`, code `888888`. Nothing is sent. The code is still hashed,
expires in 10 minutes, and works once.

Both the mobile and the firm's `review_demo` flag have to match. The same
number on an ordinary firm gets a random code, and that code is delivered.

## Tasks

```bash
bin/rails review_demo:setup
bin/rails review_demo:reset
```

`setup` is idempotent and is allowed in production. It creates or refreshes
only the firm `realtoriq-review-demo` (RealtorIQ Demo, Mumbai / Kharghar), a
12-month live subscription, the super admin Meta Reviewer, and — when the firm
has none — two projects and five sample leads. It prints the firm code. It
does not print the sign-in code.

It aborts, and changes nothing, if `+919876754543` already belongs to some
other firm.

`reset` is for between review rounds. It refuses to run when no firm is
flagged. For the review firm only, it disconnects Facebook (Pages are
unsubscribed at Meta), deletes that firm's leads and its Facebook import, form
and Page rows, then recreates the sample data.

## Guardrails

The review firm cannot:

- send a verification code to a contact channel (the app or the admin panel);
- add a user, or change a user's mobile (name, email and notification mode can still change);
- create a LaunchIQ visit pass.

It is out of the cross-firm marketplace in both directions. Its listings and
leads stay hidden from other firms, and it does not see theirs or their phone
lines. The LaunchIQ project catalog stays visible.

Facebook is not restricted: connect, subscribe, sync, configure a form, and
receive a test lead. Failure alerts go to the demo user's email if one is set.

Those refusals are `403` `demo_account_restricted`, "Not available in the demo account."

## Turning it off

Suspend **RealtorIQ Demo** in the admin panel. Sign-in then returns
`account_suspended`. Un-suspend the firm for the next review. There is no
environment variable.
