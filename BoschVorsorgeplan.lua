--
-- MoneyMoney Extension for Bosch Vorsorgeplan (bAV) <https://www.boschvorsorgeplan.de/>
--
-- Inofficial extension. Not affiliated with or endorsed by Robert Bosch GmbH
-- or the Bosch Vorsorgeplan portal operator.
--
-- Logs into the participant portal with username/password (plus an optional
-- app-based "Bestätigungscode" second factor) and reads the current total
-- value ("Kontostand") of your Bosch Vorsorgeplan / Bosch Pensionsfonds
-- account from the "Beitragsübersicht" page.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Structure inspired by the Trading 212 MoneyMoney extension by Teal Bauer.
--

WebBanking{
  version     = 1.00,
  url         = "https://www.boschvorsorgeplan.de/",
  services    = { "Bosch Vorsorgeplan" },
  description = "Bosch Vorsorgeplan (bAV)"
}

local connection = Connection()
connection.language = "de-DE"

local baseUrl        = "https://www.boschvorsorgeplan.de"
local loginPageUrl    = baseUrl .. "/portal/web/bosch/home"
local overviewPageUrl = baseUrl .. "/portal/group/bosch/beitragsubersicht"
local profilePageUrl  = baseUrl .. "/portal/group/bosch/account"
local postfachPageUrl = baseUrl .. "/portal/group/bosch/postfach"
local logoutUrl       = baseUrl .. "/portal/c/portal/logout"

-- Carries the second-factor form target from InitializeSession2 step 1 to
-- step 2 (both calls happen within the same extension run/session).
local mfaAction, mfaAuthToken

-- Helpers

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Parses amounts as rendered by the portal, e.g. " 12 345,67" (space as
-- thousands separator, comma as decimal separator), into a Lua number.
local function ParseAmount(text)
  if not text then
    return nil
  end
  local cleaned = trim(text):gsub("%s", ""):gsub(",", ".")
  return tonumber(cleaned)
end

-- Reads all <input> fields within a form into a name -> value map.
local function ReadFormFields(form)
  local fields = {}
  form:xpath(".//input"):each(function(_, input)
    local name = input:attr("name")
    if name and name ~= "" then
      fields[name] = input:attr("value") or ""
    end
  end)
  return fields
end

local function UrlEncodeFields(fields)
  local parts = {}
  for name, value in pairs(fields) do
    table.insert(parts, MM.urlencode(name) .. "=" .. MM.urlencode(value))
  end
  return table.concat(parts, "&")
end

local function LoginFormPresent(html)
  return html:xpath("//form[contains(@class,'sign-in-form')]"):length() > 0
end

local function MfaFormPresent(html)
  return html:xpath("//input[@id='otp']"):length() > 0
end

-- Categories from the "Kapitalzusammensetzung" breakdown on the
-- Beitragsübersicht page that have no dated/monthly breakdown of their own
-- (unlike Firmenbeitrag, Beitrag AVWL, Mitarbeiterbeitrag): "Wertzuwachs"
-- (investment growth) is a running cumulative total like unrealized gains
-- on a portfolio, and "Firmenzuschuss" only shows up there irregularly.
-- Both are tracked as a running total across refreshes further down, only
-- booking the change since the last refresh.
local trackedCapitalCategories = { "Wertzuwachs", "Firmenzuschuss" }

local function FindCapitalCategoryAmount(html, label)
  local nodes = html:xpath(
    "//table[@aria-label='Beiträge der Kapitalzusammensetzung']//tr[td[1][normalize-space()='" .. label .. "']]/td[2]"
  )
  if nodes:length() == 0 then
    return nil
  end
  return ParseAmount(nodes:text())
end

-- "Bosch-Personalnummer" from the "Mein Profil" page:
--   <div class="row my-3">
--     <div class="col-12 col-sm-5"> Bosch-Personalnummer </div>
--     <div class="col-12 col-sm-7"> 12345678</div>
--   </div>
local function FindPersonalnummer(html)
  local nodes = html:xpath(
    "//div[contains(concat(' ',normalize-space(@class),' '),' row ')]" ..
    "[./div[normalize-space(text())='Bosch-Personalnummer']]/div[contains(@class,'col-sm-7')]"
  )
  if nodes:length() == 0 then
    return nil
  end
  return trim(nodes:text())
