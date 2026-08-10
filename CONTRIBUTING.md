# Contributing

Thanks for your interest in improving this extension!

This is a small, single-file [MoneyMoney](https://moneymoney.app/) WebBanking
extension that scrapes the Bosch Vorsorgeplan participant portal. Because the
portal has no public API, the extension depends entirely on the portal's HTML
structure — so the most common reason it breaks is Bosch changing that markup.

## Reporting a problem

Please open a GitHub issue and include:

- The MoneyMoney version and macOS version.
- What you expected vs. what happened (e.g. wrong balance, missing statements,
  a login error).
- Relevant lines from **Fenster → Protokollfenster** (Window → Protocol Window).
  **Redact anything personal first** — the log can contain your name, balance,
  Personalnummer, and account numbers.

Never paste raw portal HTML, PDFs, `LocalStorage` contents, or your credentials
into an issue.

## Making changes

1. Keep everything in `BoschVorsorgeplan.lua` — one file, no dependencies.
2. When you change or add an XPath selector, include a short sample of the HTML
   it targets in a comment (see the existing helpers for the style), using
   **anonymized** placeholder values — never real balances, account numbers, or
   personal identifiers.
3. Syntax-check before submitting: `luac -p BoschVorsorgeplan.lua`.
4. Test against a real MoneyMoney install. Since the extension is unsigned,
   you'll need to allow unsigned extensions (see the README).
5. Bump the `version` field in the `WebBanking{ ... }` block for user-visible
   behaviour changes.

## Scope

This extension intentionally covers only the read-only participant portal
(balance, contribution history, Wertzuwachs/Firmenzuschuss, and the
Kontoauszug/Renteninformation PDFs). It does **not** support the corporate
"Anmelden mit Bosch-Konto" SSO login.

## License

By contributing, you agree that your contributions will be licensed under the
Apache License 2.0, the same license that covers this project.
