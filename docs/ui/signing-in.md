# Signing in

The sign-in screen carries the instance's own name, tagline and logo, a
language switcher, and three boxes.

- **Username.** Usernames are instance-wide. If you were added by an email
  invitation, your username is whatever the invitation set — use the address if
  you are unsure.
- **Password.**
- **2FA code (if enabled).** Leave it blank unless you have set up an
  authenticator. If you have, the code is required and a wrong one fails the
  sign-in exactly as a wrong password does — the message does not say which was
  wrong, on purpose.

The button says `Signing in…` while it works, and will not submit twice.

**The language switcher is above the form for a reason**: the instance answers
in a language before anybody has an account, so you can read the screen in your
own language before signing in. Your choice is remembered in this browser. If an
operator has turned language choice off instance-wide, the switcher is absent
and every reply uses the instance's default.

## First run

A brand-new instance has no accounts at all. The sign-in screen then carries a
collapsed **First run — create the first operator** section: a username and a
password, and `Create operator`. That account is the instance operator; it can
reach [Admin](admin.md) and everything else.

This is only accepted from the machine the server is running on, or with a
bootstrap secret the operator configured. A fresh instance on a network is not
there for the taking.

## Forgotten your password

Under the form, **Forgotten your password?** opens one box: the email address on
your account, and `Send a reset link`.

The answer is always the same — *"If that address has an account, a reset link
is on its way."* — whether or not it does. Nothing is sent to an address that
has not been confirmed, and the screen will not tell you whether an address is
known here.

The link in the message works **once**, and using it signs out every other
session on that account. Set the new password twice; if you have an
authenticator, you then sign in with it as usual.

Asking repeatedly is throttled. So is redeeming a link, which is why a long
series of attempts can come back refused for a while even when you have the
right link — wait, rather than asking for another.

## Activating an invitation

An invitation link opens the console on a `Welcome — finish setting up your
account.` screen: set a password, and you are signed in. Following the link is
what confirms your email address, so no second confirmation is sent.

## Being signed out

Two clocks end a session, and an operator sets both in
[Admin › Session security](admin.md):

- **Idle.** A banner appears before the end — *"Signing you out in Ns for
  inactivity"* — with **Stay signed in**, which makes a real request and so
  really does reset the clock. The countdown is measured from your last
  **request**, not from the last time you moved the mouse, because the server
  measures requests too. When it runs out you land back on the sign-in screen
  with `Signed out for inactivity.`
- **Maximum session.** However active you are, a session ends at this age.
  There is no warning banner for this one.

Either box may be empty, meaning no limit on that axis. A company may tighten
these for its own people and can never loosen them.

**Sign out** in the header revokes the session on the server as well as
forgetting it in this browser. Changing your password on the [Team](team.md)
screen signs out every session including the one you are using, so you sign in
again; machine credentials — API tokens and worker tokens — are deliberately
left alone.