end

-- Links from the "Kontoauszüge und Renteninformationen" category on the
-- Postfach page, e.g.:
--   <h2 id="..._acc_cat_0_hdln">Kontoauszüge und Renteninformationen</h2>
--   <div id="..._acc_cat_0_cnt"> ... <a href=".../postfach?...&fileName=KTO_..._251231.pdf">
--     Kontoauszug 2026 für 2025 (Konto: 1)
--   </a> ... </div>
-- Other categories (Bestätigungsschreiben, Lohnsteuerbescheinigung, ...)
-- are intentionally not touched.
local function FindStatementLinks(html)
  local links = {}
  html:xpath(
    "//h2[contains(@id,'_acc_cat_') and contains(.,'Kontoauszüge und Renteninformationen')]"
  ):each(function(_, headline)
    local contentId = headline:attr("id"):gsub("_hdln$", "_cnt")
    html:xpath("//div[@id='" .. contentId .. "']//a[contains(@href,'fileName=')]"):each(function(_, a)
      local fileName = a:attr("href"):match("fileName=([^&]+)")
      if fileName then
        table.insert(links, {
          url = a:attr("href"),
          name = trim(a:text()),
          fileName = fileName
        })
      end
    end)
  end)
  return links
end

-- Statement filenames end in a YYMMDD date, e.g. "KTO_10000000_001_251231.pdf"
-- -> 2025-12-31.
local function ParseStatementDate(fileName)
  local yy, mm, dd = fileName:match("(%d%d)(%d%d)(%d%d)%.pdf$")
  if not yy then
    return os.time()
  end
  return os.time({ year = 2000 + tonumber(yy), month = tonumber(mm), day = tonumber(dd), hour = 12 })
end

local germanMonths = {
  ["Januar"] = 1, ["Februar"] = 2, ["März"] = 3, ["April"] = 4,
  ["Mai"] = 5, ["Juni"] = 6, ["Juli"] = 7, ["August"] = 8,
  ["September"] = 9, ["Oktober"] = 10, ["November"] = 11, ["Dezember"] = 12
}

local function CombinePurpose(group, kind)
  if kind == "" or kind == group then
    return group
  end
  return group .. " – " .. kind
end

-- Finds the "Monatssicht" forms on the Beitragsübersicht page, one per year
-- of contribution history, e.g.:
--   <form id="show-2026-form" ...>
--     <input name="p_auth" ...><input name="action" value="exec-konto">
--     <input name="paramName" value="jahr"><input name="paramValue" value="2026">
--     <input name="actionValue" value="next">
--     <input name="friendlyURL" value="/monatssicht">
--     <input name="portletName" value="beitragshistorie-jahr">
--   </form>
local function FindYearForms(html)
  local years = {}
  html:xpath("//form[.//input[@name='friendlyURL' and @value='/monatssicht']]"):each(function(_, form)
    local fields = ReadFormFields(form)
    local year = tonumber(fields["paramValue"])
    if year then
      table.insert(years, { year = year, action = form:attr("action"), fields = fields })
    end
  end)
  return years
end

-- Fetches the monthly contribution breakdown ("Monatssicht") for one year
-- and turns each contribution row of each month into a transaction. Each
-- month is an accordion identified by an id containing "_acc_contrsum_",
-- e.g. "..._acc_contrsum_0_hdln" (headline) / "..._acc_contrsum_0_cnt"
-- (content table). The content table's last row is a per-month total with
-- empty "Beitragsgruppe"/"Beitragsart" cells, which is skipped.
local function FetchMonthlyTransactions(yearForm)
  local content, charset = connection:post(
    yearForm.action, UrlEncodeFields(yearForm.fields), "application/x-www-form-urlencoded"
  )
  local html = HTML(content, charset)
  local transactions = {}

  html:xpath("//h2[contains(@id,'_acc_contrsum_') and contains(@id,'_hdln')]"):each(function(_, headline)
    local contentId = headline:attr("id"):gsub("_hdln$", "_cnt")
    local monthName = trim(headline:xpath(".//span[@class='col-6']"):text())
    local month = germanMonths[monthName]
    if month then
      local bookingDate = os.time({ year = yearForm.year, month = month, day = 1, hour = 12 })
      html:xpath("//div[@id='" .. contentId .. "']//table//tbody/tr"):each(function(_, row)
        local group = trim(row:xpath("./td[1]"):text() or "")
        if group ~= "" then
          local kind = trim(row:xpath("./td[2]"):text() or "")
          local amount = ParseAmount(row:xpath("./td[3]"):text())
          if amount and amount ~= 0 then
            table.insert(transactions, {
              name = "Bosch Vorsorgeplan",
              amount = amount,
              currency = "EUR",
              bookingDate = bookingDate,
              purpose = CombinePurpose(group, kind),
              booked = true
            })
          end
        end
      end)
    end
  end)

  return transactions
