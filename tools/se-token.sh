#!/usr/bin/env bash
#
# se-token.sh — SolarEdge V2 API OAuth helper + thin curl wrapper.
#
# Handles the awkward parts of testing the V2 API by hand:
#   1. Access tokens expire after 2 hours.
#   2. The refresh token ROTATES on every refresh — lose it and the grant is
#      gone, and you must send the homeowner through consent again.
#   3. ISO8601 from/to need a timezone, and a literal '+' in a query string
#      decodes to a space (silent 400s). We always emit UTC 'Z'.
#
# Credentials live OUTSIDE the git repo, in ~/.config/semonitor/se-api.env
# (mode 600). Secrets are passed to curl over stdin, never on the command
# line, so they don't show up in `ps`. Nothing is written to stdout except
# API responses.
#
# FIRST-TIME SETUP (you need a refresh token; this is how you mint one):
#   se-token.sh init                  # store client_id + client_secret
#   se-token.sh authorize             # prints the consent URL — open it
#   se-token.sh exchange <code> [site_id]   # trade the code for tokens
#
# EVERYDAY USE:
#   se-token.sh token                 # print a valid access token
#   se-token.sh header                # print "Authorization: Bearer ..."
#   se-token.sh get <path[?query]>    # GET against the V2 base URL
#   se-token.sh day  <YYYY-MM-DD>     # overview for one LOCAL calendar day
#   se-token.sh energy <YYYY-MM-DD>   # energy?resolution=DAY for that day
#   se-token.sh today                 # overview, local midnight -> now
#   se-token.sh refresh               # force a refresh (rarely needed)
#   se-token.sh revoke                # revoke the current access token
#   se-token.sh xcconfig              # emit Secrets.xcconfig for the Xcode build
#
# Examples:
#   se-token.sh day 2026-11-03 | jq .
#   se-token.sh get "/sites/3958787/power?from=2026-11-03T06:00:00Z&to=2026-11-03T10:00:00Z&resolution=QUARTER_HOUR" | jq .
#
set -euo pipefail

CONFIG_DIR="${SE_CONFIG_DIR:-$HOME/.config/semonitor}"
CONFIG_FILE="$CONFIG_DIR/se-api.env"
CACHE_FILE="$CONFIG_DIR/access-token.json"
AUTHORIZE_URL="https://connect.solaredge.com/authorize"
TOKEN_URL="https://monitoringapi.solaredge.com/v2/oauth2/token"
REVOKE_URL="https://monitoringapi.solaredge.com/v2/oauth2/revoke-token"
API_BASE="https://monitoringapi.solaredge.com/v2"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

# ---------------------------------------------------------------- config i/o

write_config() {
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  local tmp; tmp="$(mktemp "$CONFIG_DIR/.cfg.XXXXXX")"
  {
    printf 'SE_CLIENT_ID=%q\n'     "${SE_CLIENT_ID:-}"
    printf 'SE_CLIENT_SECRET=%q\n' "${SE_CLIENT_SECRET:-}"
    printf 'SE_REFRESH_TOKEN=%q\n' "${SE_REFRESH_TOKEN:-}"
    printf 'SE_SITE_ID=%q\n'       "${SE_SITE_ID:-}"
    printf 'SE_DEVELOPMENT_TEAM=%q\n' "${SE_DEVELOPMENT_TEAM:-}"
  } >"$tmp"
  chmod 600 "$tmp"
  # Keep one generation back: if a rotation ever half-fails, this is the only
  # thing between you and re-running the consent flow.
  [[ -f "$CONFIG_FILE" ]] && cp -p "$CONFIG_FILE" "$CONFIG_FILE.prev"
  mv -f "$tmp" "$CONFIG_FILE"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "no config at $CONFIG_FILE — run: $0 init"
  set -a; . "$CONFIG_FILE"; set +a
  SE_CLIENT_ID="${SE_CLIENT_ID:-}"
  SE_CLIENT_SECRET="${SE_CLIENT_SECRET:-}"
  SE_REFRESH_TOKEN="${SE_REFRESH_TOKEN:-}"
  SE_SITE_ID="${SE_SITE_ID:-}"
  SE_DEVELOPMENT_TEAM="${SE_DEVELOPMENT_TEAM:-}"
}

