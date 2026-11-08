# Chat

One prompt box, **Send**, and the conversation below it, newest first.

The heading says which model is answering. A green badge is the configured
model's name. A yellow badge reading **simulated** means no model URL is set on
this instance, so the reply is a deterministic echo of your prompt rather than
an answer — the badge's tooltip says so, and every reply it produces is marked.
This exists so a misconfigured instance cannot pass an echo off as a model's
work; the remedy is for an operator to set `TMACH_MODEL_URL`.

## The character count

Under the box is `N / M characters`. **M is the model's own input budget**, read
from the server, and it is the only number on this screen that can silently
change your answer. Past it the count turns red and says what will happen: a
model server discards the overflow, and what goes first is the instruction at
the top of the request — so an over-long prompt comes back **wrong rather than
refused**. The count is the warning; the server is the authority.

The count is on the [Agent](agent.md) and [Translate](translate.md) prompts for
the same reason, against the same kind of limit.

## Sending

`Enter` sends, `Shift+Enter` inserts a newline. The hint beside the button says
so. An input method's confirming `Enter` does not send.

**One send at a time.** The button shows `Sending…` while an answer is
streaming and a second press does nothing — it used to be possible to bill two
model calls for one click. **Stop** appears while a reply is streaming: it
aborts the request, leaves the partial answer on screen and marks it `stopped`.

Your prompt is cleared only once the request has been **accepted**. A refusal —
a budget, a bad request — leaves the text where you can edit and resend it.

## What it costs, and what it does not leave behind

A reply is metered against the team's `ai.tokens.total` and `ai.requests`
allowances; [Usage](usage.md) reports both, and a reply's own line carries the
tokens it used. A simulated echo is not metered and is not logged as a model
request, because nothing left the process.

**Chat creates no scheduler job.** The answer streams back in the request
itself, so using Chat leaves nothing on the [Jobs](jobs.md) screen. If this
instance routes chat to a worker fleet, the work appears there as a sub-job of
kind `infer.chat` instead.

Chat can be turned off for the instance, a company or a team, in which case the
tab is absent.
