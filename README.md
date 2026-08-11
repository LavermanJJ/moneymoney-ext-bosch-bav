# Bosch Vorsorgeplan for Money Money

Inofficial [MoneyMoney](https://moneymoney.app/) WebBanking extension that reads the
current value of your Bosch Vorsorgeplan / Bosch Pensionsfonds account (bAV) from
[boschvorsorgeplan.de](https://www.boschvorsorgeplan.de/) via web scraping.

Not affiliated with or endorsed by Robert Bosch GmbH or the Bosch Vorsorgeplan portal
operator. Use at your own risk — the portal can change its markup at any time, which
would break this extension.

![Example screenshot](img/example.png)

## What it does

1. Logs into the participant portal ("Mit Zugangsdaten zum Altersversorgungskonto") with
   your username and password.
2. If your account has the app-based second factor enabled, MoneyMoney prompts you for the
   "Bestätigungscode" shown in your authenticator app.
3. Presents your bAV as a **Depot (portfolio)** account with a single position, using the
   "Kontostand" and your "Mitarbeiterbeitrag" from the "Beitragsübersicht" page:
   - **Einstand** (cost basis) = your own Mitarbeiterbeitrag — the money you personally
     paid in via Entgeltumwandlung.
   - **Wert** (current value) = the total Kontostand.
   - **Gewinn** = Kontostand − Mitarbeiterbeitrag = the Arbeitgeber-Beiträge (Firmenbeitrag,
     Firmenzuschuss, AVWL) **plus** the Wertzuwachs (market growth) — i.e. everything you
     did *not* pay yourself.

   This is deliberately framed as your **personal return** on your own contribution, which
   for a bAV is typically very large (employer money + subsidies + market growth on top of
   what you put in). It is intentionally *not* the fund's performance — for that, the
   Wertzuwachs alone would be the relevant figure. The position is named to make the
   composition of the gain explicit.
4. Uses your Bosch-Personalnummer (from "Mein Profil") as the account's Kontonummer in
   MoneyMoney, rather than a generic placeholder.
5. Downloads "Kontoauszug" and "Renteninformation" PDFs from the Postfach's
   "Kontoauszüge und Renteninformationen" category into MoneyMoney's Dokumente view, via
   the undocumented `FetchStatements` entry point (not part of the public WebBanking API
   reference, but supported by the app — confirmed by inspecting a real published
   extension that uses it the same way). Only new documents (by filename) are downloaded
   on each refresh.

The extension provides only the *current* snapshot each refresh; MoneyMoney builds the
value-over-time chart forward from when you add the account (past values can't be
backfilled via the extension API). The "Anmelden mit Bosch-Konto" SSO button (corporate
Bosch account / Okta-style login for active employees) is **not** supported — only the
direct username/password login for the pension account itself.

## Installation

1. Open MoneyMoney → **Hilfe → Zeige Datenbank im Finder** (**Help → Show Database in
   Finder**). This opens the app's data folder.
2. Copy `BoschVorsorgeplan.lua` into the `Extensions` subfolder there.
3. In **MoneyMoney → Einstellungen → Erweiterungen** (**Preferences → Extensions**),
   uncheck **"Digitale Signatur von Extensions überprüfen"** ("Check Digital Signature of
   Extensions"). This is required because the script isn't signed by MoneyMoney — only
   do this if you trust the script (review the source, it's short).
4. Restart MoneyMoney.
5. **Konto hinzufügen → Andere Kontoverbindung** and search for "Bosch Vorsorgeplan".
   Enter your portal username and password. If prompted, enter the confirmation code from
   your authenticator app.

## Troubleshooting

If the account stops refreshing (e.g. because Bosch changed the portal's HTML), open
**Fenster → Protokollfenster** (**Window → Protocol Window**) in MoneyMoney to see the
extension's status/error messages. From there you can save/copy the log. There's no
automatic HTTP traffic log — add `print(...)` calls to the script to inspect specific
requests/responses while debugging.

## Statements (Dokumente)

The extension also downloads the "Kontoauszug" and "Renteninformation" PDFs from the
Postfach into MoneyMoney's Dokumente view. This uses `FetchStatements`, an entry point
that is **not part of MoneyMoney's published WebBanking API** — it works today (a real
published extension uses it the same way), but it could stop working on a future
MoneyMoney release. Treat the Dokumente feature as best-effort.

## Development notes

The extension is a single file, `BoschVorsorgeplan.lua`, with no dependencies. Syntax-check
it with `luac -p BoschVorsorgeplan.lua`.

The XPath selectors were derived from local, saved copies of the portal pages (login, 2FA,
account overview, profile, and Postfach). Those saved pages — and any debug
logs — contain real personal data (name, balance, Personalnummer, account numbers) and are
kept out of the repository via `.gitignore`. **Never commit or share them.** When adding
selectors, document the target HTML with anonymized placeholder values only.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: see [SECURITY.md](SECURITY.md).

## License

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE).

Not affiliated with, endorsed by, or supported by Robert Bosch GmbH or the operator of the
Bosch Vorsorgeplan portal. Structure inspired by the Trading 212 MoneyMoney extension by
Teal Bauer (also Apache-2.0).