require_client() {
  load_config
  [[ -n "$SE_CLIENT_ID"     ]] || die "missing SE_CLIENT_ID — run: $0 init"
  [[ -n "$SE_CLIENT_SECRET" ]] || die "missing SE_CLIENT_SECRET — run: $0 init"
}

require_grant() {
  require_client
  [[ -n "$SE_REFRESH_TOKEN" ]] || die "no refresh token yet — run: $0 authorize"
  [[ -n "$SE_SITE_ID"       ]] || die "no site id — re-run: $0 exchange <code> <site_id>"
}

cmd_init() {
  local id secret site team
  note "Stored in $CONFIG_FILE (mode 600). Secrets are read silently."
  printf 'client_id: '           >&2; read -r  id
  printf 'client_secret: '       >&2; read -rs secret; printf '\n' >&2
  printf 'site id (optional, the consent callback also returns it): ' >&2; read -r site
  printf 'Apple Developer Team ID (optional, for Xcode signing): ' >&2; read -r team
  [[ -n "$id" && -n "$secret" ]] || die "client_id and client_secret are both required"
  SE_CLIENT_ID="$id"; SE_CLIENT_SECRET="$secret"
  SE_SITE_ID="$site"; SE_REFRESH_TOKEN=""
  SE_DEVELOPMENT_TEAM="$team"
  write_config
  rm -f "$CACHE_FILE"
  note ""
  note "saved. next:  $0 authorize"
}

# ------------------------------------------------------------- oauth helpers

# POST a JSON body to an OAuth endpoint. Body arrives on stdin so the secret
# never appears in the process list. Echoes the response body on success.
oauth_post() {
  local url="$1" body="$2" resp http out
  resp="$(printf '%s' "$body" | curl -sS -w $'\n%{http_code}' -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    --data-binary @-)" || die "could not reach $url"
  http="${resp##*$'\n'}"
  out="${resp%$'\n'*}"
  if [[ "$http" != 2* ]]; then
    note "OAuth call failed (HTTP $http):"
    printf '%s\n' "$out" >&2
    local err; err="$(jq -r '.error // empty' <<<"$out" 2>/dev/null || true)"
    case "$err" in
      invalid_client)  note "-> client_id or client_secret is wrong. Re-run: $0 init" ;;
      invalid_request) note "-> usually a consumed, expired or mistyped code. Restart: $0 authorize" ;;
    esac
    exit 1
  fi
  printf '%s' "$out"
}

# Store the token pair from an OAuth response. The refresh token is the
# irreplaceable half, so it is persisted BEFORE the access-token cache: if we
# die in between, we lose only a cheap cache write.
save_tokens() {
  local body="$1" at rt ei exp tmp
  at="$(jq -r '.access_token  // empty' <<<"$body")"
  rt="$(jq -r '.refresh_token // empty' <<<"$body")"
  ei="$(jq -r '.expires_in    // 7200'  <<<"$body")"
  [[ -n "$at" ]] || { note "no access_token in response:"; printf '%s\n' "$body" >&2; exit 1; }

  if [[ -n "$rt" && "$rt" != "${SE_REFRESH_TOKEN:-}" ]]; then
    SE_REFRESH_TOKEN="$rt"
    write_config
    note "note: refresh token stored/rotated in $CONFIG_FILE"
  fi

  exp=$(( $(date +%s) + ei - 300 ))   # 300s margin so a call can't straddle expiry
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  tmp="$(mktemp "$CONFIG_DIR/.tok.XXXXXX")"
  jq -n --arg t "$at" --argjson e "$exp" '{access_token:$t,expires_at:$e}' >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$CACHE_FILE"
  ACCESS_TOKEN="$at"
}

cmd_authorize() {
  require_client
  note "1. Open this URL in a browser and approve access to your site:"
  note ""
  printf '%s?client_id=%s\n' "$AUTHORIZE_URL" "$SE_CLIENT_ID"
  note ""
  note "2. After you approve, SolarEdge redirects to the Redirect URL set on"
  note "   your Application. That page will probably fail to load — that is"
  note "   fine and expected. What matters is the ADDRESS BAR, which now"
  note "   contains the code and the site id:"
  note ""
  note "     ...?site_id=3958787&code=uWUZ9LaLoxW4KpzZJjVfoBPLCi4FwPFW"
  note ""
  note "3. Copy both out of the address bar and run, promptly (the code is"
  note "   one-use and short-lived):"
  note ""
  note "     $0 exchange <code> <site_id>"
}