end

-- WebBanking API impl

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Bosch Vorsorgeplan"
end

-- Two-step login: step 1 submits username/password, and either finishes
-- (no second factor configured) or returns a challenge for the app-based
-- confirmation code. Step 2 submits that code.
function InitializeSession2(protocol, bankCode, step, credentials, interactive)
  if step == 1 then
    local username, password = credentials[1], credentials[2]

    MM.printStatus("Öffne Login-Seite")
    local content, charset = connection:get(loginPageUrl)
    local html = HTML(content, charset)

    local form = html:xpath("//form[contains(@class,'sign-in-form')]")
    if form:length() == 0 then
      return "Das Login-Formular wurde auf der Bosch-Vorsorgeplan-Seite nicht gefunden. Die Seite wurde vermutlich geändert."
    end

    local action = form:attr("action")
    local fields = ReadFormFields(form)

    -- The visible username/password inputs are matched by type, since
    -- their name attributes are Liferay-portlet-instance-specific and can
    -- change (e.g. "_58_login") between deployments.
    form:xpath(".//input[@type='text']"):each(function(_, input)
      fields[input:attr("name")] = username
    end)
    form:xpath(".//input[@type='password']"):each(function(_, input)
      fields[input:attr("name")] = password
    end)

    MM.printStatus("Melde an")
    local respContent, respCharset = connection:post(action, UrlEncodeFields(fields), "application/x-www-form-urlencoded")
    local respHtml = HTML(respContent, respCharset)

    if MfaFormPresent(respHtml) then
      local mfaForm = respHtml:xpath("//form[.//input[@id='otp']]")
      mfaAction = mfaForm:attr("action")
      mfaAuthToken = mfaForm:xpath(".//input[@name='p_auth']"):attr("value")

      local label = trim(respHtml:xpath("//label[@for='otp']"):text() or "Bestätigungscode")
      label = label:gsub("%s*%*%s*$", "")

      return {
        title = "Bosch Vorsorgeplan – Zwei-Faktor-Authentifizierung",
        challenge = "Bitte geben Sie den Code aus Ihrer Authenticator-App ein.",
        label = label
      }
    end

    if LoginFormPresent(respHtml) then
      return LoginFailed
    end

    -- No second factor configured for this account - already done.
    return nil
  elseif step == 2 then
    local otp = credentials[1]

    if not mfaAction or not mfaAuthToken then
      return "Interner Fehler: Die Sitzung für die Zwei-Faktor-Authentifizierung ist ungültig. Bitte erneut versuchen."
    end

    local postContent = UrlEncodeFields({
      p_auth = mfaAuthToken,
      action = "next",
      otp = otp
    })

    MM.printStatus("Prüfe Bestätigungscode")
    local respContent, respCharset = connection:post(mfaAction, postContent, "application/x-www-form-urlencoded")
    local respHtml = HTML(respContent, respCharset)

    mfaAction, mfaAuthToken = nil, nil

    if MfaFormPresent(respHtml) then
      return LoginFailed
    end

    return nil
  end

  return "Unbekannter Login-Schritt: " .. tostring(step)
end

function ListAccounts(knownAccounts)
  MM.printStatus("Rufe Bosch-Personalnummer ab")
  local content, charset = connection:get(profilePageUrl)
  local html = HTML(content, charset)

  local accountNumber = FindPersonalnummer(html) or "Bosch-Vorsorgeplan"

  return {
    {
      name = "Bosch Vorsorgeplan",
      accountNumber = accountNumber,
      currency = "EUR",
      type = AccountTypeSavings
    }
  }
