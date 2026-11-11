# Admin

The operator's tab. It appears only for an instance operator, and it is the
only screen that changes what the instance *is* rather than what one team has.

Eight cards: **Branding**, **Theme**, **Localization**, **Session security**,
**Instance features**, **Email delivery**, **Email notifications**, and the
**Workers** and **Queue** cards described in [Workers and the
queue](workers.md). Plus **Testing tools** at the bottom.

## Branding

> The name, tagline and logo this instance wears — on the sign-in screen, in
> the header, and in the browser tab.

**Title**, **Tagline**, **Logo** (with **Remove logo**), **Save** and **Reset
to default**.

An uploaded logo replaces both the mark and the wordmark. With none, the
console falls back to the shipped mark and the title.

This is the **product's** name, which is a different thing from the public
onboarding page's look — that is the [Beta](beta.md) tab's own theme.

## Theme

> The palette this console wears — the same tokens the beta funnel uses.
> Changes preview live; Save applies them for everyone.

**Brand**, **Text on brand**, **Background**, **Panel**, **Text**, **Muted
text**, **Font**, **Corner radius**, **Mode**. A handful of values, not a
stylesheet: each one is a value the console maps onto a custom property, and the
panel shades, lines and accents are derived from them.

**Contrast is enforced, not warned about.** A `Low contrast` marker appears
beside a pair that fails, and:

> Readers may not be able to see this text. The server refuses a theme below
> the minimum.

That is deliberate for this screen and not for the funnel editor: this is the
page people sign in on, and an instance that themed its own sign-in link into
invisibility would have no way back through the UI.

**Reset theme** restores the shipped palette.

## Localization

> The language this instance answers in when a visitor has not chosen one —
> including on the sign-in screen, before anyone has an account.

- **Default language** — validated against what this build ships, so the
  instance cannot advertise a language it cannot render. **Shipped in this
  build** lists them.
- **Let people choose their language** — *"With this off, every reply uses the
  default language and the language switcher disappears."*

Turning it off does not remove the catalogs; turning it back on restores them.
An unknown language asked for by a caller falls back to **the instance
default**, not to English.

## Session security

**Idle timeout (minutes)**, **Maximum session (hours)**, **Warn before
(seconds)**.

> A session ends after this much inactivity, and after the maximum age however
> active it is. Leave a box empty for no limit on that axis. A company may
> tighten these for its own people and can never loosen them.

Boxes are minutes and hours; an empty box means no limit, not zero. What a
person sees of this is in [signing in](signing-in.md).

## Instance features

> Turn a feature off for the whole instance. No company and no team can turn it
> back on — they may only tighten further.

Two states per feature, not three: **Allow** and **Turn off**. There is nothing
above the instance to object to, so an explicit "allow" would compute nothing —
**Allow removes the decision** rather than storing one.

Five features are switchable: Chat, Agent, Translate, Search and Workflows. A
team's own view of the same question is on [Team](team.md), which names which
layer decided.

## Email delivery

> The relay this instance sends notifications through. Nothing is sent until it
> is configured, and a team configures nothing here — the From address is this
> instance's own identity.

**SMTP host**, **Port**, **Security**, **Username**, **Password** (*leave blank
to keep the stored one*), **From address**, **From name**, **Sending enabled**,
and:

- **Console URL** — *"This console's own external address. A notification links
  back to it, and it cannot be guessed — a message is composed by a sweep with
  no request in sight."* Without it, the links in notifications go nowhere
  useful.
- **Send a test** to an address, and **Last test** with its outcome. The
  relay's own reply is kept and shown, clipped, because for a relay that will
  not answer it is the most useful thing there is.
- **Remove the transport** — *"Nothing will be sent until it is configured
  again."*

The password is stored encrypted whenever this instance has an encryption key
configured. **With no key it is stored unencrypted, and this card does not say
so.** Before typing a live relay password, check that the Health tab or
`GET /api/admin/status` reads `secrets: sealed`; if it reads `plaintext`, set
`TMACH_SECRET_KEY` first — `docs/deploy-tailnet.md` has the four steps.

**A team cannot point this anywhere.** There is no per-team relay, and that is
a security decision rather than a missing feature: a team-chosen SMTP host
would be a way to make this server connect to an address of somebody's
choosing.

## Email notifications

> Which categories this instance sends. A category nobody has named is OFF —
> this decides whether the instance mails people at all, so it is named rather
> than assumed. A person may turn one off for themselves; nobody below this may
> turn one on.

Four categories over seven events. **Absence means off here**, which is the one
place in this console where that is true — everywhere else an unset feature
switch means enabled. The reason is that this governs whether the instance sends
mail to people, and the behaviour that already existed is sending none: a
document upload fires an event, so an "absent means on" default would mail every
member once per document the first time anybody confirmed an address, on an
upgrade, to an operator who had configured nothing.

A **person** may always turn a category off for themselves — on their own
[Usage](usage.md) screen — including one every layer above allows, and that
choice survives the layer above being switched back on.

What a message carries is deliberately narrow: ids, a status, a workflow slug
and a link back to this console. **Never content.** An inbox leaves the instance
altogether, rests on somebody else's server and is forwarded onwards.

## Testing tools

**Load sample data** seeds this team with notes, documents and a run so the
other screens have something on them. It is a development convenience and says
so.
