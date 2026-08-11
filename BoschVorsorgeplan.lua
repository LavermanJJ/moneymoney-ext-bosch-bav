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

-- Reads one row's amount from the "Kapitalzusammensetzung" breakdown on the
-- Beitragsübersicht page (e.g. "Mitarbeiterbeitrag" -> your own contribution
-- total). Used as the cost basis of the portfolio position.
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
      portfolio = true,
      type = AccountTypePortfolio
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

  -- Model the whole bAV as a single portfolio position so MoneyMoney's Depot
  -- shows the gain you actually care about:
  --   cost basis (Einstand) = your own Mitarbeiterbeitrag (Entgeltumwandlung)
  --   current value         = Kontostand
  -- The Gewinn MoneyMoney then computes = Kontostand - Mitarbeiterbeitrag =
  -- the Arbeitgeber-Beiträge (Firmenbeitrag, Firmenzuschuss, AVWL) plus the
  -- Wertzuwachs, i.e. everything you did not pay yourself. If the
  -- Mitarbeiterbeitrag can't be read, cost falls back to 0 (Gewinn = full value).
  local eigenbeitrag = FindCapitalCategoryAmount(html, "Mitarbeiterbeitrag") or 0

  local security = {
    name = "Bosch Vorsorgeplan (Gewinn = Arbeitgeber-Beiträge + Wertzuwachs)",
    quantity = 1,
    amount = balance,
    price = balance,
    currencyOfPrice = "EUR",
    purchasePrice = eigenbeitrag,
    currencyOfPurchasePrice = "EUR"
  }

  return { securities = { security } }
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