# Pull code= and site_id= out of a pasted redirect URL, so nobody has to
# transcribe a one-use credential by hand.
parse_redirect_url() {
  local url="$1" q kv k v
  q="${url#*\?}"
  [[ "$q" != "$url" ]] || die "that URL has no query string — did the redirect actually carry ?code=... ?"
  q="${q%%#*}"
  PARSED_CODE=""; PARSED_SITE=""
  local oldifs="$IFS"; IFS='&'
  for kv in $q; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      code)    PARSED_CODE="$v" ;;
      site_id) PARSED_SITE="$v" ;;
    esac
  done
  IFS="$oldifs"
  [[ -n "$PARSED_CODE" ]] || die "no code= parameter in that URL (params seen: $(printf '%s' "$q" | tr '&' ' ' | sed 's/=[^ ]*//g'))"
}

cmd_exchange() {
  local code="${1:-}" site="${2:-}"
  [[ -n "$code" ]] || die "usage: $0 exchange <code> [site_id]   |   $0 exchange '<full redirect URL>'"
  # Accept a pasted redirect URL in place of the bare code.
  if [[ "$code" == http*://* || "$code" == *"code="* ]]; then
    parse_redirect_url "$code"
    code="$PARSED_CODE"
    [[ -n "$site" ]] || site="$PARSED_SITE"
    note "parsed code (${#code} chars)${site:+ and site_id $site} from the pasted URL"
  fi
  require_client
  local body resp
  body="$(jq -n \
    --arg c "$code" --arg ci "$SE_CLIENT_ID" --arg cs "$SE_CLIENT_SECRET" \
    '{grant_type:"authorization_code", code:$c, client_id:$ci, client_secret:$cs}')"
  resp="$(oauth_post "$TOKEN_URL" "$body")"
  [[ -n "$site" ]] && SE_SITE_ID="$site"
  save_tokens "$resp"
  [[ -n "${SE_SITE_ID:-}" ]] && write_config
  note ""
  note "authorized. site id: ${SE_SITE_ID:-<unset — pass it to exchange>}"
  note "try:  $0 day 2026-11-03 | jq ."
}

refresh_access_token() {
  [[ -n "$SE_REFRESH_TOKEN" ]] || die "no refresh token — run: $0 authorize"
  local body resp
  body="$(jq -n \
    --arg rt "$SE_REFRESH_TOKEN" --arg ci "$SE_CLIENT_ID" --arg cs "$SE_CLIENT_SECRET" \
    '{grant_type:"refresh_token", refresh_token:$rt, client_id:$ci, client_secret:$cs}')"
  if ! resp="$(oauth_post "$TOKEN_URL" "$body")"; then
    note ""
    note "If the refresh token is invalid or expired (14-day idle limit), the"
    note "grant is gone — re-run: $0 authorize"
    exit 1
  fi
  save_tokens "$resp"
}

get_access_token() {
  load_config
  if [[ -f "$CACHE_FILE" ]]; then
    local cached exp
    cached="$(jq -r '.access_token // empty' "$CACHE_FILE" 2>/dev/null || true)"
    exp="$(jq -r '.expires_at // 0' "$CACHE_FILE" 2>/dev/null || echo 0)"
    if [[ -n "$cached" && "$exp" -gt "$(date +%s)" ]]; then
      ACCESS_TOKEN="$cached"; return
    fi
  fi
  require_client
  refresh_access_token
}

# ---------------------------------------------------------------- api calls

api_get() {
  local path="$1" url resp http body
  [[ "$path" == /* ]] || path="/$path"
  url="$API_BASE$path"
  resp="$(curl -sS -w $'\n%{http_code}' \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H 'Accept: application/json' \
    "$url")" || die "could not reach $url"
  http="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$http" != 2* ]]; then
    note "HTTP $http for $path"
    case "$http" in
      403) note "(403: either a tier gate — Advanced Monitoring needs Business Pro — or a missing scope)" ;;
      429) note "(429: x-ratelimit-remaining-minute 0 = rate limit, honor retry-after; >0 = monthly credit limit, wait for the billing cycle)" ;;
    esac
    printf '%s\n' "$body" >&2
    exit 1
  fi
  printf '%s\n' "$body"
}

# Convert a LOCAL calendar day to a UTC Z range. BSD date (macOS).
local_day_range() {
  local d="$1" next s e
  s="$(date -j -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null)" \
    || die "bad date '$d' (expected YYYY-MM-DD)"
  # NB: -v+1d MUST precede the operand; BSD date silently ignores a -v that
  # comes after it (and then also drops the output format). Verified against
  # the 2026 DST transitions: 25 Oct -> 25h, 29 Mar -> 23h.
  next="$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" '+%Y-%m-%d')"
  e=$(( $(date -j -f '%Y-%m-%d %H:%M:%S' "$next 00:00:00" +%s) - 1 ))
  FROM_UTC="$(date -u -r "$s" '+%Y-%m-%dT%H:%M:%SZ')"
  TO_UTC="$(date -u -r "$e" '+%Y-%m-%dT%H:%M:%SZ')"
}

# ------------------------------------------------------------------- main

cmd="${1:-help}"; shift || true

case "$cmd" in
  init)      cmd_init ;;
  authorize) cmd_authorize ;;
  exchange)  cmd_exchange "${1:-}" "${2:-}" ;;

  token)     get_access_token; printf '%s\n' "$ACCESS_TOKEN" ;;
  header)    get_access_token; printf 'Authorization: Bearer %s\n' "$ACCESS_TOKEN" ;;
  refresh)   require_client; refresh_access_token; note "ok, new access token cached" ;;

  revoke)    get_access_token
             oauth_post "$REVOKE_URL" "$(jq -n --arg t "$ACCESS_TOKEN" '{token:$t}')" >/dev/null
             rm -f "$CACHE_FILE"
             note "access token revoked and local cache cleared" ;;

  xcconfig)  # Emit the build's Secrets.xcconfig. Writes to stdout, so redirect:
             #   tools/se-token.sh xcconfig > Secrets.xcconfig
             # The refresh token here is a snapshot: SolarEdge rotates it on
             # every refresh, and the app stores the live one on-device after
             # its first refresh. This value only has to be valid at the moment
             # of a fresh install, so re-run this if a build can't authorize.
             require_grant
             # Force a refresh first, so what we emit is a token the server
             # has just accepted. Emitting the stored value unchecked was a
             # trap: once the app's own first refresh rotates the token, the
             # copy here is dead, and re-running this would cheerfully re-bake
             # the dead one — looking like the command did nothing.
             note "verifying the grant before emitting..."
             refresh_access_token
             [[ -t 1 ]] && note "(writing to the terminal — redirect into Secrets.xcconfig)"
             printf '// Generated by se-token.sh on %s — DO NOT COMMIT.\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
             printf 'SE_CLIENT_ID = %s\n'     "$SE_CLIENT_ID"
             printf 'SE_CLIENT_SECRET = %s\n' "$SE_CLIENT_SECRET"
             printf 'SE_REFRESH_TOKEN = %s\n' "$SE_REFRESH_TOKEN"
             printf 'SE_SITE_ID = %s\n'       "$SE_SITE_ID"
             printf 'SE_DEVELOPMENT_TEAM = %s\n' "$SE_DEVELOPMENT_TEAM" ;;

  get)       [[ $# -ge 1 ]] || die "usage: $0 get <path[?query]>"
             get_access_token; api_get "$1" ;;

  day)       [[ $# -ge 1 ]] || die "usage: $0 day <YYYY-MM-DD>"
             require_grant; get_access_token; local_day_range "$1"
             note "# local day $1 -> $FROM_UTC .. $TO_UTC"
             api_get "/sites/$SE_SITE_ID/overview?from=$FROM_UTC&to=$TO_UTC" ;;

  energy)    [[ $# -ge 1 ]] || die "usage: $0 energy <YYYY-MM-DD>"
             require_grant; get_access_token; local_day_range "$1"
             note "# local day $1 -> $FROM_UTC .. $TO_UTC"
             api_get "/sites/$SE_SITE_ID/energy?from=$FROM_UTC&to=$TO_UTC&resolution=DAY" ;;

  today)     require_grant; get_access_token
             local_day_range "$(date '+%Y-%m-%d')"
             TO_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
             note "# today -> $FROM_UTC .. $TO_UTC"
             api_get "/sites/$SE_SITE_ID/overview?from=$FROM_UTC&to=$TO_UTC" ;;

  help|-h|--help)
             awk 'NR==1 {next} /^#/ {sub(/^#[[:space:]]?/,""); print; next} {exit}' "$0" ;;
  *)         die "unknown command '$cmd' (try: $0 help)" ;;
esac