end

function RefreshAccount(account, since)
  MM.printStatus("Rufe Kontostand ab")
  local content, charset = connection:get(overviewPageUrl)
  local html = HTML(content, charset)

  -- Total "Kontostand" on the Beitragsübersicht page:
  --   <div class="col-lg-8 amount-display"> <h2>Kontostand</h2> ...
  --     <div class="col-12 text-right"><div class="h2 highlight"> 12 345,67</div></div>
  local amountNodes = html:xpath("//div[contains(@class,'amount-display')]//div[contains(concat(' ', normalize-space(@class), ' '), ' h2 ') and contains(@class,'highlight')]")
  if amountNodes:length() == 0 then
    error("Der Kontostand konnte nicht aus der Beitragsübersicht-Seite ausgelesen werden (" .. overviewPageUrl .. "). Möglicherweise wurde die Seite geändert oder die Sitzung ist abgelaufen.")
  end

  local balance = ParseAmount(amountNodes:text())
  if not balance then
    error("Der Kontostand-Text (" .. tostring(amountNodes:text()) .. ") konnte nicht als Zahl interpretiert werden.")
  end

  -- Always fetch every year the portal offers, regardless of `since`:
  -- MoneyMoney applies its own lookback default (e.g. "last 12 months") on
  -- the very first refresh rather than passing since=nil, and later
  -- refreshes only ever advance `since` forward from the newest
  -- transaction MoneyMoney has already stored. If older years were
  -- skipped once, they would never get backfilled - so it's not worth
  -- trying to optimize this away. MoneyMoney itself discards whatever
  -- falls outside the requested range.
  local transactions = {}
  for _, yearForm in ipairs(FindYearForms(html)) do
    MM.printStatus("Rufe Beiträge " .. yearForm.year .. " ab")
    for _, transaction in ipairs(FetchMonthlyTransactions(yearForm)) do
      table.insert(transactions, transaction)
    end
  end

  -- Wertzuwachs/Firmenzuschuss have no dated breakdown, only a cumulative
  -- total, so we track that total across refreshes ourselves and book the
  -- change since last time. On the very first refresh there's no prior
  -- value yet, so it's treated as 0 - meaning the full current total gets
  -- booked as a starting transaction, rather than being invisible forever.
  -- The date and sign of the amount already make it obvious whether it
  -- grew or shrank, so the purpose is just the category label.
  for _, label in ipairs(trackedCapitalCategories) do
    local currentValue = FindCapitalCategoryAmount(html, label)
    if currentValue then
      local storageKey = label .. "_" .. account.accountNumber
      local previousValue = LocalStorage[storageKey] or 0
      local delta = currentValue - previousValue
      if math.abs(delta) >= 0.01 then
        table.insert(transactions, {
          name = "Bosch Vorsorgeplan",
          amount = delta,
          currency = "EUR",
          bookingDate = os.time(),
          purpose = label,
          booked = true
        })
      end
      LocalStorage[storageKey] = currentValue
    end
  end

  return { balance = balance, transactions = transactions }
end

-- Undocumented MoneyMoney entry point (not in the public WebBanking API
-- reference, but supported by the app - it feeds the "Dokumente" view).
-- Downloads Kontoauszug/Renteninformation PDFs from the Postfach that
-- MoneyMoney doesn't already have, identified by their filename.
function FetchStatements(accounts, knownIdentifiers)
  local known = {}
  for _, identifier in ipairs(knownIdentifiers) do
    known[identifier] = true
  end

  MM.printStatus("Suche Kontoauszüge im Postfach")
  local content, charset = connection:get(postfachPageUrl)
  local html = HTML(content, charset)

  local statements = {}
  for _, link in ipairs(FindStatementLinks(html)) do
    if not known[link.fileName] then
      MM.printStatus("Lade " .. link.name)
      local pdfContent = connection:get(link.url)
      table.insert(statements, {
        pdf = pdfContent,
        filename = link.fileName,
        identifier = link.fileName,
        name = link.name,
        creationDate = ParseStatementDate(link.fileName)
      })
    end
  end

  return { statements = statements }
end

function EndSession()
  connection:get(logoutUrl)
end
