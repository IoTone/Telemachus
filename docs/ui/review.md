# Review

The queue of work a [workflow](workflows.md) parked on a person. Two lists:
**Waiting** and **Decided**.

The tab appears only with the `reviews:read` permission, which a plain member
holds on this platform — reviewing is the specialist's job here, not an admin
act.

## Deciding

An item shows what is under review, the run it belongs to, and a checklist if
the workflow declared one. Three verdicts, and the vocabulary is fixed:

- **Approve** — the run continues down its approve branch.
- **Send back** — the run goes down its revise branch, with your words.
- **Reject** — the run goes down its reject branch, or ends.

**Why — required to send work back or reject it.** Not for a plain approval,
which would only collect a field full of "ok"; the case that has to be
explainable later is the one where work was sent back.

A verdict is **final**. Deciding again is refused — a wrong decision wants a
superseding record, not a rewrite.

## Needs a second reviewer

Some items say `Needs a second reviewer`, and then the person whose work it is
may not decide it. Where the thing under review was produced by a model it has
no human author, so anyone who may decide may decide it — which is what lets a
team of one finish a run.

Somebody else's item that you may not decide is a refusal that says so, rather
than a missing row: the request is fine, you are the wrong person for it.

## What is recorded

Every decision is kept with its author, its verdict, its reason and its
checklist answers, and each one is chained to the one before it so that an
altered or removed record can be detected. **Decided** is that record.

The chain detects a record changed in place, one removed from the middle, and a
rewritten link. It cannot detect a rewrite by somebody who can write the
database itself — closing that needs the external anchor an operator exports,
which is an operator's procedure rather than a screen.
