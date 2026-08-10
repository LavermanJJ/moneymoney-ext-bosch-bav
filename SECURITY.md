# Security Policy

This extension handles credentials for a financial account, so please treat
security issues seriously.

## Reporting a vulnerability

If you discover a security issue (for example: credential handling, data
leaking into logs, or an injection via scraped content), **do not open a public
GitHub issue.** Instead, report it privately via GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
("Report a vulnerability" under the repository's **Security** tab).

Please include a description of the issue, steps to reproduce, and — with any
logs or samples — **redact all personal data** (name, balance, Personalnummer,
account numbers) first.

## How credentials are handled

- Your username, password, and second-factor code are provided by MoneyMoney
  through its own credential store and are used only to authenticate against
  `https://www.boschvorsorgeplan.de`. They are never written to disk or
  `LocalStorage` by this extension.
- All portal requests use HTTPS.
- Only two values are persisted in MoneyMoney's `LocalStorage`: the last
  known "Wertzuwachs" and "Firmenzuschuss" totals, used to compute the change
  between refreshes. No credentials or documents are stored there.

## Trust considerations

- This is an **unofficial** extension and is not signed by MoneyMoney. Running
  it requires disabling MoneyMoney's signature check for extensions. Review the
  source (it's a single, short file) before installing.
- It relies on `FetchStatements`, an entry point that is not part of
  MoneyMoney's published WebBanking API. It may stop working on a future
  MoneyMoney release.
